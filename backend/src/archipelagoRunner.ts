import { exec, execFile, spawn } from 'child_process';
import path from 'path';
import fs from 'fs';
import os from 'os';
import AdmZip from 'adm-zip';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const WORKSPACE_ROOT = path.join(__dirname, '..', '..');
const BACKEND_ROOT = path.join(__dirname, '..');
const ARCHIPELAGO_PATH = path.join(BACKEND_ROOT, 'archipelago_core');
const CUSTOM_WORLDS_DIR = path.join(ARCHIPELAGO_PATH, 'custom_worlds');
const PARSER_SCRIPT_PATH = path.join(BACKEND_ROOT, 'src', 'parse_options.py');
const TEMPLATES_SCRIPT_PATH = path.join(BACKEND_ROOT, 'src', 'generate_templates.py');
const TEMPLATES_ZIP_PATH = path.join(BACKEND_ROOT, 'data', 'yaml_templates.zip');

console.log(`Archipelago core path: ${ARCHIPELAGO_PATH}`);
console.log(`Custom worlds path: ${CUSTOM_WORLDS_DIR}`);

// Ensure directories exist
if (!fs.existsSync(CUSTOM_WORLDS_DIR)) {
  fs.mkdirSync(CUSTOM_WORLDS_DIR, { recursive: true });
}

/**
 * Ensures MultiServer.py has keepalive ping_interval set and ping_timeout relaxed
 * so WebSocket connections through Cloudflare Tunnels do not drop due to client lag or inactivity.
 */
export function patchMultiServerKeepalive(): void {
  try {
    const multiServerPath = path.join(ARCHIPELAGO_PATH, 'MultiServer.py');
    if (!fs.existsSync(multiServerPath)) return;
    let content = fs.readFileSync(multiServerPath, 'utf-8');
    if (content.includes('extensions=[server_per_message_deflate_factory]') && !content.includes('ping_timeout=None')) {
      content = content.replace(
        'extensions=[server_per_message_deflate_factory],',
        'extensions=[server_per_message_deflate_factory],\n        ping_interval=20,\n        ping_timeout=None,'
      );
      fs.writeFileSync(multiServerPath, content, 'utf-8');
      console.log('[Archipelago Core] Patched MultiServer.py with keepalive and ping_timeout=None');
    }
  } catch (err: any) {
    console.warn('[Archipelago Core] Warning patching MultiServer keepalive:', err.message);
  }
}

/**
 * Patches Generate.py to include detailed failed_world_loads diagnostics if a world fails to load.
 */
export function patchGenerateDiagnostics(): void {
  try {
    const generatePath = path.join(ARCHIPELAGO_PATH, 'Generate.py');
    if (!fs.existsSync(generatePath)) return;
    let content = fs.readFileSync(generatePath, 'utf-8');
    if (content.includes('If so, it appears the world failed to initialize correctly.') && !content.includes('Reason:')) {
      content = content.replace(
        'f"If so, it appears the world failed to initialize correctly.")',
        'f"If so, it appears the world failed to initialize correctly. Reason: {failed_world_loads.get(picks[0])}")'
      );
      fs.writeFileSync(generatePath, content, 'utf-8');
      console.log('[Archipelago Core] Patched Generate.py with failed_world_loads diagnostics');
    }
  } catch (err: any) {
    console.warn('[Archipelago Core] Warning patching Generate diagnostics:', err.message);
  }
}

/**
 * Ensures the Archipelago core repository is cloned locally.
 * Clones a lightweight/shallow copy from GitHub if missing.
 */
export async function ensureArchipelagoCore(): Promise<void> {
  if (fs.existsSync(path.join(ARCHIPELAGO_PATH, 'worlds', '__init__.py'))) {
    console.log('Archipelago core package detected.');
    patchMultiServerKeepalive();
    patchGenerateDiagnostics();
    await ensureArchipelagoDependencies();
    await ensureServerBaseRom('Zelda no Densetsu - Kamigami no Triforce (Japan).sfc');
    return;
  }

  console.log('Archipelago core package not found. Shallow cloning repository...');
  
  await new Promise<void>((resolve, reject) => {
    const child = spawn('git', ['clone', '--depth', '1', 'https://github.com/ArchipelagoMW/Archipelago.git', ARCHIPELAGO_PATH], {
      stdio: 'inherit'
    });

    child.on('error', (err) => {
      console.error(`Failed to start git clone for Archipelago core: ${err.message}`);
      reject(err);
    });

    child.on('close', (code) => {
      if (code !== 0) {
        return reject(new Error(`git clone for Archipelago core failed with exit code ${code}`));
      }
      console.log('Archipelago core repository cloned successfully.');
      patchMultiServerKeepalive();
      patchGenerateDiagnostics();
      resolve();
    });
  });

  await ensureArchipelagoDependencies();
  await ensureServerBaseRom('Zelda no Densetsu - Kamigami no Triforce (Japan).sfc');
}

/**
 * Automatically ensures that any base ROM required on the backend for multiworld generation exists.
 * If missing, downloads it from backend/data/roms.json and unpacks if compressed.
 */
export async function ensureServerBaseRom(romFileName: string): Promise<boolean> {
  const destPath = path.join(ARCHIPELAGO_PATH, romFileName);
  if (fs.existsSync(destPath)) return true;

  const romsJsonPath = path.join(BACKEND_ROOT, 'data', 'roms.json');
  if (!fs.existsSync(romsJsonPath)) return false;

  try {
    const catalog = JSON.parse(fs.readFileSync(romsJsonPath, 'utf-8'));
    const entry = catalog[romFileName] || catalog[path.basename(romFileName, path.extname(romFileName))];
    const downloadUrl = typeof entry === 'string' ? entry : entry?.url;
    if (!downloadUrl) return false;

    console.log(`[Archipelago Core] Automatically downloading required base ROM "${romFileName}" from ${downloadUrl}...`);
    const resp = await fetch(downloadUrl, {
      headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
    });
    if (!resp.ok) {
      console.warn(`[Archipelago Core] Failed to download base ROM ${romFileName}: HTTP ${resp.status}`);
      return false;
    }

    const arrayBuffer = await resp.arrayBuffer();
    const buffer = Buffer.from(arrayBuffer);

    // If it's a zip archive (PK\x03\x04), extract matching entry
    if (buffer.length > 4 && buffer[0] === 0x50 && buffer[1] === 0x4B && buffer[2] === 0x03 && buffer[3] === 0x04) {
      const zip = new AdmZip(buffer);
      const zipEntries = zip.getEntries();
      const targetEntry = zipEntries.find(e => 
        !e.isDirectory && (e.entryName === romFileName || path.basename(e.entryName) === romFileName)
      ) || zipEntries.find(e => !e.isDirectory && (e.entryName.endsWith('.sfc') || e.entryName.endsWith('.gba') || e.entryName.endsWith('.z64')));

      if (targetEntry) {
        fs.writeFileSync(destPath, targetEntry.getData());
        console.log(`[Archipelago Core] Extracted base ROM "${romFileName}" to ${destPath} (${targetEntry.header.size} bytes).`);
        return true;
      } else {
        console.warn(`[Archipelago Core] Could not find "${romFileName}" inside downloaded zip archive.`);
        return false;
      }
    } else {
      fs.writeFileSync(destPath, buffer);
      console.log(`[Archipelago Core] Saved base ROM "${romFileName}" to ${destPath} (${buffer.length} bytes).`);
      return true;
    }
  } catch (err: any) {
    console.warn(`[Archipelago Core] Error downloading base ROM "${romFileName}":`, err.message);
    return false;
  }
}

/**
 * Resolves the Python executable and any prefix arguments (e.g. ['-3.12'] on Windows).
 */
export function getPythonCommand(): { exe: string; prefixArgs: string[] } {
  if (process.env.PYTHON_BIN) {
    return { exe: process.env.PYTHON_BIN, prefixArgs: [] };
  }
  if (process.platform === 'win32') {
    return { exe: 'py', prefixArgs: ['-3.12'] };
  }
  return { exe: 'python', prefixArgs: [] };
}

/**
 * Known custom world Python package dependencies and their pip package names.
 */
const KNOWN_WORLD_DEPENDENCIES: Record<string, string> = {
  dolphin_memory_engine: 'dolphin-memory-engine',
  websockets: 'websockets',
  pyevermizer: 'pyevermizer',
  zilliandomizer: 'zilliandomizer',
  colorama: 'colorama',
};

/**
 * Installs a Python package using the resolved Python executable and pip.
 */
export function installPythonPackage(packageName: string): Promise<boolean> {
  return new Promise((resolve) => {
    const { exe: pythonExe, prefixArgs } = getPythonCommand();
    console.log(`[Dependencies] Installing Python package "${packageName}" via pip...`);
    const args = [...prefixArgs, '-m', 'pip', 'install', packageName];
    execFile(pythonExe, args, { maxBuffer: 10 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) {
        console.error(`[Dependencies] Failed to install "${packageName}":`, stderr || error.message);
        resolve(false);
      } else {
        console.log(`[Dependencies] Successfully installed "${packageName}".`);
        resolve(true);
      }
    });
  });
}

/**
 * Checks if a Python module is importable in the environment.
 */
export function isPythonModuleAvailable(moduleName: string): Promise<boolean> {
  return new Promise((resolve) => {
    const { exe: pythonExe, prefixArgs } = getPythonCommand();
    const args = [...prefixArgs, '-c', `import ${moduleName}`];
    execFile(pythonExe, args, (error) => {
      resolve(!error);
    });
  });
}

/**
 * Ensures required and common custom world Python dependencies are installed.
 */
export async function ensureArchipelagoDependencies(): Promise<void> {
  for (const [moduleName, pipName] of Object.entries(KNOWN_WORLD_DEPENDENCIES)) {
    try {
      const available = await isPythonModuleAvailable(moduleName);
      if (!available) {
        console.log(`[Dependencies] Module "${moduleName}" is missing. Auto-installing "${pipName}"...`);
        await installPythonPackage(pipName);
      }
    } catch (e: any) {
      console.warn(`[Dependencies] Warning checking module ${moduleName}:`, e.message);
    }
  }
}

/**
 * Query games list or game options schema by invoking parse_options.py.
 */
function runParser(gameName: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const { exe: pythonExe, prefixArgs } = getPythonCommand();
    const args = [
      ...prefixArgs,
      PARSER_SCRIPT_PATH,
      ARCHIPELAGO_PATH,
      gameName,
      CUSTOM_WORLDS_DIR
    ];

    const options = {
      maxBuffer: 10 * 1024 * 1024,
      env: {
        ...process.env,
        SKIP_REQUIREMENTS_UPDATE: '1'
      }
    };

    execFile(pythonExe, args, options, (error, stdout, stderr) => {
      if (error) {
        console.error(`Parser error on game ${gameName}:`, stderr);
        return reject(new Error(stderr || error.message));
      }

      try {
        const result = JSON.parse(stdout);
        if (result.error) {
          return reject(new Error(result.error));
        }
        resolve(result);
      } catch (parseError) {
        console.error('Failed to parse script output as JSON:', stdout);
        reject(parseError);
      }
    });
  });
}

function runGenerateTemplates(outputDir: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const { exe: pythonExe, prefixArgs } = getPythonCommand();
    const args = [
      ...prefixArgs,
      TEMPLATES_SCRIPT_PATH,
      ARCHIPELAGO_PATH,
      outputDir,
      CUSTOM_WORLDS_DIR
    ];

    const options = {
      maxBuffer: 20 * 1024 * 1024,
      env: {
        ...process.env,
        SKIP_REQUIREMENTS_UPDATE: '1'
      }
    };

    execFile(pythonExe, args, options, (error, stdout, stderr) => {
      if (error) {
        console.error('Template generator error:', stderr);
        return reject(new Error(stderr || error.message));
      }
      try {
        const jsonMatch = stdout.trim().match(/\{[\s\S]*\}$/);
        const result = jsonMatch ? JSON.parse(jsonMatch[0]) : { success: true };
        resolve(result);
      } catch (e: any) {
        console.warn('Could not parse template generator JSON output:', stdout);
        resolve({ success: true, raw: stdout });
      }
    });
  });
}

/**
 * Generates all YAML templates (standard worlds in root, custom worlds in custom/)
 * and returns the absolute path to the resulting ZIP archive.
 */
export async function generateYamlTemplatesZip(force: boolean = false): Promise<string> {
  const currentFingerprint = getCustomWorldsFingerprint();
  if (!force && fs.existsSync(TEMPLATES_ZIP_PATH) && templatesZipFingerprint === currentFingerprint) {
    return TEMPLATES_ZIP_PATH;
  }

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wf_templates_'));
  try {
    console.log('[ArchipelagoRunner] Generating YAML templates package...');
    const result = await runGenerateTemplates(tempDir);
    console.log('[ArchipelagoRunner] Template generation result:', result);

    const zip = new AdmZip();
    zip.addLocalFolder(tempDir);

    const dataDir = path.dirname(TEMPLATES_ZIP_PATH);
    if (!fs.existsSync(dataDir)) {
      fs.mkdirSync(dataDir, { recursive: true });
    }

    zip.writeZip(TEMPLATES_ZIP_PATH);
    templatesZipFingerprint = currentFingerprint;
    return TEMPLATES_ZIP_PATH;
  } finally {
    try {
      fs.rmSync(tempDir, { recursive: true, force: true });
    } catch {}
  }
}

import db from './db.js';

const optionsCache = new Map<string, any>();
let gamesCache: string[] | null = null;
const CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

let templatesZipFingerprint: string | null = null;

export function invalidateTemplatesCache(): void {
  templatesZipFingerprint = null;
  if (fs.existsSync(TEMPLATES_ZIP_PATH)) {
    try {
      fs.unlinkSync(TEMPLATES_ZIP_PATH);
      console.log('YAML templates zip cache invalidated and file deleted.');
    } catch (err: any) {
      console.warn('Failed to delete cached YAML templates zip:', err.message);
    }
  }
}

/**
 * Clears the games list and options schemas cache (both in-memory and DB).
 */
export function clearCache(): void {
  gamesCache = null;
  optionsCache.clear();
  invalidateTemplatesCache();
  try {
    db.prepare('DELETE FROM OptionsCache').run();
    console.log('Archipelago runner options and games caches (memory and DB) cleared.');
  } catch (err) {
    console.error('Failed to clear OptionsCache from database:', err);
  }
}

/**
 * Returns a list of all registered Archipelago games (official + custom).
 */

function getCustomWorldsFingerprint(): string {
  try {
    if (!fs.existsSync(CUSTOM_WORLDS_DIR)) return '';
    const entries = fs.readdirSync(CUSTOM_WORLDS_DIR).filter(f => f.endsWith('.apworld'));
    const stats = entries.map(f => {
      const p = path.join(CUSTOM_WORLDS_DIR, f);
      const stat = fs.statSync(p);
      return f + ':' + stat.size + ':' + stat.mtimeMs;
    });
    return stats.sort().join(';');
  } catch {
    return '';
  }
}

let lastCustomWorldsFingerprint: string | null = null;

export async function getAvailableGames(forceRefresh: boolean = false): Promise<string[]> {
  if (!forceRefresh && gamesCache) {
    return gamesCache;
  }

  const cacheKey = 'games_list';

  const currentFingerprint = getCustomWorldsFingerprint();
  if (lastCustomWorldsFingerprint === null) {
    lastCustomWorldsFingerprint = currentFingerprint;
  } else if (lastCustomWorldsFingerprint !== currentFingerprint) {
    console.log('[ArchipelagoRunner] Detected custom_worlds changes on disk; invalidating games_list cache.');
    lastCustomWorldsFingerprint = currentFingerprint;
    forceRefresh = true;
  }

  if (!forceRefresh) {
    try {
      const row = db.prepare('SELECT json_data, updated_at FROM OptionsCache WHERE cache_key = ?').get(cacheKey) as { json_data: string; updated_at: string } | undefined;
      if (row) {
        const updatedAt = new Date(row.updated_at).getTime();
        if (Date.now() - updatedAt < CACHE_TTL_MS) {
          const parsed = JSON.parse(row.json_data);
          gamesCache = parsed.games || [];
          console.log(`Loaded available games list from SQLite persistent cache (${gamesCache?.length} games)`);
          return gamesCache!;
        }
      }
    } catch (e) {
      console.warn('Failed to read games list from OptionsCache:', e);
    }
  }

  try {
    console.log('Fetching games list from Archipelago Python runner...');
    const data = await runParser('__list');
    gamesCache = data.games || [];
    db.prepare(`
      INSERT INTO OptionsCache (cache_key, json_data, updated_at)
      VALUES (?, ?, CURRENT_TIMESTAMP)
      ON CONFLICT(cache_key) DO UPDATE SET
        json_data = excluded.json_data,
        updated_at = CURRENT_TIMESTAMP
    `).run(cacheKey, JSON.stringify(data));
    return gamesCache!;
  } catch (error) {
    console.error('Failed to list available games:', error);
    return gamesCache || [];
  }
}

/**
 * Returns options schema JSON for the specified game.
 */
export async function getGameOptions(gameName: string, forceRefresh: boolean = false): Promise<any> {
  if (!forceRefresh && optionsCache.has(gameName)) {
    return optionsCache.get(gameName);
  }

  const cacheKey = `game:${gameName}`;

  const currentFingerprint = getCustomWorldsFingerprint();
  if (lastCustomWorldsFingerprint === null) {
    lastCustomWorldsFingerprint = currentFingerprint;
  } else if (lastCustomWorldsFingerprint !== currentFingerprint) {
    console.log('[ArchipelagoRunner] Detected custom_worlds changes on disk; invalidating games_list cache.');
    lastCustomWorldsFingerprint = currentFingerprint;
    forceRefresh = true;
  }

  if (!forceRefresh) {
    try {
      const row = db.prepare('SELECT json_data, updated_at FROM OptionsCache WHERE cache_key = ?').get(cacheKey) as { json_data: string; updated_at: string } | undefined;
      if (row) {
        const updatedAt = new Date(row.updated_at).getTime();
        if (Date.now() - updatedAt < CACHE_TTL_MS) {
          const schema = JSON.parse(row.json_data);
          optionsCache.set(gameName, schema);
          console.log(`Loaded options schema for game "${gameName}" from SQLite persistent cache`);
          return schema;
        }
      }
    } catch (e) {
      console.warn(`Failed to read options for ${gameName} from OptionsCache:`, e);
    }
  }

  console.log(`Fetching options schema for game "${gameName}" from Archipelago Python runner...`);
  const result = await runParser(gameName);
  optionsCache.set(gameName, result);
  try {
    db.prepare(`
      INSERT INTO OptionsCache (cache_key, json_data, updated_at)
      VALUES (?, ?, CURRENT_TIMESTAMP)
      ON CONFLICT(cache_key) DO UPDATE SET
        json_data = excluded.json_data,
        updated_at = CURRENT_TIMESTAMP
    `).run(cacheKey, JSON.stringify(result));
  } catch (e) {
    console.warn(`Failed to write options for ${gameName} to OptionsCache:`, e);
  }
  return result;
}

export interface PlayerYaml {
  name: string;
  yaml: string;
}

/**
 * Generates an Archipelago multiworld seed from player YAML configurations.
 */
export function generateSeed(
  roomCode: string, 
  players: PlayerYaml[], 
  onLog: (line: string) => void,
  isRetry: boolean = false
): Promise<{ zipName: string, spoilerName: string }> {
  return new Promise(async (resolve, reject) => {
    // Ensure base ROMs required on the server by Archipelago generator (e.g. ALTTP)
    const alttpNeedsRom = players.some(p => p.yaml && (
      p.yaml.includes('game: A Link to the Past') || 
      p.yaml.includes('game: "A Link to the Past"') || 
      p.yaml.includes('game: alttp') || 
      p.yaml.includes('game: ALTTP')
    ));
    if (alttpNeedsRom) {
      await ensureServerBaseRom('Zelda no Densetsu - Kamigami no Triforce (Japan).sfc');
    }

    const tempSeedsDir = path.join(BACKEND_ROOT, 'temp_seeds', roomCode);
    const inputsDir = path.join(tempSeedsDir, 'inputs');
    const outputsDir = path.join(tempSeedsDir, 'outputs');

    try {
      // Recreate clean input/output directories
      if (fs.existsSync(tempSeedsDir)) {
        fs.rmSync(tempSeedsDir, { recursive: true, force: true });
      }
      fs.mkdirSync(inputsDir, { recursive: true });
      fs.mkdirSync(outputsDir, { recursive: true });

      // Write player YAML files
      console.log(`[Generation] Writing player configuration files for ${players.length} players...`);
      for (const player of players) {
        if (!player.yaml) continue;
        const safeName = player.name.replace(/[^a-zA-Z0-9_-]/g, '_');
        console.log(`[Generation] Wrote configuration for "${safeName}" (${player.yaml.length} bytes)`);
        // If YAML contains multiple documents (---), split them into separate files so Archipelago Generate.py processes each slot cleanly
        const rawDocs = player.yaml.split(/^---[ \t]*$/m).map(d => d.trim()).filter(Boolean);
        if (rawDocs.length > 1) {
          rawDocs.forEach((doc, idx) => {
            fs.writeFileSync(path.join(inputsDir, `${safeName}_slot${idx + 1}.yaml`), doc, 'utf8');
          });
        } else {
          fs.writeFileSync(path.join(inputsDir, `${safeName}.yaml`), player.yaml, 'utf8');
        }
      }
    } catch (fsErr) {
      return reject(fsErr);
    }

    const { exe: pythonExe, prefixArgs } = getPythonCommand();
    const generateScript = path.join(ARCHIPELAGO_PATH, 'Generate.py');

    const args = [
      ...prefixArgs,
      generateScript,
      '--player_files_path',
      inputsDir,
      '--outputpath',
      outputsDir
    ];

    const options = {
      cwd: ARCHIPELAGO_PATH,
      env: {
        ...process.env,
        SKIP_REQUIREMENTS_UPDATE: '1'
      }
    };

    patchGenerateDiagnostics();
    console.log(`Running seed generation for room ${roomCode}...`);
    const child = spawn(pythonExe, args, options);
    child.stdin.end(); // Close stdin immediately so atexit input() prompts fail fast with EOFError

    const logFilePath = path.join(outputsDir, 'generation.log');
    const logStream = fs.createWriteStream(logFilePath, { flags: 'a' });

    let stdoutBuffer = '';
    let stderrBuffer = '';
    let stdoutLineRemainder = '';
    let stderrLineRemainder = '';

    child.stdout.on('data', (data) => {
      const text = data.toString();
      logStream.write(text);
      stdoutBuffer += text;

      stdoutLineRemainder += text;
      const lines = stdoutLineRemainder.split('\n');
      stdoutLineRemainder = lines.pop() || '';
      for (const rawLine of lines) {
        const line = rawLine.trim();
        if (line) onLog(line);
      }
    });

    child.stderr.on('data', (data) => {
      const text = data.toString();
      logStream.write(text);
      stderrBuffer += text;

      stderrLineRemainder += text;
      const lines = stderrLineRemainder.split('\n');
      stderrLineRemainder = lines.pop() || '';
      for (const rawLine of lines) {
        const line = rawLine.trim();
        if (line) onLog(line);
      }
    });

    child.on('close', async (code) => {
      if (stdoutLineRemainder.trim()) {
        onLog(stdoutLineRemainder.trim());
      }
      if (stderrLineRemainder.trim()) {
        onLog(stderrLineRemainder.trim());
      }
      logStream.end();
      if (code !== 0) {
        console.error(`Archipelago generation exited with code ${code} for room ${roomCode}`);
        if (stderrBuffer.trim()) console.error('[Archipelago stderr]:\n', stderrBuffer.trim());
        if (stdoutBuffer.trim()) console.error('[Archipelago stdout]:\n', stdoutBuffer.trim());
        
        const combined = (stderrBuffer + '\n' + stdoutBuffer);

        // Check if generation failed due to a missing Python module that we can auto-install and retry
        const moduleMatch = combined.match(/ModuleNotFoundError:\s+No module named\s+['"]([a-zA-Z0-9_]+)['"]/i);
        if (moduleMatch && !isRetry) {
          const missingModule = moduleMatch[1];
          const pipPackage = KNOWN_WORLD_DEPENDENCIES[missingModule] || missingModule.replace(/_/g, '-');
          onLog(`[Dependencies] Missing Python module detected: "${missingModule}". Attempting auto-installation of "${pipPackage}"...`);
          console.log(`[Generation] Auto-installing missing dependency "${pipPackage}" for room ${roomCode}...`);
          const installed = await installPythonPackage(pipPackage);
          if (installed) {
            onLog(`[Dependencies] Successfully installed "${pipPackage}". Automatically re-running seed generation...`);
            try {
              const retryResult = await generateSeed(roomCode, players, onLog, true);
              return resolve(retryResult);
            } catch (retryErr) {
              return reject(retryErr);
            }
          } else {
            onLog(`[Dependencies] Failed to auto-install "${pipPackage}". Please check server environment.`);
          }
        }

        // Find clean error message from logs
        let cleanError = '';
        const lines = combined.split('\n');
        for (let i = lines.length - 1; i >= 0; i--) {
          const line = lines[i].trim();
          if (line.includes('Exception:') || line.includes('ValueError:') || line.includes('Error:')) {
            // Include subsequent lines if they provide detail
            cleanError = lines.slice(i, i + 10).map(l => l.trim()).filter(Boolean).join(' ');
            break;
          }
        }
        if (!cleanError) {
          for (let i = lines.length - 1; i >= 0; i--) {
            const line = lines[i].trim();
            if (line && !line.includes('Press enter to close')) {
              cleanError = line;
              break;
            }
          }
        }
        if (cleanError) {
          cleanError = cleanError.replace(/Press enter to close\.?/gi, '').trim();
        }
        return reject(new Error(cleanError || `Generation exited with code ${code}`));
      }

      console.log(`Generation finished for room ${roomCode}. Scanning output files...`);

      try {
        const files = fs.readdirSync(outputsDir);
        let zipName = '';
        let spoilerName = '';

        for (const file of files) {
          if (file.endsWith('.zip')) {
            zipName = file;
          } else if (file.endsWith('_Spoiler.txt') || (file.includes('Spoiler') && file.endsWith('.txt'))) {
            spoilerName = file;
          }
        }

        if (!zipName) {
          return reject(new Error('Generation completed but no output seed .zip file was found.'));
        }

        console.log(`Room ${roomCode} generation complete. Zip: ${zipName}, Spoiler: ${spoilerName}`);
        resolve({ zipName, spoilerName });
      } catch (dirError) {
        reject(dirError);
      }
    });
  });
}

