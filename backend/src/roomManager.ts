import { WebSocket } from 'ws';
import { v4 as uuidv4 } from 'uuid';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);
import db, { touchRoomActivity } from './db.js';
import { PlayerState, ClientMessage, ServerMessage } from './types.js';
import { generateSeed } from './archipelagoRunner.js';
import { getHostingProvider } from './hostingProvider.js';
import {
  activeServers,
  killRoomServer,
  sendServerCommand,
  startCentralServer,
  registerBroadcastCallback,
  registerChecksBroadcastCallback,
  registerServerLogBroadcastCallback
} from './serverManager.js';
import {
  roomChecksCache,
  fetchRoomChecks,
  recalculateRoomChecks,
  clearRoomSeedData
} from './checksService.js';

// Re-export server and check operations for external routers
export {
  activeServers,
  killRoomServer,
  sendServerCommand,
  startCentralServer,
  roomChecksCache,
  fetchRoomChecks,
  recalculateRoomChecks
};

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const BACKEND_ROOT = path.join(__dirname, '..');

// Character set for 6-digit room codes (excluding confusing characters: 0, 1, I, O, L)
const ROOM_CODE_CHARACTERS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

const CONNECTION_KIND = 'LODESTONE_LOBBY';

// Map of userId -> active WebSocket connection
const activeConnections = new Map<string, WebSocket>();

// Map of WebSocket -> metadata (userId and roomCode)
const connectionMetadata = new Map<WebSocket, { userId: string; roomCode: string }>();

// Periodic WebSocket heartbeat keep-alive every 20 seconds
// Sends ping frames to all active clients to keep Cloudflare tunnel and local connections alive
setInterval(() => {
  for (const ws of connectionMetadata.keys()) {
    if ((ws as any).isAlive === false) {
      console.log(`[Heartbeat][${CONNECTION_KIND}] Terminating unresponsive lobby connection`);
      ws.terminate();
      continue;
    }
    (ws as any).isAlive = false;
    try {
      ws.ping();
    } catch {}
  }
}, 20000);

// Register broadcast callback so serverManager updates room state when players connect/status changes
registerBroadcastCallback(broadcastRoomState);
registerChecksBroadcastCallback(broadcastChecks);
registerServerLogBroadcastCallback((roomCode: string, line: string) => {
  broadcastToRoom(roomCode, {
    type: 'server_log',
    line
  });
});

export function executeHostCommand(roomCode: string, userId: string, command: string): { success: boolean; message?: string; error?: string } {
  const room = db.prepare("SELECT host_id FROM Rooms WHERE code = ?").get(roomCode) as { host_id: string } | undefined;
  if (!room) {
    return { success: false, error: `Room ${roomCode} not found` };
  }
  if (room.host_id !== userId) {
    return { success: false, error: 'Only the room host can execute server commands' };
  }

  const ok = sendServerCommand(roomCode, command);
  if (!ok) {
    return { success: false, error: 'Central AP Server is not currently running or input is unavailable' };
  }

  return { success: true, message: `Command executed: ${command}` };
}

/**
 * Start or restart the Central MultiServer process for a room from its existing seed
 */
export async function startRoomServer(roomCode: string): Promise<void> {
  const room = db.prepare("SELECT seed_status, seed_zip_name, hosting_mode FROM Rooms WHERE code = ?").get(roomCode) as { seed_status: string; seed_zip_name: string | null; hosting_mode: string } | undefined;
  if (!room) {
    throw new Error(`Room ${roomCode} not found.`);
  }
  if (!room.seed_zip_name) {
    throw new Error(`Room ${roomCode} does not have a generated seed archive.`);
  }
  if (room.hosting_mode === 'archipelago_gg') {
    throw new Error(`Room ${roomCode} is hosted on Archipelago.gg and has no local server.`);
  }
  await startCentralServer(roomCode, room.seed_zip_name);
}

/**
 * Re-trigger seed generation for a room using its registered player YAML configurations
 */
export async function regenerateRoomSeed(roomCode: string): Promise<{ zipName: string; spoilerName: string }> {
  const room = db.prepare("SELECT code FROM Rooms WHERE code = ?").get(roomCode) as { code: string } | undefined;
  if (!room) {
    throw new Error(`Room ${roomCode} not found.`);
  }

  const playersYamls = db.prepare("SELECT name, yaml FROM Users WHERE room_code = ?").all(roomCode) as Array<{ name: string, yaml: string }>;
  if (playersYamls.length === 0) {
    throw new Error('Room has no registered players to generate seed from.');
  }

  killRoomServer(roomCode);
  db.prepare("UPDATE Rooms SET seed_status = 'generating' WHERE code = ?").run(roomCode);
  broadcastRoomState(roomCode);

  try {
    const { zipName, spoilerName } = await generateSeed(roomCode, playersYamls, (line) => {
      broadcastToRoom(roomCode, { type: 'generation_log', line });
    });

    clearRoomSeedData(roomCode);
    const hosting = db.prepare("SELECT hosting_mode FROM Rooms WHERE code = ?").get(roomCode) as { hosting_mode: string } | undefined;
    const provider = getHostingProvider(hosting?.hosting_mode || 'wayfinder_backend');
    const hosted = await provider.hostSeed(
      roomCode,
      path.join(BACKEND_ROOT, 'temp_seeds', roomCode, 'outputs', zipName),
      zipName
    );
    db.prepare("UPDATE Rooms SET seed_status = 'done', seed_zip_name = ?, seed_spoiler_name = ?, hosting_seed_id = ?, hosting_room_id = ?, hosting_room_url = ?, hosting_server_url = ?, hosting_status = ?, hosting_last_activity = ?, hosting_timeout = ?, hosting_last_error = NULL, hosting_updated_at = CURRENT_TIMESTAMP WHERE code = ?").run(
      zipName,
      spoilerName,
      hosted.seedId,
      hosted.roomId,
      hosted.roomUrl,
      hosted.serverUrl,
      hosted.status,
      hosted.lastActivity,
      hosted.timeout,
      roomCode
    );

    broadcastRoomState(roomCode);
    return { zipName, spoilerName };
  } catch (error: any) {
    db.prepare("UPDATE Rooms SET seed_status = 'idle' WHERE code = ?").run(roomCode);
    broadcastRoomState(roomCode);
    throw error;
  }
}

/**
 * Ensure the server process is active if the room has a generated seed
 */
async function ensureServerRunning(roomCode: string) {
  if (activeServers.has(roomCode)) {
    return;
  }
  
  // Check if session is locked/checked out
  const session = db.prepare("SELECT locked_by FROM Sessions WHERE room_code = ?").get(roomCode) as { locked_by: string | null } | undefined;
  if (session && session.locked_by) {
    console.log(`Archipelago session for room ${roomCode} is currently checked out by ${session.locked_by}. Auto-start skipped.`);
    return;
  }

  const room = db.prepare("SELECT seed_status, seed_zip_name, hosting_mode FROM Rooms WHERE code = ?").get(roomCode) as { seed_status: string; seed_zip_name: string | null; hosting_mode: string } | undefined;
  if (room && !getHostingProvider(room.hosting_mode).managesLocalProcess) {
    return;
  }
  if (room && room.seed_status === 'done' && room.seed_zip_name) {
    console.log(`Archipelago server is not running for room ${roomCode} but seed is done. Auto-starting...`);
    try {
      await startCentralServer(roomCode, room.seed_zip_name);
    } catch (e) {
      console.error(`Failed to automatically start server for room ${roomCode}:`, e);
    }
  }
}

/**
 * Generate a unique 6-character room code
 */
function generateRoomCode(): string {
  let code = '';
  const len = ROOM_CODE_CHARACTERS.length;
  for (let attempt = 0; attempt < 10; attempt++) {
    code = '';
    for (let i = 0; i < 6; i++) {
      code += ROOM_CODE_CHARACTERS.charAt(Math.floor(Math.random() * len));
    }
    const exists = db.prepare('SELECT 1 FROM Rooms WHERE code = ?').get(code);
    if (!exists) {
      return code;
    }
  }
  throw new Error('Failed to generate a unique room code');
}

/**
 * Fetch and format current room state (list of players)
 */
function getRoomState(roomCode: string): PlayerState[] {
  const room = db.prepare('SELECT host_id FROM Rooms WHERE code = ?').get(roomCode) as { host_id: string } | undefined;
  if (!room) return [];

  const users = db.prepare('SELECT id, name, games, is_ready, is_connected, yaml FROM Users WHERE room_code = ?').all(roomCode) as Array<{
    id: string;
    name: string;
    games: string;
    is_ready: number;
    is_connected: number;
    yaml: string | null;
  }>;

  return users.map((u) => {
    let parsedGames: string[] = [];
    try {
      parsedGames = JSON.parse(u.games || '[]');
    } catch (e) {
      parsedGames = [];
    }
    return {
      userId: u.id,
      name: u.name,
      games: parsedGames,
      isReady: u.is_ready === 1,
      isConnected: u.is_connected === 1,
      isHost: u.id === room.host_id,
      yaml: u.yaml,
    };
  });
}

/**
 * Broadcast general message to all connected players in a room
 */
function broadcastToRoom(roomCode: string, message: ServerMessage) {
  const payload = JSON.stringify(message);
  const players = getRoomState(roomCode);
  const roomUserIds = players.filter((p) => p.isConnected).map((p) => p.userId);
  for (const userId of roomUserIds) {
    const ws = activeConnections.get(userId);
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(payload);
    }
  }
}

export function broadcastRoomState(roomCode: string) {
  const room = db.prepare("SELECT seed_status, seed_zip_name, seed_spoiler_name, tunnel_url, hosting_mode, hosting_status, hosting_room_url, hosting_server_url FROM Rooms WHERE code = ?").get(roomCode) as {
    seed_status: 'idle' | 'generating' | 'done';
    seed_zip_name: string | null;
    seed_spoiler_name: string | null;
    tunnel_url: string | null;
    hosting_mode: 'wayfinder_backend' | 'archipelago_gg';
    hosting_status: string | null;
    hosting_room_url: string | null;
    hosting_server_url: string | null;
  } | undefined;

  const session = db.prepare("SELECT locked_by FROM Sessions WHERE room_code = ?").get(roomCode) as { locked_by: string | null } | undefined;
  const lockedBy = session ? session.locked_by : null;

  const players = getRoomState(roomCode);
  broadcastToRoom(roomCode, {
    type: 'room_state',
    roomCode,
    players,
    seedStatus: room ? room.seed_status : 'idle',
    seedZipName: room ? room.seed_zip_name : null,
    seedSpoilerName: room ? room.seed_spoiler_name : null,
    tunnelUrl: room ? room.tunnel_url : null,
    hostingMode: room?.hosting_mode || 'wayfinder_backend',
    hostingStatus: room?.hosting_status || null,
    hostingRoomUrl: room?.hosting_room_url || null,
    hostingServerUrl: room?.hosting_server_url || null,
    lockedBy: lockedBy,
    checks: roomChecksCache.get(roomCode) || null,
  });
}

export function broadcastChecks(roomCode: string) {
  const checks = roomChecksCache.get(roomCode);
  if (checks) {
    broadcastToRoom(roomCode, {
      type: 'checks_updated',
      checks
    });
  }
}

function sendToSocket(ws: WebSocket, message: ServerMessage) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(message));
  }
}

/**
 * Handle host seed generation request
 */
async function handleGenerateSeed(ws: WebSocket) {
  const meta = connectionMetadata.get(ws);
  if (!meta) {
    return sendToSocket(ws, { type: 'error', message: 'Not connected to a room' });
  }

  const { userId, roomCode } = meta;

  const room = db.prepare("SELECT host_id, seed_status, hosting_mode FROM Rooms WHERE code = ?").get(roomCode) as { host_id: string, seed_status: string; hosting_mode: string } | undefined;
  if (!room) {
    return sendToSocket(ws, { type: 'error', message: 'Room not found' });
  }
  if (room.host_id !== userId) {
    return sendToSocket(ws, { type: 'error', message: 'Only the host can generate the seed' });
  }
  if (room.seed_status === 'generating') {
    return sendToSocket(ws, { type: 'error', message: 'Seed generation is already in progress for this room' });
  }
  if (room.seed_status === 'done') {
    return sendToSocket(ws, { type: 'error', message: 'Seed has already been generated and locked for this room' });
  }

  const players = getRoomState(roomCode);
  if (players.length === 0) {
    return sendToSocket(ws, { type: 'error', message: 'Lobby has no players' });
  }

  const unready = players.filter(p => !p.isReady);
  if (unready.length > 0) {
    return sendToSocket(ws, { type: 'error', message: 'Cannot generate: waiting for all players to be ready' });
  }

  try {
    db.prepare("UPDATE Rooms SET seed_status = 'generating', updated_at = CURRENT_TIMESTAMP WHERE code = ?").run(roomCode);
    console.log(`Room ${roomCode} seed status updated to generating.`);
    broadcastRoomState(roomCode);

    const playersYamls = db.prepare("SELECT name, yaml FROM Users WHERE room_code = ?").all(roomCode) as Array<{ name: string, yaml: string }>;

    const { zipName, spoilerName } = await generateSeed(roomCode, playersYamls, (line) => {
      broadcastToRoom(roomCode, { type: 'generation_log', line });
    });

    clearRoomSeedData(roomCode);
    const provider = getHostingProvider(room.hosting_mode);
    if (provider.mode === 'archipelago_gg') {
      broadcastToRoom(roomCode, { type: 'generation_log', line: 'Uploading generated seed to Archipelago.gg...' });
    }
    const hosting = await provider.hostSeed(
      roomCode,
      path.join(BACKEND_ROOT, 'temp_seeds', roomCode, 'outputs', zipName),
      zipName
    );
    if (provider.mode === 'archipelago_gg') {
      broadcastToRoom(roomCode, { type: 'generation_log', line: hosting.serverUrl
        ? `Archipelago.gg room ready at ${hosting.serverUrl}`
        : 'Archipelago.gg room created; waiting for the hosted server port...' });
    }
    db.prepare("UPDATE Rooms SET seed_status = 'done', seed_zip_name = ?, seed_spoiler_name = ?, hosting_seed_id = ?, hosting_room_id = ?, hosting_room_url = ?, hosting_server_url = ?, hosting_status = ?, hosting_last_activity = ?, hosting_timeout = ?, hosting_last_error = NULL, hosting_updated_at = CURRENT_TIMESTAMP, tunnel_url = COALESCE(?, tunnel_url) WHERE code = ?").run(
      zipName,
      spoilerName,
      hosting.seedId,
      hosting.roomId,
      hosting.roomUrl,
      hosting.serverUrl,
      hosting.status,
      hosting.lastActivity,
      hosting.timeout,
      hosting.serverUrl,
      roomCode
    );

    await fetchRoomChecks(roomCode);

    console.log(`Room ${roomCode} seed generation completed successfully.`);
    broadcastRoomState(roomCode);
  } catch (error: any) {
    console.error(`Seed generation failed for room ${roomCode}:`, error);
    
    try {
      const failedGenDir = path.join(BACKEND_ROOT, 'failed_generations');
      if (!fs.existsSync(failedGenDir)) {
        fs.mkdirSync(failedGenDir, { recursive: true });
      }
      const tempLogPath = path.join(BACKEND_ROOT, 'temp_seeds', roomCode, 'outputs', 'generation.log');
      if (fs.existsSync(tempLogPath)) {
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const destLogPath = path.join(failedGenDir, `failed_${roomCode}_${timestamp}.log`);
        fs.copyFileSync(tempLogPath, destLogPath);
        console.log(`Failed generation log copied to: ${destLogPath}`);
      }
    } catch (logErr) {
      console.error('Failed to copy error logs:', logErr);
    }

    db.prepare("UPDATE Rooms SET seed_status = 'idle' WHERE code = ?").run(roomCode);
    broadcastRoomState(roomCode);
    sendToSocket(ws, { type: 'error', message: `Generation failed: ${error.message}` });
  }
}

/**
 * Handle kicking a player initiated by a WebSocket client (host)
 */
function handleKickPlayer(ws: WebSocket, targetUserId: string) {
  const meta = connectionMetadata.get(ws);
  if (!meta) {
    return sendToSocket(ws, { type: 'error', message: 'Not connected to a room' });
  }

  const { userId, roomCode } = meta;
  const room = db.prepare("SELECT host_id FROM Rooms WHERE code = ?").get(roomCode) as { host_id: string } | undefined;
  if (!room || room.host_id !== userId) {
    return sendToSocket(ws, { type: 'error', message: 'Only the room host can kick players.' });
  }

  if (targetUserId === userId) {
    return sendToSocket(ws, { type: 'error', message: 'Host cannot kick themselves.' });
  }

  const targetUser = db.prepare("SELECT id, name FROM Users WHERE id = ? AND room_code = ?").get(targetUserId, roomCode) as { id: string; name: string } | undefined;
  if (!targetUser) {
    return sendToSocket(ws, { type: 'error', message: 'Target player not found in room.' });
  }

  const targetWs = activeConnections.get(targetUserId);
  if (targetWs) {
    sendToSocket(targetWs, { type: 'kicked', message: 'You have been kicked from the room by the host.' });
    try {
      targetWs.close();
    } catch (e) {}
    activeConnections.delete(targetUserId);
    connectionMetadata.delete(targetWs);
  }

  db.prepare("DELETE FROM Users WHERE id = ?").run(targetUserId);
  console.log(`Player ${targetUser.name} (${targetUserId}) was kicked from room ${roomCode} by host.`);

  broadcastRoomState(roomCode);
}

/**
 * Handles incoming WebSocket connection messages
 */
export function handleConnection(ws: WebSocket) {
  console.log(`[${CONNECTION_KIND}] New WebSocket connection established.`);
  (ws as any).isAlive = true;

  ws.on('pong', () => {
    (ws as any).isAlive = true;
  });

function sanitizeForLog(obj: any): any {
  if (!obj || typeof obj !== 'object') return obj;
  if (Array.isArray(obj)) return obj.map(sanitizeForLog);
  const out: Record<string, any> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (k === 'yaml' && typeof v === 'string') {
      out[k] = `<yaml: ${v.length} chars>`;
    } else if (k === 'players' && Array.isArray(v)) {
      out[k] = v.map((p: any) => {
        if (p && typeof p === 'object' && typeof p.yaml === 'string') {
          return { ...p, yaml: `<yaml: ${p.yaml.length} chars>` };
        }
        return sanitizeForLog(p);
      });
    } else if (v && typeof v === 'object') {
      out[k] = sanitizeForLog(v);
    } else {
      out[k] = v;
    }
  }
  return out;
}

  ws.on('message', (rawData) => {
    try {
      const data: ClientMessage = JSON.parse(rawData.toString());
      if ((data.type as any) !== 'ping' && (data.type as any) !== 'pong') {
        console.log('Received message:', sanitizeForLog(data));
      }

      (ws as any).isAlive = true;

      switch (data.type) {
        case 'ping' as any:
          sendToSocket(ws, { type: 'pong' } as any);
          break;

        case 'pong' as any:
          break;

        case 'create_room':
          handleCreateRoom(ws, data.playerName);
          break;

        case 'join_room':
          handleJoinRoom(ws, data.roomCode.toUpperCase(), data.playerName);
          break;

        case 'reconnect':
          handleReconnect(ws, data.userId, data.roomCode.toUpperCase());
          break;

        case 'update_state':
          handleUpdateState(ws, data.games, data.isReady, data.yaml);
          break;

        case 'generate_seed':
          handleGenerateSeed(ws);
          break;

        case 'kick_player':
          handleKickPlayer(ws, data.targetUserId);
          break;

        default:
          sendToSocket(ws, { type: 'error', message: 'Unknown message type' });
      }
    } catch (error: any) {
      console.error('Error handling WebSocket message:', error);
      sendToSocket(ws, { type: 'error', message: 'Invalid message format or server error' });
    }
  });

  ws.on('close', () => {
    handleDisconnect(ws);
  });

  ws.on('error', (err) => {
    console.error('WebSocket connection error:', err);
    handleDisconnect(ws);
  });
}

function handleCreateRoom(ws: WebSocket, playerName: string) {
  if (!playerName || playerName.trim() === '') {
    return sendToSocket(ws, { type: 'error', message: 'Player name is required' });
  }

  const roomCode = generateRoomCode();
  const userId = uuidv4();

  const transaction = db.transaction(() => {
    db.prepare('INSERT INTO Rooms (code, host_id) VALUES (?, ?)').run(roomCode, userId);
    db.prepare('INSERT INTO Users (id, room_code, name, is_connected) VALUES (?, ?, ?, 1)').run(
      userId,
      roomCode,
      playerName.trim()
    );
    db.prepare('INSERT INTO Sessions (room_code) VALUES (?)').run(roomCode);
  });

  try {
    transaction();

    activeConnections.set(userId, ws);
    connectionMetadata.set(ws, { userId, roomCode });

    console.log(`Room ${roomCode} created by host ${playerName} (${userId})`);
    sendToSocket(ws, { type: 'room_created', roomCode, userId });
    broadcastRoomState(roomCode);
  } catch (error: any) {
    console.error('Transaction failed while creating room:', error);
    sendToSocket(ws, { type: 'error', message: 'Failed to create room' });
  }
}

function handleJoinRoom(ws: WebSocket, roomCode: string, playerName: string) {
  if (!playerName || playerName.trim() === '') {
    return sendToSocket(ws, { type: 'error', message: 'Player name is required' });
  }

  const room = db.prepare("SELECT code FROM Rooms WHERE code = ? AND status = 'active'").get(roomCode);
  if (!room) {
    return sendToSocket(ws, { type: 'error', message: `Room ${roomCode} not found or inactive` });
  }

  ensureServerRunning(roomCode).catch(e => console.error("ensureServerRunning failed:", e));

  const existingUser = db.prepare('SELECT id, is_connected FROM Users WHERE room_code = ? AND name = ? COLLATE NOCASE').get(roomCode, playerName.trim()) as { id: string; is_connected: number } | undefined;
  
  if (existingUser) {
    if (existingUser.is_connected === 1) {
      return sendToSocket(ws, { type: 'error', message: `Name "${playerName}" is already taken and actively connected in room ${roomCode}` });
    }
    
    const userId = existingUser.id;
    try {
      db.prepare('UPDATE Users SET is_connected = 1 WHERE id = ?').run(userId);
      activeConnections.set(userId, ws);
      connectionMetadata.set(ws, { userId, roomCode });
      
      console.log(`Player ${playerName} (${userId}) took over disconnected slot in room ${roomCode}`);
      
      const roomInfo = db.prepare("SELECT seed_status, seed_zip_name, seed_spoiler_name, tunnel_url, hosting_mode, hosting_status, hosting_room_url, hosting_server_url FROM Rooms WHERE code = ?").get(roomCode) as {
        seed_status: 'idle' | 'generating' | 'done';
        seed_zip_name: string | null;
        seed_spoiler_name: string | null;
        tunnel_url: string | null;
        hosting_mode: 'wayfinder_backend' | 'archipelago_gg';
        hosting_status: string | null;
        hosting_room_url: string | null;
        hosting_server_url: string | null;
      } | undefined;
      const session = db.prepare("SELECT locked_by FROM Sessions WHERE room_code = ?").get(roomCode) as { locked_by: string | null } | undefined;
      const players = getRoomState(roomCode);
      sendToSocket(ws, {
        type: 'room_joined',
        roomCode,
        userId,
        players,
        seedStatus: roomInfo ? roomInfo.seed_status : 'idle',
        seedZipName: roomInfo ? roomInfo.seed_zip_name : null,
        seedSpoilerName: roomInfo ? roomInfo.seed_spoiler_name : null,
        tunnelUrl: roomInfo ? roomInfo.tunnel_url : null,
        hostingMode: roomInfo?.hosting_mode || 'wayfinder_backend',
        hostingStatus: roomInfo?.hosting_status || null,
        hostingRoomUrl: roomInfo?.hosting_room_url || null,
        hostingServerUrl: roomInfo?.hosting_server_url || null,
        lockedBy: session ? session.locked_by : null,
        checks: roomChecksCache.get(roomCode) || null
      });
      touchRoomActivity(roomCode);
      broadcastRoomState(roomCode);
      return;
    } catch (error: any) {
      console.error('Failed to take over slot:', error);
      return sendToSocket(ws, { type: 'error', message: 'Failed to join room' });
    }
  }

  const userId = uuidv4();

  try {
    db.prepare('INSERT INTO Users (id, room_code, name, is_connected) VALUES (?, ?, ?, 1)').run(
      userId,
      roomCode,
      playerName.trim()
    );

    activeConnections.set(userId, ws);
    connectionMetadata.set(ws, { userId, roomCode });

    console.log(`Player ${playerName} (${userId}) joined room ${roomCode}`);

    const roomInfo = db.prepare("SELECT seed_status, seed_zip_name, seed_spoiler_name, tunnel_url FROM Rooms WHERE code = ?").get(roomCode) as {
      seed_status: 'idle' | 'generating' | 'done';
      seed_zip_name: string | null;
      seed_spoiler_name: string | null;
      tunnel_url: string | null;
    } | undefined;
    const session = db.prepare("SELECT locked_by FROM Sessions WHERE room_code = ?").get(roomCode) as { locked_by: string | null } | undefined;
    const players = getRoomState(roomCode);
    sendToSocket(ws, {
      type: 'room_joined',
      roomCode,
      userId,
      players,
      seedStatus: roomInfo ? roomInfo.seed_status : 'idle',
      seedZipName: roomInfo ? roomInfo.seed_zip_name : null,
      seedSpoilerName: roomInfo ? roomInfo.seed_spoiler_name : null,
      tunnelUrl: roomInfo ? roomInfo.tunnel_url : null,
      lockedBy: session ? session.locked_by : null,
      checks: roomChecksCache.get(roomCode) || null
    });

    touchRoomActivity(roomCode);
    broadcastRoomState(roomCode);
  } catch (error: any) {
    console.error('Failed to join room:', error);
    sendToSocket(ws, { type: 'error', message: 'Failed to join room' });
  }
}

function handleReconnect(ws: WebSocket, userId: string, roomCode: string) {
  const user = db.prepare('SELECT id, name, room_code FROM Users WHERE id = ? AND room_code = ?').get(userId, roomCode) as {
    id: string;
    name: string;
    room_code: string;
  } | undefined;

  if (!user) {
    return sendToSocket(ws, { type: 'error', message: 'Session details not found' });
  }

  ensureServerRunning(roomCode).catch(e => console.error("ensureServerRunning failed:", e));

  try {
    const oldWs = activeConnections.get(userId);
    if (oldWs && oldWs !== ws) {
      console.log(`[${CONNECTION_KIND}] Closing stale socket connection for user ${userId} (replaced by a reconnect)`);
      connectionMetadata.delete(oldWs);
      oldWs.close();
    }

    db.prepare('UPDATE Users SET is_connected = 1 WHERE id = ?').run(userId);

    activeConnections.set(userId, ws);
    connectionMetadata.set(ws, { userId, roomCode });

    console.log(`Player ${user.name} (${userId}) reconnected to room ${roomCode}`);

    const roomInfo = db.prepare("SELECT seed_status, seed_zip_name, seed_spoiler_name, tunnel_url FROM Rooms WHERE code = ?").get(roomCode) as {
      seed_status: 'idle' | 'generating' | 'done';
      seed_zip_name: string | null;
      seed_spoiler_name: string | null;
      tunnel_url: string | null;
    } | undefined;
    const session = db.prepare("SELECT locked_by FROM Sessions WHERE room_code = ?").get(roomCode) as { locked_by: string | null } | undefined;
    const players = getRoomState(roomCode);
    sendToSocket(ws, {
      type: 'room_joined',
      roomCode,
      userId,
      players,
      seedStatus: roomInfo ? roomInfo.seed_status : 'idle',
      seedZipName: roomInfo ? roomInfo.seed_zip_name : null,
      seedSpoilerName: roomInfo ? roomInfo.seed_spoiler_name : null,
      tunnelUrl: roomInfo ? roomInfo.tunnel_url : null,
      lockedBy: session ? session.locked_by : null,
      checks: roomChecksCache.get(roomCode) || null
    });

    touchRoomActivity(roomCode);
    broadcastRoomState(roomCode);
  } catch (error: any) {
    console.error('Failed to reconnect player:', error);
    sendToSocket(ws, { type: 'error', message: 'Failed to reconnect session' });
  }
}

function handleUpdateState(ws: WebSocket, games: string[], isReady: boolean, yaml: string | null) {
  const meta = connectionMetadata.get(ws);
  if (!meta) {
    return sendToSocket(ws, { type: 'error', message: 'Not connected to a room' });
  }

  const { userId, roomCode } = meta;

  const room = db.prepare("SELECT seed_status FROM Rooms WHERE code = ?").get(roomCode) as { seed_status: string } | undefined;
  if (room && room.seed_status === 'done') {
    return sendToSocket(ws, { type: 'error', message: 'Room configuration is locked after seed generation' });
  }

  try {
    const gamesJson = JSON.stringify(games || []);
    db.prepare('UPDATE Users SET games = ?, is_ready = ?, yaml = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?').run(
      gamesJson,
      isReady ? 1 : 0,
      yaml,
      userId
    );

    console.log(`Player ${userId} in room ${roomCode} updated games to ${gamesJson}, ready: ${isReady}, yaml length: ${yaml ? yaml.length : 0}`);

    touchRoomActivity(roomCode);
    broadcastRoomState(roomCode);
  } catch (error: any) {
    console.error('Failed to update player state:', error);
    sendToSocket(ws, { type: 'error', message: 'Failed to update ready state' });
  }
}

/**
 * Check if any game clients are currently connected to the AP server port
 */
export async function hasActiveTcpClients(port: number): Promise<boolean> {
  try {
    const cmd = process.platform === 'win32'
      ? `netstat -ano | findstr :${port}`
      : `netstat -an | grep :${port}`;
    const { stdout } = await execAsync(cmd);
    return stdout.includes('ESTABLISHED');
  } catch (e) {
    return false;
  }
}

// Audit active AP servers every 30 seconds to clean up when both lobby users and AP clients disconnect
setInterval(async () => {
  for (const [roomCode, server] of activeServers.entries()) {
    const connectedCount = db.prepare("SELECT COUNT(*) as count FROM Users WHERE room_code = ? AND is_connected = 1").get(roomCode) as { count: number } | undefined;
    const lobbyConnected = connectedCount ? connectedCount.count > 0 : false;
    
    if (!lobbyConnected) {
      const hasClients = await hasActiveTcpClients(server.port);
      if (!hasClients) {
        console.log(`Periodic Cleanup: No lobby users or game clients connected to room ${roomCode} (port ${server.port}). Stopping AP server.`);
        killRoomServer(roomCode);
      }
    }
  }
}, 30000);

function handleDisconnect(ws: WebSocket) {
  const meta = connectionMetadata.get(ws);
  if (!meta) return;

  const { userId, roomCode } = meta;

  connectionMetadata.delete(ws);
  if (activeConnections.get(userId) === ws) {
    activeConnections.delete(userId);
  }

  try {
    db.prepare('UPDATE Users SET is_connected = 0 WHERE id = ?').run(userId);
    console.log(`Player ${userId} disconnected from room ${roomCode}`);
    broadcastRoomState(roomCode);

    const connectedCount = db.prepare("SELECT COUNT(*) as count FROM Users WHERE room_code = ? AND is_connected = 1").get(roomCode) as { count: number } | undefined;
    if (connectedCount && connectedCount.count === 0) {
      const server = activeServers.get(roomCode);
      if (server) {
        hasActiveTcpClients(server.port).then((hasClients) => {
          if (hasClients) {
            console.log(`Lobby users disconnected from room ${roomCode}, but game clients are still connected on port ${server.port}. Keeping AP server active.`);
          } else {
            const recheck = db.prepare("SELECT COUNT(*) as count FROM Users WHERE room_code = ? AND is_connected = 1").get(roomCode) as { count: number } | undefined;
            if (recheck && recheck.count > 0) {
              console.log(`User reconnected to room ${roomCode} during cleanup check. Keeping AP server active.`);
              return;
            }
            killRoomServer(roomCode);
          }
        }).catch(() => {
          const recheck = db.prepare("SELECT COUNT(*) as count FROM Users WHERE room_code = ? AND is_connected = 1").get(roomCode) as { count: number } | undefined;
          if (recheck && recheck.count > 0) return;
          killRoomServer(roomCode);
        });
      } else {
        killRoomServer(roomCode);
      }
    }
  } catch (error: any) {
    console.error('Error during player disconnection cleanup:', error);
  }
}

export function kickPlayer(roomCode: string, userId: string): boolean {
  const user = db.prepare("SELECT id, name FROM Users WHERE id = ? AND room_code = ?").get(userId, roomCode) as { id: string; name: string } | undefined;
  if (!user) return false;

  const ws = activeConnections.get(userId);
  if (ws) {
    try {
      sendToSocket(ws, { type: 'kicked', message: 'You have been kicked from the room by the host.' });
      ws.close();
    } catch (e) {}
    activeConnections.delete(userId);
    connectionMetadata.delete(ws);
  }

  db.prepare("DELETE FROM Users WHERE id = ?").run(userId);

  const room = db.prepare("SELECT host_id FROM Rooms WHERE code = ?").get(roomCode) as { host_id: string } | undefined;
  if (room && room.host_id === userId) {
    const nextPlayer = db.prepare("SELECT id FROM Users WHERE room_code = ? LIMIT 1").get(roomCode) as { id: string } | undefined;
    const newHostId = nextPlayer ? nextPlayer.id : '';
    db.prepare("UPDATE Rooms SET host_id = ? WHERE code = ?").run(newHostId, roomCode);
  }

  broadcastRoomState(roomCode);
  return true;
}

export async function closeRoom(roomCode: string) {
  const room = db.prepare('SELECT hosting_mode, hosting_seed_id, hosting_room_id FROM Rooms WHERE code = ?').get(roomCode) as {
    hosting_mode: string;
    hosting_seed_id: string | null;
    hosting_room_id: string | null;
  } | undefined;
  if (!room) {
    throw new Error(`Room ${roomCode} not found.`);
  }
  await getHostingProvider(room.hosting_mode).markForDeletion({
    roomCode,
    seedId: room.hosting_seed_id,
    roomId: room.hosting_room_id
  });
  getHostingProvider(room.hosting_mode).stop(roomCode);
  broadcastToRoom(roomCode, { type: 'room_deleted', message: 'This room has been closed by the host.' });

  for (const [ws, meta] of connectionMetadata.entries()) {
    if (meta.roomCode === roomCode) {
      activeConnections.delete(meta.userId);
      connectionMetadata.delete(ws);
      try {
        ws.close();
      } catch (e) {}
    }
  }
}

export function setPlayerReady(roomCode: string, userId: string, isReady: boolean): boolean {
  const user = db.prepare("SELECT id FROM Users WHERE id = ? AND room_code = ?").get(userId, roomCode);
  if (!user) return false;

  db.prepare("UPDATE Users SET is_ready = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?").run(isReady ? 1 : 0, userId);
  broadcastRoomState(roomCode);
  return true;
}

export function transferRoomHost(roomCode: string, newHostId: string): boolean {
  const user = db.prepare("SELECT id FROM Users WHERE id = ? AND room_code = ?").get(newHostId, roomCode);
  if (!user) return false;

  db.prepare("UPDATE Rooms SET host_id = ? WHERE code = ?").run(newHostId, roomCode);
  broadcastRoomState(roomCode);
  return true;
}
