import fs from "node:fs";
import path from "node:path";
import { app, nativeImage } from "electron";
import type { SourceId } from "./types";

const CACHE = new Map<string, string>();

function providersDir(): string {
  if (app.isPackaged) return path.join(process.resourcesPath, "Artwork", "providers");
  return path.join(app.getAppPath(), "menubar", "Artwork", "providers");
}

function providerFile(id: SourceId): string {
  return path.join(providersDir(), `${id}.png`);
}

/** data: URL of the plain provider mark (64×64). */
export function providerIconDataUrl(id: SourceId, _size: number): string {
  const hit = CACHE.get(id);
  if (hit) return hit;
  const file = providerFile(id);
  if (!fs.existsSync(file)) return "";
  const url = `data:image/png;base64,${fs.readFileSync(file).toString("base64")}`;
  CACHE.set(id, url);
  return url;
}

export function providerIconMap(size: number): Record<SourceId, string> {
  return {
    chatgpt: providerIconDataUrl("chatgpt", size),
    cursor: providerIconDataUrl("cursor", size),
    grokbot: providerIconDataUrl("grokbot", size),
    openai: providerIconDataUrl("openai", size),
    claude: providerIconDataUrl("claude", size),
  };
}

/**
 * RGBA buffer for tray compositing — Swift PNGs resized to `size`.
 */
export function providerIconRgba(id: SourceId, size: number): Buffer {
  const file = providerFile(id);
  const rgba = Buffer.alloc(size * size * 4);
  if (!fs.existsSync(file)) return rgba;
  const img = nativeImage.createFromPath(file);
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
