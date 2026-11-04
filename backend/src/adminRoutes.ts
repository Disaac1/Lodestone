import { Router, Request, Response, NextFunction } from 'express';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import multer from 'multer';
import AdmZip from 'adm-zip';
import db, { purgeInactiveRooms } from './db.js';
import {
  activeServers,
  killRoomServer,
  broadcastRoomState,
  sendServerCommand,
  startRoomServer,
  regenerateRoomSeed,
  kickPlayer,
  setPlayerReady,
  transferRoomHost
} from './roomManager.js';
import { clearCache, generateYamlTemplatesZip, invalidateTemplatesCache } from './archipelagoRunner.js';
import { getLogs, clearLogs, addLog } from './logger.js';
import { loadRegistry, downloadFromUpstream } from './customWorldRoutes.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const BACKEND_ROOT = path.join(__dirname, '..');
const CUSTOM_WORLDS_DIR = path.join(BACKEND_ROOT, 'archipelago_core', 'custom_worlds');

/**
 * Middleware to restrict access strictly to localhost requests (127.0.0.1 or ::1)
 */
export function localhostOnly(req: Request, res: Response, next: NextFunction) {
  // If running behind a reverse proxy (e.g. Traefik) that enforces authentication
  if (process.env.ALLOW_PROXY_ADMIN === 'true') {
    return next();
  }
  const remoteIp = req.socket.remoteAddress || req.ip || '';
  const hostHeader = req.headers.host || '';

  const isLocalIp =
    remoteIp === '127.0.0.1' ||
    remoteIp === '::1' ||
    remoteIp === '::ffff:127.0.0.1';

  const isLocalHostHeader =
    hostHeader.startsWith('localhost:') ||
    hostHeader === 'localhost' ||
    hostHeader.startsWith('127.0.0.1:') ||
    hostHeader === '127.0.0.1' ||
    hostHeader.startsWith('[::1]:') ||
    hostHeader === '[::1]';

  if (!isLocalIp || !isLocalHostHeader) {
    return res.status(403).json({
      error: 'Forbidden: Access to Web UI administration is strictly limited to localhost.'
    });
  }

  next();
}

const upload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => {
      if (!fs.existsSync(CUSTOM_WORLDS_DIR)) {
        fs.mkdirSync(CUSTOM_WORLDS_DIR, { recursive: true });
      }
      cb(null, CUSTOM_WORLDS_DIR);
    },
    filename: (req, file, cb) => {
      cb(null, file.originalname);
    }
  }),
  fileFilter: (req, file, cb) => {
    if (file.originalname.endsWith('.apworld')) {
      cb(null, true);
    } else {
      cb(new Error('Only .apworld files are allowed'));
    }
  }
});

const router = Router();

// Apply localhost check to all admin routes
router.use(localhostOnly);

/**
 * GET /api/admin/overview
 * System vitals and aggregate metrics
 */
router.get('/overview', (req: Request, res: Response) => {
  try {
    const totalRooms = (db.prepare('SELECT COUNT(*) as count FROM Rooms').get() as any)?.count || 0;
    const activeRooms = (db.prepare("SELECT COUNT(*) as count FROM Rooms WHERE status = 'active'").get() as any)?.count || 0;
    const totalUsers = (db.prepare('SELECT COUNT(*) as count FROM Users').get() as any)?.count || 0;
    const connectedUsers = (db.prepare('SELECT COUNT(*) as count FROM Users WHERE is_connected = 1').get() as any)?.count || 0;
    const lockedSessions = (db.prepare('SELECT COUNT(*) as count FROM Sessions WHERE locked_by IS NOT NULL').get() as any)?.count || 0;

    let apWorldCount = 0;
    if (fs.existsSync(CUSTOM_WORLDS_DIR)) {
      apWorldCount = fs.readdirSync(CUSTOM_WORLDS_DIR).filter(f => f.endsWith('.apworld')).length;
    }

    res.json({
      status: 'online',
      uptimeSeconds: process.uptime(),
      memoryUsage: process.memoryUsage(),
      nodeVersion: process.version,
      stats: {
        totalRooms,
        activeRooms,
        totalUsers,
        connectedUsers,
        lockedSessions,
        activeServersCount: activeServers.size,
        apWorldCount
      }
    });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * GET /api/admin/rooms
 * Detailed list of all rooms
 */
router.get('/rooms', (req: Request, res: Response) => {
  try {
    const rooms = db.prepare(`
      SELECT 
        r.code, 
        r.host_id, 
        r.status, 
        r.seed_status, 
        r.seed_zip_name, 
        r.seed_spoiler_name, 
        r.tunnel_url, 
        r.created_at,
        s.locked_by,
        s.locked_at
      FROM Rooms r
      LEFT JOIN Sessions s ON r.code = s.room_code
      ORDER BY r.created_at DESC
    `).all() as any[];

    const enrichedRooms = rooms.map(room => {
      const users = db.prepare(`
        SELECT id, name, games, is_ready, is_connected, updated_at 
        FROM Users 
        WHERE room_code = ?
      `).all(room.code) as any[];

      const isServerRunning = activeServers.has(room.code);
      const serverDetails = activeServers.get(room.code);

      return {
        ...room,
        isServerRunning,
        serverPort: serverDetails ? serverDetails.port : null,
        serverPid: serverDetails?.child ? serverDetails.child.pid : null,
        players: users.map(u => ({
          ...u,
          games: (() => {
            try { return JSON.parse(u.games || '[]'); } catch (e) { return []; }
          })(),
          isReady: u.is_ready === 1,
          isConnected: u.is_connected === 1,
          isHost: u.id === room.host_id
        }))
      };
    });

    res.json({ rooms: enrichedRooms });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/admin/rooms/:code/kill
 * Terminate Archipelago MultiServer process for room
 */
router.post('/rooms/:code/kill', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  try {
    if (!activeServers.has(code)) {
      return res.status(404).json({ error: `No active AP Server running for room ${code}` });
    }
    killRoomServer(code);
    broadcastRoomState(code);
    res.json({ success: true, message: `Terminated Archipelago server for room ${code}` });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/admin/rooms/:code/start-server
 * Start / restart Central Archipelago MultiServer process for room
 */
router.post('/rooms/:code/start-server', async (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  try {
    await startRoomServer(code);
    res.json({ success: true, message: `MultiServer launched for room ${code}` });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/admin/rooms/:code/regenerate
 * Trigger multiworld seed generation for room using player YAMLs
 */
router.post('/rooms/:code/regenerate', async (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  try {
    const result = await regenerateRoomSeed(code);
    res.json({ success: true, message: `Successfully regenerated seed for room ${code}`, ...result });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/admin/rooms/:code/unlock
 * Force unlock save session lock
 */
router.post('/rooms/:code/unlock', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  try {
    db.prepare(`
      INSERT INTO Sessions (room_code, locked_by, locked_at, updated_at)
      VALUES (?, NULL, NULL, CURRENT_TIMESTAMP)
      ON CONFLICT(room_code) DO UPDATE SET
        locked_by = NULL,
        locked_at = NULL,
        updated_at = CURRENT_TIMESTAMP
    `).run(code);

    broadcastRoomState(code);
    res.json({ success: true, message: `Force unlocked session for room ${code}` });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * DELETE /api/admin/rooms/:code
 * Delete room and remove temp files
 */
router.delete('/rooms/:code', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  try {
    killRoomServer(code);

    const tempSeedsDir = path.join(BACKEND_ROOT, 'temp_seeds', code);
    if (fs.existsSync(tempSeedsDir)) {
      fs.rmSync(tempSeedsDir, { recursive: true, force: true });
    }

    db.prepare('DELETE FROM Users WHERE room_code = ?').run(code);
    db.prepare('DELETE FROM Sessions WHERE room_code = ?').run(code);
    db.prepare('DELETE FROM Rooms WHERE code = ?').run(code);

    res.json({ success: true, message: `Deleted room ${code} and cleaned up assets.` });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * Helper to locate spoiler file on disk with automatic zip extraction and DB recovery fallback
 */
function findRoomSpoilerFile(code: string, recordedName?: string | null): string | null {
  const outputsDir = path.join(BACKEND_ROOT, 'temp_seeds', code, 'outputs');
  if (!fs.existsSync(outputsDir)) return null;

  // 1. Check recorded name if valid
  if (recordedName && recordedName.trim()) {
    const directPath = path.join(outputsDir, recordedName.trim());
    if (fs.existsSync(directPath)) return recordedName.trim();
  }

  // 2. Scan outputs directory
  const files = fs.readdirSync(outputsDir);
  const found = files.find(f => f.toLowerCase().endsWith('_spoiler.txt') || (f.toLowerCase().includes('spoiler') && f.endsWith('.txt')));
  if (found) {
    try {
      db.prepare("UPDATE Rooms SET seed_spoiler_name = ? WHERE code = ?").run(found, code);
    } catch (e) {}
    return found;
  }

  // 3. Check inside seed zip if available
  const zipFile = files.find(f => f.endsWith('.zip'));
  if (zipFile) {
    try {
      const zipPath = path.join(outputsDir, zipFile);
      const zip = new AdmZip(zipPath);
      const spoilerEntry = zip.getEntries().find(e => e.entryName.toLowerCase().includes('spoiler') && e.entryName.endsWith('.txt'));
      if (spoilerEntry) {
        const safeName = path.basename(spoilerEntry.entryName);
        fs.writeFileSync(path.join(outputsDir, safeName), spoilerEntry.getData());
        try {
          db.prepare("UPDATE Rooms SET seed_spoiler_name = ? WHERE code = ?").run(safeName, code);
        } catch (e) {}
        return safeName;
      }
    } catch (e) {}
  }

  return null;
}

/**
 * Helper to locate seed zip file on disk with automatic DB recovery fallback
 */
function findRoomSeedZip(code: string, recordedName?: string | null): string | null {
  const outputsDir = path.join(BACKEND_ROOT, 'temp_seeds', code, 'outputs');
  if (!fs.existsSync(outputsDir)) return null;

  if (recordedName && recordedName.trim()) {
    const directPath = path.join(outputsDir, recordedName.trim());
    if (fs.existsSync(directPath)) return recordedName.trim();
  }

  const files = fs.readdirSync(outputsDir);
  const found = files.find(f => f.endsWith('.zip'));
  if (found) {
    try {
      db.prepare("UPDATE Rooms SET seed_zip_name = ? WHERE code = ?").run(found, code);
    } catch (e) {}
    return found;
  }

  return null;
}

/**
 * GET /api/admin/rooms/:code/download/seed
 * Download generated multiworld seed ZIP
 */
router.get('/rooms/:code/download/seed', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  try {
    const room = db.prepare('SELECT seed_zip_name FROM Rooms WHERE code = ?').get(code) as any;
    const zipName = findRoomSeedZip(code, room?.seed_zip_name);
    if (!zipName) {
      return res.status(404).json({ error: `Room ${code} has no generated seed archive.` });
    }
    const zipPath = path.join(BACKEND_ROOT, 'temp_seeds', code, 'outputs', zipName);
    res.download(zipPath, zipName);
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * GET /api/admin/rooms/:code/download/spoiler
 * Download or inspect seed spoiler log
 */
router.get('/rooms/:code/download/spoiler', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  try {
    const room = db.prepare('SELECT seed_spoiler_name FROM Rooms WHERE code = ?').get(code) as any;
    const spoilerName = findRoomSpoilerFile(code, room?.seed_spoiler_name);
    if (!spoilerName) {
      return res.status(404).json({ error: `Room ${code} has no spoiler log.` });
    }
    const spoilerPath = path.join(BACKEND_ROOT, 'temp_seeds', code, 'outputs', spoilerName);
    if (req.query.view === 'true') {
      const content = fs.readFileSync(spoilerPath, 'utf8');
      return res.json({ filename: spoilerName, content });
    }
    res.download(spoilerPath, spoilerName);
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * GET /api/admin/rooms/:code/generation-log
 * Inspect seed generation output / error traceback log
 */
router.get('/rooms/:code/generation-log', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  try {
    const tempLogPath = path.join(BACKEND_ROOT, 'temp_seeds', code, 'outputs', 'generation.log');
    if (fs.existsSync(tempLogPath)) {
      const content = fs.readFileSync(tempLogPath, 'utf8');
      return res.json({ found: true, source: 'generation.log', content });
    }

    const failedGenDir = path.join(BACKEND_ROOT, 'failed_generations');
    if (fs.existsSync(failedGenDir)) {
      const failedFiles = fs.readdirSync(failedGenDir).filter(f => f.includes(`_${code}_`)).sort().reverse();
      if (failedFiles.length > 0) {
        const content = fs.readFileSync(path.join(failedGenDir, failedFiles[0]), 'utf8');
        return res.json({ found: true, source: failedFiles[0], content });
      }
    }

    res.json({ found: false, content: 'No generation log file available for this room.' });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * GET /api/admin/rooms/:code/players/:id/yaml
 * View or download a player's YAML configuration
 */
router.get('/rooms/:code/players/:id/yaml', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  const id = req.params.id as string;
  try {
    const user = db.prepare('SELECT name, yaml FROM Users WHERE id = ? AND room_code = ?').get(id, code) as any;
    if (!user) {
      return res.status(404).json({ error: 'Player not found' });
    }

    if (req.query.download === 'true') {
      res.setHeader('Content-Disposition', `attachment; filename="${user.name}.yaml"`);
      res.setHeader('Content-Type', 'text/yaml');
      return res.send(user.yaml || '# No YAML configured');
    }

    res.json({ name: user.name, yaml: user.yaml || '' });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/admin/rooms/:code/players/:id/kick
 * Disconnect and remove player from room
 */
router.post('/rooms/:code/players/:id/kick', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  const id = req.params.id as string;
  try {
    const ok = kickPlayer(code, id);
    if (!ok) return res.status(404).json({ error: 'Player not found in room' });
    res.json({ success: true, message: 'Player kicked and removed from room' });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/admin/rooms/:code/players/:id/ready
 * Force update player ready status
 */
router.post('/rooms/:code/players/:id/ready', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  const id = req.params.id as string;
  try {
    const ready = req.body.ready === true || req.body.ready === 'true' || req.body.ready === 1;
    const ok = setPlayerReady(code, id, ready);
    if (!ok) return res.status(404).json({ error: 'Player not found in room' });
    res.json({ success: true, ready });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/admin/rooms/:code/players/:id/host
 * Transfer room host role to another player
 */
router.post('/rooms/:code/players/:id/host', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  const id = req.params.id as string;
  try {
    const ok = transferRoomHost(code, id);
    if (!ok) return res.status(404).json({ error: 'Player not found in room' });
    res.json({ success: true, message: 'Room host transferred' });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * GET /api/admin/custom-worlds
 * List custom .apworld packages (both enabled and disabled) with metadata
 */
router.get('/custom-worlds', (req: Request, res: Response) => {
  try {
    if (!fs.existsSync(CUSTOM_WORLDS_DIR)) {
      return res.json({ files: [] });
    }
    const allFiles = fs.readdirSync(CUSTOM_WORLDS_DIR);
    const files = allFiles
      .filter(f => f.endsWith('.apworld') || f.endsWith('.apworld.disabled'))
      .map(filename => {
        const filePath = path.join(CUSTOM_WORLDS_DIR, filename);
        const stat = fs.statSync(filePath);
        const isEnabled = !filename.endsWith('.disabled');

        let worldName = '';
        try {
          const zip = new AdmZip(filePath);
          const entries = zip.getEntries();
          const manifestEntry = entries.find(e => e.entryName.toLowerCase().endsWith('manifest.json'));
          if (manifestEntry) {
            const manifest = JSON.parse(manifestEntry.getData().toString('utf8'));
            worldName = manifest.game || manifest.name || '';
          }
          if (!worldName) {
            const topDir = entries.find(e => e.isDirectory);
            if (topDir) {
              worldName = topDir.entryName.split('/')[0];
            }
          }
        } catch (e) {
          // Fallback if zip cannot be read
        }

        return {
          filename,
          sizeBytes: stat.size,
          modifiedAt: stat.mtime,
          isEnabled,
          worldName: worldName || filename.replace(/\.apworld(\.disabled)?$/, '')
        };
      });

    res.json({ files });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/admin/custom-worlds/:filename/toggle
 * Enable or disable a custom .apworld package
 */
router.post('/custom-worlds/:filename/toggle', (req: Request, res: Response) => {
  const filename = path.basename(req.params.filename as string);
  const filePath = path.join(CUSTOM_WORLDS_DIR, filename);
  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ error: 'File not found' });
  }

  let targetFilename: string;
  if (filename.endsWith('.apworld')) {
    targetFilename = `${filename}.disabled`;
  } else if (filename.endsWith('.apworld.disabled')) {
    targetFilename = filename.replace(/\.disabled$/, '');
  } else {
    return res.status(400).json({ error: 'Invalid file extension' });
  }

  const targetPath = path.join(CUSTOM_WORLDS_DIR, targetFilename);
  fs.renameSync(filePath, targetPath);
  clearCache();
  res.json({ success: true, oldFilename: filename, newFilename: targetFilename, isEnabled: !targetFilename.endsWith('.disabled') });
});

/**
 * GET /api/admin/custom-worlds/:filename/download
 * Download a custom .apworld package
 */
router.get('/custom-worlds/:filename/download', (req: Request, res: Response) => {
  const filename = path.basename(req.params.filename as string);
  const filePath = path.join(CUSTOM_WORLDS_DIR, filename);
  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ error: 'File not found' });
  }
  res.download(filePath, filename);
});

/**
 * GET /api/admin/yaml-templates/download
 * Download all game YAML templates bundled in a ZIP archive with custom roms in /custom
 */
router.get('/yaml-templates/download', async (req: Request, res: Response) => {
  try {
    const force = req.query.force === 'true';
    const zipPath = await generateYamlTemplatesZip(force);
    res.download(zipPath, 'yaml_templates.zip');
  } catch (err: any) {
    console.error('Failed to generate yaml templates archive:', err);
    res.status(500).json({ error: 'Failed to generate YAML templates: ' + err.message });
  }
});

/**
 * POST /api/admin/custom-worlds/upload
 * Upload new .apworld file
 */
router.post('/custom-worlds/upload', upload.single('file'), (req: Request, res: Response) => {
  if (!req.file) {
    return res.status(400).json({ error: 'No file uploaded' });
  }
  if (req.file.filename.endsWith('.apworld') || req.file.originalname.endsWith('.apworld')) {
    try {
      const zip = new AdmZip(req.file.path);
      if (zip.getEntries().length === 0) throw new Error('Archive contains no files');
    } catch (zipErr: any) {
      try { fs.unlinkSync(req.file.path); } catch {}
      return res.status(400).json({ error: 'Uploaded file is not a valid .apworld archive: ' + zipErr.message });
    }
  }
  clearCache();
  res.json({ success: true, filename: req.file.filename, size: req.file.size });
});

/**
 * DELETE /api/admin/custom-worlds/:filename
 * Delete a custom .apworld file
 */

/**
 * POST /api/admin/custom-worlds/sync-upstream
 * Automatically downloads/updates custom .apworld packages from their upstream GitHub repositories.
 */
router.post('/custom-worlds/sync-upstream', async (req: Request, res: Response) => {
  try {
    const registry = loadRegistry();
    const results: Array<{ filename: string; success: boolean; repo: string }> = [];

    if (!fs.existsSync(CUSTOM_WORLDS_DIR)) {
      fs.mkdirSync(CUSTOM_WORLDS_DIR, { recursive: true });
    }

    for (const [filename, item] of Object.entries(registry)) {
      const dest = path.join(CUSTOM_WORLDS_DIR, filename);
      const success = await downloadFromUpstream(item.download_url, dest);
      results.push({ filename, success, repo: item.repo });
    }

    clearCache();
    res.json({ success: true, count: results.filter(r => r.success).length, results });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

router.delete('/custom-worlds/:filename', (req: Request, res: Response) => {
  const safeFilename = path.basename(req.params.filename as string);
  try {
    const filePath = path.join(CUSTOM_WORLDS_DIR, safeFilename);
    if (!fs.existsSync(filePath)) {
      return res.status(404).json({ error: 'File not found' });
    }
    fs.unlinkSync(filePath);
    clearCache();
    res.json({ success: true, message: `Deleted ${safeFilename}` });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * GET /api/admin/servers
 * Active Archipelago server processes list
 */
router.get('/servers', (req: Request, res: Response) => {
  try {
    const serversList = Array.from(activeServers.entries()).map(([roomCode, server]) => ({
      roomCode,
      port: server.port,
      pid: server.child ? server.child.pid : null,
      saveFilePath: server.saveFilePath,
      connected: server.child && !server.child.killed
    }));
    res.json({ servers: serversList });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/admin/servers/:code/command
 * Send Archipelago console command to running MultiServer subprocess
 */
router.post('/servers/:code/command', (req: Request, res: Response) => {
  const code = (req.params.code as string).toUpperCase();
  const command = req.body?.command;
  if (!command || typeof command !== 'string') {
    return res.status(400).json({ error: 'Command string is required' });
  }

  const ok = sendServerCommand(code, command);
  if (!ok) {
    return res.status(400).json({ error: `AP Server for room ${code} is not active or console input is unavailable.` });
  }

  res.json({ success: true, message: `Command sent to room ${code}: ${command}` });
});

/**
 * GET /api/admin/logs
 * Live log ring buffer streaming / polling endpoint
 */
router.get('/logs', (req: Request, res: Response) => {
  try {
    const sinceId = req.query.since ? parseInt(req.query.since as string, 10) : undefined;
    const limit = req.query.limit ? parseInt(req.query.limit as string, 10) : 200;
    const roomCode = req.query.roomCode ? String(req.query.roomCode).toUpperCase() : undefined;
    const source = req.query.source ? String(req.query.source) : undefined;

    const result = getLogs({ sinceId, limit, roomCode, source });
    res.json(result);
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * DELETE /api/admin/logs
 * Clear the in-memory log buffer
 */
router.delete('/logs', (req: Request, res: Response) => {
  try {
    clearLogs();
    res.json({ success: true, message: 'Logs buffer cleared' });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * GET /api/admin/db
 * Database table viewer with search and CSV export
 */
router.get('/db', (req: Request, res: Response) => {
  const table = (req.query.table as string) || 'Rooms';
  const allowedTables = ['Rooms', 'Users', 'Sessions', 'OptionsCache'];

  if (!allowedTables.includes(table)) {
    return res.status(400).json({ error: `Invalid table name. Allowed: ${allowedTables.join(', ')}` });
  }

  try {
    const format = req.query.format as string;
    const search = (req.query.search as string || '').trim().toLowerCase();
    const limit = Math.min(Math.max(parseInt(req.query.limit as string || '100', 10), 1), 500);
    const offset = Math.max(parseInt(req.query.offset as string || '0', 10), 0);

    let rows: any[] = [];
    const totalCount = (db.prepare(`SELECT COUNT(*) as count FROM ${table}`).get() as any)?.count || 0;

    if (search) {
      const allRows = db.prepare(`SELECT * FROM ${table} ORDER BY 1 DESC`).all() as any[];
      const filtered = allRows.filter(r => JSON.stringify(r).toLowerCase().includes(search));
      rows = filtered.slice(offset, offset + limit);
    } else {
      rows = db.prepare(`SELECT * FROM ${table} ORDER BY 1 DESC LIMIT ? OFFSET ?`).all(limit, offset) as any[];
    }

    if (format === 'csv') {
      if (rows.length === 0) {
        return res.attachment(`${table}.csv`).send('');
      }
      const headers = Object.keys(rows[0]);
      const csvLines = [headers.join(',')];
      for (const row of rows) {
        const line = headers.map(h => {
          let val = row[h];
          if (val === null || val === undefined) return '';
          val = String(val).replace(/"/g, '""');
          return `"${val}"`;
        }).join(',');
        csvLines.push(line);
      }
      res.setHeader('Content-Type', 'text/csv');
      return res.attachment(`${table}.csv`).send(csvLines.join('\n'));
    }

    res.json({ table, totalCount, limit, offset, rows });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/admin/purge-all
 * Delete all backend data (rooms, users, sessions, temp seeds, failed logs, active AP servers)
 */
router.post('/purge-all', (req: Request, res: Response) => {
  try {
    const includeCustomWorlds = req.body?.includeCustomWorlds === true || req.query.includeCustomWorlds === 'true';

    // 1. Kill all active Archipelago server processes
    const activeRoomCodes = Array.from(activeServers.keys());
    for (const code of activeRoomCodes) {
      killRoomServer(code);
    }

    // 2. Clear database tables
    const purgeDb = db.transaction(() => {
      db.prepare('DELETE FROM Sessions').run();
      db.prepare('DELETE FROM Users').run();
      db.prepare('DELETE FROM Rooms').run();
      db.prepare('DELETE FROM OptionsCache').run();
    });
    purgeDb();

    // 3. Clean up temp_seeds directory
    const tempSeedsDir = path.join(BACKEND_ROOT, 'temp_seeds');
    if (fs.existsSync(tempSeedsDir)) {
      const items = fs.readdirSync(tempSeedsDir);
      for (const item of items) {
        fs.rmSync(path.join(tempSeedsDir, item), { recursive: true, force: true });
      }
    }

    // 4. Clean up failed_generations directory
    const failedGenDir = path.join(BACKEND_ROOT, 'failed_generations');
    if (fs.existsSync(failedGenDir)) {
      const items = fs.readdirSync(failedGenDir);
      for (const item of items) {
        fs.rmSync(path.join(failedGenDir, item), { recursive: true, force: true });
      }
    }

    // 5. Optionally remove custom .apworld packages
    let apWorldsPurged = 0;
    if (includeCustomWorlds && fs.existsSync(CUSTOM_WORLDS_DIR)) {
      const apFiles = fs.readdirSync(CUSTOM_WORLDS_DIR).filter(f => f.endsWith('.apworld') || f.endsWith('.apworld.disabled'));
      apWorldsPurged = apFiles.length;
      for (const file of apFiles) {
        fs.unlinkSync(path.join(CUSTOM_WORLDS_DIR, file));
      }
    }

    // 6. Invalidate caches
    clearCache();
    clearLogs();

    res.json({
      success: true,
      message: `All server data successfully deleted.${apWorldsPurged > 0 ? ` (${apWorldsPurged} custom worlds removed)` : ''}`
    });
  } catch (err: any) {
    console.error('Failed to purge data:', err);
    res.status(500).json({ error: err.message || 'Failed to purge data' });
  }
});

/**
 * POST /api/admin/housekeeping
 * Trigger on-demand purge of expired soft-deleted rooms (> 7 days) and inactive rooms (> 3 months / 90 days)
 */
router.post('/housekeeping', (req: Request, res: Response) => {
  try {
    purgeInactiveRooms();
    res.json({ success: true, message: 'Housekeeping executed successfully.' });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
