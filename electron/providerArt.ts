import fs from "node:fs";
import path from "node:path";
import { app, nativeImage } from "electron";
import { encodePng } from "./iconRaster";
import type { SourceId } from "./types";

export const ART_CYAN: [number, number, number] = [88, 210, 236];
export const ART_NAVY: [number, number, number] = [14, 25, 41];
export const ART_INK: [number, number, number] = [237, 245, 255];

function artworkDir(): string {
  if (app.isPackaged) return path.join(process.resourcesPath, "Artwork");
  return path.join(app.getAppPath(), "menubar", "Artwork");
}

/** Load ChatGPT / Grok PNG cutouts from menubar/Artwork. */
function loadPng(name: "chatgpt" | "grokbot"): Electron.NativeImage | null {
  const file = path.join(artworkDir(), `icon-${name}.png`);
  if (!fs.existsSync(file)) return null;
  const img = nativeImage.createFromPath(file);
  return img.isEmpty() ? null : img;
}

/**
 * Provider mark as RGBA pixels (size×size), themed cyan-on-navy or plain ink.
 * Uses Artwork PNGs for ChatGPT/Grok; draws SF-style glyphs for the rest.
 */
export function providerIconRgba(
  id: SourceId,
  size: number,
  themed: boolean,
): Buffer {
  const rgba = Buffer.alloc(size * size * 4);
  const ink = themed ? ART_CYAN : ART_INK;
  if (themed) fillRoundedRect(rgba, size, 0, 0, size, size, size * 0.22, ART_NAVY, 255);

  if (id === "chatgpt" || id === "grokbot") {
    const src = loadPng(id);
    if (src) {
      const inset = themed ? Math.round(size * 0.18) : Math.round(size * 0.06);
      const inner = Math.max(8, size - inset * 2);
      // Crop Grok's packaged tile a bit before resize.
      let cut = src;
      if (id === "grokbot") {
        const { width, height } = src.getSize();
        const crop = Math.round(Math.min(width, height) * 0.12);
        cut = src.crop({
          x: crop,
          y: crop,
          width: width - crop * 2,
          height: height - crop * 2,
        });
      }
      const resized = cut.resize({ width: inner, height: inner, quality: "best" });
      blitTinted(rgba, size, resized, inset, inset, ink);
      return rgba;
    }
  }

  drawGlyph(rgba, size, id, ink);
  return rgba;
}

export function providerIconDataUrl(id: SourceId, size: number, themed: boolean): string {
  const png = encodePng(size, size, providerIconRgba(id, size, themed));
  return `data:image/png;base64,${png.toString("base64")}`;
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

function fillRoundedRect(
  rgba: Buffer,
  dim: number,
  x0: number,
  y0: number,
  w: number,
  h: number,
  r: number,
  rgb: [number, number, number],
  a: number,
): void {
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const px = x0 + x;
      const py = y0 + y;
      if (px < 0 || py < 0 || px >= dim || py >= dim) continue;
      const cover = roundCover(x + 0.5, y + 0.5, w, h, r);
      if (cover <= 0) continue;
      put(rgba, dim, px, py, rgb[0], rgb[1], rgb[2], Math.round(a * cover));
    }
  }
}

function roundCover(x: number, y: number, w: number, h: number, r: number): number {
  const cx = Math.min(Math.max(x, r), w - r);
  const cy = Math.min(Math.max(y, r), h - r);
  const dx = x - cx;
  const dy = y - cy;
  if (dx * dx + dy * dy <= (r - 0.5) * (r - 0.5)) return 1;
  const d = Math.hypot(dx, dy);
  if (d >= r + 0.5) return 0;
  return r + 0.5 - d;
}

function put(
  rgba: Buffer,
  dim: number,
  x: number,
  y: number,
  r: number,
  g: number,
  b: number,
  a: number,
): void {
  if (a <= 0 || x < 0 || y < 0 || x >= dim || y >= dim) return;
  const i = (y * dim + x) * 4;
  const srcA = a / 255;
  const dstA = rgba[i + 3] / 255;
  const outA = srcA + dstA * (1 - srcA);
  if (outA <= 0) return;
  rgba[i] = Math.round((r * srcA + rgba[i] * dstA * (1 - srcA)) / outA);
  rgba[i + 1] = Math.round((g * srcA + rgba[i + 1] * dstA * (1 - srcA)) / outA);
  rgba[i + 2] = Math.round((b * srcA + rgba[i + 2] * dstA * (1 - srcA)) / outA);
  rgba[i + 3] = Math.round(outA * 255);
}

/** Tint dark ink from a source PNG onto the destination. */
function blitTinted(
  dest: Buffer,
  dim: number,
  src: Electron.NativeImage,
  ox: number,
  oy: number,
  ink: [number, number, number],
): void {
  const { width, height } = src.getSize();
  const bgra = src.toBitmap();
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const si = (y * width + x) * 4;
      const a = bgra[si + 3];
      if (a < 12) continue;
      // Prefer dark foreground (logo ink); skip light packaging tiles.
      const luma = (bgra[si + 2] * 0.2126 + bgra[si + 1] * 0.7152 + bgra[si] * 0.0722) / 255;
      const strength = Math.max(0, Math.min(1, (0.72 - luma) / 0.45)) * (a / 255);
      if (strength < 0.08) continue;
      put(dest, dim, ox + x, oy + y, ink[0], ink[1], ink[2], Math.round(strength * 255));
    }
  }
}

function drawGlyph(
  rgba: Buffer,
  dim: number,
  id: SourceId,
  ink: [number, number, number],
): void {
  const cx = (dim - 1) / 2;
  const cy = (dim - 1) / 2;
  const stroke = Math.max(1.2, dim * 0.1);
  if (id === "cursor") {
    // Isometric cube
    const u = dim * 0.22;
    line(rgba, dim, cx, cy - u * 1.15, cx + u, cy - u * 0.45, ink, stroke);
    line(rgba, dim, cx + u, cy - u * 0.45, cx + u, cy + u * 0.45, ink, stroke);
    line(rgba, dim, cx + u, cy + u * 0.45, cx, cy + u * 1.15, ink, stroke);
    line(rgba, dim, cx, cy + u * 1.15, cx - u, cy + u * 0.45, ink, stroke);
    line(rgba, dim, cx - u, cy + u * 0.45, cx - u, cy - u * 0.45, ink, stroke);
    line(rgba, dim, cx - u, cy - u * 0.45, cx, cy - u * 1.15, ink, stroke);
    line(rgba, dim, cx - u, cy - u * 0.45, cx, cy, ink, stroke * 0.85);
    line(rgba, dim, cx + u, cy - u * 0.45, cx, cy, ink, stroke * 0.85);
    line(rgba, dim, cx, cy, cx, cy + u * 1.15, ink, stroke * 0.85);
  } else if (id === "claude") {
    const r = dim * 0.32;
    for (const deg of [0, 60, 120]) {
      const a = (deg * Math.PI) / 180;
      line(
        rgba,
        dim,
        cx - r * Math.cos(a),
        cy - r * Math.sin(a),
        cx + r * Math.cos(a),
        cy + r * Math.sin(a),
        ink,
        stroke,
      );
    }
  } else if (id === "openai") {
    ring(rgba, dim, cx, cy, dim * 0.3, stroke, ink);
    // inner loop
    for (let t = 0; t < 1; t += 0.02) {
      const a = t * Math.PI * 2;
      const x = cx + dim * 0.16 * Math.cos(a);
      const y = cy + dim * 0.1 * Math.sin(a * 2);
      stamp(rgba, dim, x, y, ink, stroke * 0.45);
    }
  } else {
    // fallback bloom
    ring(rgba, dim, cx, cy, dim * 0.28, stroke, ink);
  }
}

function line(
  rgba: Buffer,
  dim: number,
  x0: number,
  y0: number,
  x1: number,
  y1: number,
  ink: [number, number, number],
  width: number,
): void {
  const steps = Math.max(8, Math.ceil(Math.hypot(x1 - x0, y1 - y0) * 2));
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    stamp(rgba, dim, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, ink, width / 2);
  }
}

function ring(
  rgba: Buffer,
  dim: number,
  cx: number,
  cy: number,
  r: number,
  width: number,
  ink: [number, number, number],
): void {
  const steps = Math.max(32, Math.ceil(2 * Math.PI * r * 2));
  for (let i = 0; i < steps; i++) {
    const a = (i / steps) * Math.PI * 2;
    stamp(rgba, dim, cx + r * Math.cos(a), cy + r * Math.sin(a), ink, width / 2);
  }
}

function stamp(
  rgba: Buffer,
  dim: number,
  fx: number,
  fy: number,
  ink: [number, number, number],
  radius: number,
): void {
  const x0 = Math.floor(fx - radius - 1);
  const x1 = Math.ceil(fx + radius + 1);
  const y0 = Math.floor(fy - radius - 1);
  const y1 = Math.ceil(fy + radius + 1);
  for (let y = y0; y <= y1; y++) {
    for (let x = x0; x <= x1; x++) {
      const d = Math.hypot(x + 0.5 - fx, y + 0.5 - fy);
      const cover =
        d <= radius - 0.5 ? 1 : d >= radius + 0.5 ? 0 : radius + 0.5 - d;
      if (cover > 0) put(rgba, dim, x, y, ink[0], ink[1], ink[2], Math.round(255 * cover));
    }
  }
}
