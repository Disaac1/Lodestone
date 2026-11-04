import { Router, Request, Response } from 'express';
import path from 'path';
import fs from 'fs';
import AdmZip from 'adm-zip';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const BACKEND_ROOT = path.join(__dirname, '..');
const CUSTOM_WORLDS_DIR = path.join(BACKEND_ROOT, 'archipelago_core', 'custom_worlds');
const REGISTRY_PATH = path.join(BACKEND_ROOT, 'data', 'custom_worlds_registry.json');

export interface CustomWorldRegistryItem {
  game: string;
  filename: string;
  repo: string;
  release_tag: string;
  download_url: string;
  description?: string;
}

export function loadRegistry(): Record<string, CustomWorldRegistryItem> {
  try {
    if (fs.existsSync(REGISTRY_PATH)) {
      return JSON.parse(fs.readFileSync(REGISTRY_PATH, 'utf-8'));
    }
  } catch (err: any) {
    console.warn('[CustomWorlds] Failed to read custom_worlds_registry.json:', err.message);
  }
  return {};
}

export async function downloadFromUpstream(url: string, destPath: string): Promise<boolean> {
  try {
    console.log(`[CustomWorlds] Auto-downloading upstream package from: ${url}`);
    const res = await fetch(url, {
      headers: { 'User-Agent': 'Wayfinder-Server' },
      redirect: 'follow',
    });
    if (!res.ok) {
      console.error(`[CustomWorlds] Failed to download package. HTTP status: ${res.status}`);
      return false;
    }
    const arrayBuffer = await res.arrayBuffer();
    const buf = Buffer.from(arrayBuffer);
    if (destPath.endsWith('.apworld')) {
      try {
        const zip = new AdmZip(buf);
        if (zip.getEntries().length === 0) throw new Error('Archive contains no files');
      } catch (zipErr: any) {
        console.error(`[CustomWorlds] Downloaded file from ${url} is not a valid zip archive:`, zipErr.message);
        return false;
      }
    }
    if (!fs.existsSync(path.dirname(destPath))) {
      fs.mkdirSync(path.dirname(destPath), { recursive: true });
    }
    fs.writeFileSync(destPath, buf);
    console.log(`[CustomWorlds] Successfully cached package to: ${destPath}`);
    return true;
  } catch (err: any) {
    console.error(`[CustomWorlds] Error downloading from ${url}:`, err.message);
    return false;
  }
}

const router = Router();

// 1. List custom worlds (both locally cached and upstream registered)
router.get('/', (req: Request, res: Response) => {
  try {
    const registry = loadRegistry();
    const seen = new Set<string>();
    const worlds: Array<{
      game: string;
      filename: string;
      size: number;
      modified?: string;
      upstream?: boolean;
      repo?: string;
      download_url?: string;
    }> = [];

    // Local files in custom_worlds directory
    if (fs.existsSync(CUSTOM_WORLDS_DIR)) {
      const files = fs.readdirSync(CUSTOM_WORLDS_DIR).filter(f => f.endsWith('.apworld'));
      for (const filename of files) {
        seen.add(filename);
        const filePath = path.join(CUSTOM_WORLDS_DIR, filename);
        let stat: fs.Stats | null = null;
        try { stat = fs.statSync(filePath); } catch {}

        let game = '';
        try {
          const zip = new AdmZip(filePath);
          const entry = zip.getEntries().find(e => e.entryName.endsWith('archipelago.json') || e.entryName.endsWith('manifest.json'));
          if (entry) {
            const parsed = JSON.parse(entry.getData().toString('utf8'));
            game = parsed.game || parsed.world || parsed.name || '';
          }
        } catch {}

        if (!game && registry[filename]) {
          game = registry[filename].game;
        }

        worlds.push({
          game,
          filename,
          size: stat ? stat.size : 0,
          modified: stat ? stat.mtime.toISOString() : undefined,
          upstream: false,
          repo: registry[filename]?.repo,
          download_url: registry[filename]?.download_url,
        });
      }
    }

    // Add registered worlds not yet downloaded
    for (const [filename, item] of Object.entries(registry)) {
      if (!seen.has(filename)) {
        worlds.push({
          game: item.game,
          filename: item.filename,
          size: 0,
          upstream: true,
          repo: item.repo,
          download_url: item.download_url,
        });
      }
    }

    res.json({ worlds });
  } catch (err: any) {
    res.status(500).json({ error: 'Failed to list custom worlds: ' + err.message });
  }
});

// 2. Download or auto-fetch custom world .apworld
router.get('/:worldName', async (req: Request, res: Response) => {
  try {
    const safeFilename = path.basename(req.params.worldName as string);
    if (!safeFilename.endsWith('.apworld')) {
      return res.status(400).json({ error: 'Filename must end with .apworld' });
    }

    if (!fs.existsSync(CUSTOM_WORLDS_DIR)) {
      fs.mkdirSync(CUSTOM_WORLDS_DIR, { recursive: true });
    }

    const filePath = path.join(CUSTOM_WORLDS_DIR, safeFilename);

    // If missing, check if it's in the upstream registry and download automatically
    if (!fs.existsSync(filePath)) {
      const registry = loadRegistry();
      const item = registry[safeFilename];
      if (item && item.download_url) {
        console.log(`[CustomWorlds] Requested ${safeFilename} is missing locally; fetching from upstream: ${item.download_url}`);
        const success = await downloadFromUpstream(item.download_url, filePath);
        if (!success) {
          return res.status(502).json({ error: `Failed to fetch ${safeFilename} from upstream repository (${item.repo})` });
        }
      } else {
        return res.status(404).json({ error: `Custom world ${safeFilename} not found locally or in upstream registry` });
      }
    }

    res.setHeader('Content-Type', 'application/octet-stream');
    res.setHeader('Content-Disposition', `attachment; filename="${safeFilename}"`);
    res.sendFile(filePath);
  } catch (err: any) {
    res.status(500).json({ error: 'Failed to deliver custom world: ' + err.message });
  }
});

// 3. Sync all registered custom worlds from upstream repositories
router.post('/sync-upstream', async (req: Request, res: Response) => {
  try {
    const registry = loadRegistry();
    const results: Array<{ filename: string; success: boolean; error?: string }> = [];

    if (!fs.existsSync(CUSTOM_WORLDS_DIR)) {
      fs.mkdirSync(CUSTOM_WORLDS_DIR, { recursive: true });
    }

    for (const [filename, item] of Object.entries(registry)) {
      const dest = path.join(CUSTOM_WORLDS_DIR, filename);
      const success = await downloadFromUpstream(item.download_url, dest);
      results.push({ filename, success });
    }

    res.json({ success: true, results });
  } catch (err: any) {
    res.status(500).json({ error: 'Failed to sync upstream packages: ' + err.message });
  }
});

export default router;
