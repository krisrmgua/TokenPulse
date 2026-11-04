import fs from "node:fs";
import path from "node:path";
import { app, nativeImage } from "electron";
import type { SourceId } from "./types";

const CACHE = new Map<string, string>();

function providersDir(): string {
  if (app.isPackaged) return path.join(process.resourcesPath, "Artwork", "providers");
  return path.join(app.getAppPath(), "menubar", "Artwork", "providers");
}

function providerFile(id: SourceId, themed: boolean): string {
  const name = themed ? `${id}-themed.png` : `${id}.png`;
  return path.join(providersDir(), name);
}

/** data: URL of the Swift-exported ProviderArtwork PNG (64×64). */
export function providerIconDataUrl(id: SourceId, _size: number, themed: boolean): string {
  const key = `${id}:${themed ? "t" : "p"}`;
  const hit = CACHE.get(key);
  if (hit) return hit;
  const file = providerFile(id, themed);
  if (!fs.existsSync(file)) {
    // Fall back to themed/plain sibling if one set is missing.
    const alt = providerFile(id, !themed);
    if (!fs.existsSync(alt)) return "";
    const b64 = fs.readFileSync(alt).toString("base64");
    const url = `data:image/png;base64,${b64}`;
    CACHE.set(key, url);
    return url;
  }
  const url = `data:image/png;base64,${fs.readFileSync(file).toString("base64")}`;
  CACHE.set(key, url);
  return url;
}

export function providerIconMap(
  size: number,
  themed: boolean,
): Record<SourceId, string> {
  return {
    chatgpt: providerIconDataUrl("chatgpt", size, themed),
    cursor: providerIconDataUrl("cursor", size, themed),
    grokbot: providerIconDataUrl("grokbot", size, themed),
    openai: providerIconDataUrl("openai", size, themed),
    claude: providerIconDataUrl("claude", size, themed),
  };
}

/**
 * RGBA buffer for tray compositing — Swift PNGs resized to `size`.
 */
export function providerIconRgba(
  id: SourceId,
  size: number,
  themed: boolean,
): Buffer {
  const file = providerFile(id, themed);
  const pathToUse = fs.existsSync(file) ? file : providerFile(id, !themed);
  const rgba = Buffer.alloc(size * size * 4);
  if (!fs.existsSync(pathToUse)) return rgba;
  const img = nativeImage.createFromPath(pathToUse);
  if (img.isEmpty()) return rgba;
  const resized = img.resize({ width: size, height: size, quality: "best" });
  const { width, height } = resized.getSize();
  const bgra = resized.toBitmap();
  for (let y = 0; y < Math.min(height, size); y++) {
    for (let x = 0; x < Math.min(width, size); x++) {
      const si = (y * width + x) * 4;
      const di = (y * size + x) * 4;
      // Electron toBitmap is BGRA
      rgba[di] = bgra[si + 2];
      rgba[di + 1] = bgra[si + 1];
      rgba[di + 2] = bgra[si];
      rgba[di + 3] = bgra[si + 3];
    }
  }
  return rgba;
}
