import fs from "node:fs";
import path from "node:path";
import { app, nativeImage } from "electron";
import { encodePng } from "./iconRaster";
import type { SourceId } from "./types";

export const ART_CYAN: [number, number, number] = [88, 210, 236];
export const ART_NAVY: [number, number, number] = [14, 25, 41];
export const ART_INK: [number, number, number] = [210, 220, 235];

function artworkDir(): string {
  if (app.isPackaged) return path.join(process.resourcesPath, "Artwork");
  return path.join(app.getAppPath(), "menubar", "Artwork");
}

function loadPng(name: "chatgpt" | "grokbot"): Electron.NativeImage | null {
  const file = path.join(artworkDir(), `icon-${name}.png`);
  if (!fs.existsSync(file)) return null;
  const img = nativeImage.createFromPath(file);
  return img.isEmpty() ? null : img;
}

/**
 * Provider mark as RGBA. Matches Swift ProviderArtwork:
 * ChatGPT = Artwork swirl cutout, Grok = two slanted eye dashes,
 * Cursor = cube, Claude = asterisk, OpenAI = brain.head.profile.
 */
export function providerIconRgba(
  id: SourceId,
  size: number,
  themed: boolean,
): Buffer {
  const rgba = Buffer.alloc(size * size * 4);
  const ink = themed ? ART_CYAN : ART_INK;
  if (themed) fillRoundedRect(rgba, size, 0, 0, size, size, size * 0.22, ART_NAVY, 255);

  if (id === "chatgpt") {
    const src = loadPng("chatgpt");
    if (src && blitChatGptCutout(rgba, size, src, ink, themed)) return rgba;
  }

  drawGlyph(rgba, size, id, ink, themed);
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

/**
 * Extract the dark ChatGPT swirl from the white app-icon tile (Swift foregroundMark).
 * Drops the rounded packaging border by ignoring edge-touching components.
 */
function blitChatGptCutout(
  dest: Buffer,
  dim: number,
  src: Electron.NativeImage,
  ink: [number, number, number],
  themed: boolean,
): boolean {
  const n = 256;
  const resized = src.resize({ width: n, height: n, quality: "best" });
  const bgra = resized.toBitmap();
  const alpha = new Float32Array(n * n);
  const x0 = 10;
  const x1 = 246;
  const y0 = 10;
  const y1 = 246;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const o = (y * n + x) * 4;
      const a = bgra[o + 3] / 255;
      if (a < 0.05) continue;
      const luma =
        (bgra[o + 2] * 0.2126 + bgra[o + 1] * 0.7152 + bgra[o] * 0.0722) / (255 * a);
      alpha[y * n + x] = Math.max(0, Math.min(1, (0.63 - luma) / 0.25)) * a;
    }
  }

  const seen = new Uint8Array(n * n);
  const kept: number[] = [];
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const start = y * n + x;
      if (seen[start] || alpha[start] < 0.03) continue;
      const queue = [start];
      let head = 0;
      let edge = false;
      let minX = x;
      let maxX = x;
      let minY = y;
      let maxY = y;
      seen[start] = 1;
      while (head < queue.length) {
        const p = queue[head++];
        const px = p % n;
        const py = (p / n) | 0;
        if (px === x0 || px === x1 - 1 || py === y0 || py === y1 - 1) edge = true;
        minX = Math.min(minX, px);
        maxX = Math.max(maxX, px);
        minY = Math.min(minY, py);
        maxY = Math.max(maxY, py);
        for (const [dx, dy] of [
          [-1, 0],
          [1, 0],
          [0, -1],
          [0, 1],
        ] as const) {
          const nx = px + dx;
          const ny = py + dy;
          if (nx < x0 || nx >= x1 || ny < y0 || ny >= y1) continue;
          const q = ny * n + nx;
          if (!seen[q] && alpha[q] >= 0.03) {
            seen[q] = 1;
            queue.push(q);
          }
        }
      }
      const packaging =
        maxX - minX > n * 0.78 || maxY - minY > n * 0.78;
      if (!edge && !packaging && queue.length > 20) kept.push(...queue);
    }
  }
  if (kept.length === 0) return false;

  let minX = n;
  let maxX = 0;
  let minY = n;
  let maxY = 0;
  for (const p of kept) {
    const px = p % n;
    const py = (p / n) | 0;
    minX = Math.min(minX, px);
    maxX = Math.max(maxX, px);
    minY = Math.min(minY, py);
    maxY = Math.max(maxY, py);
  }
  const span = Math.max(maxX - minX, maxY - minY) + 4;
  const inset = themed ? Math.max(2, Math.round(dim * 0.08)) : Math.max(1, Math.round(dim * 0.04));
  const inner = dim - inset * 2;
  for (const p of kept) {
    const px = p % n;
    const py = (p / n) | 0;
    const sx = (px - minX + (span - (maxX - minX + 1)) / 2) / span;
    const sy = (py - minY + (span - (maxY - minY + 1)) / 2) / span;
    const dx = inset + Math.round(sx * (inner - 1));
    const dy = inset + Math.round(sy * (inner - 1));
    put(dest, dim, dx, dy, ink[0], ink[1], ink[2], Math.round(alpha[p] * 255));
  }
  return true;
}

function drawGlyph(
  rgba: Buffer,
  dim: number,
  id: SourceId,
  ink: [number, number, number],
  themed: boolean,
): void {
  const cx = (dim - 1) / 2;
  const cy = (dim - 1) / 2;
  const stroke = Math.max(1.8, dim * 0.11);
  const margin = themed ? dim * 0.14 : dim * 0.08;

  if (id === "grokbot") {
    // Swift cutout of Grok Artwork → two parallel slanted eye dashes.
    const len = dim * 0.42;
    const gap = dim * 0.16;
    const thick = Math.max(2.2, dim * 0.14);
    const angle = -0.55;
    const dx = Math.cos(angle) * len;
    const dy = Math.sin(angle) * len;
    const nx = -Math.sin(angle) * gap;
    const ny = Math.cos(angle) * gap;
    line(rgba, dim, cx - dx / 2 + nx, cy - dy / 2 + ny, cx + dx / 2 + nx, cy + dy / 2 + ny, ink, thick);
    line(rgba, dim, cx - dx / 2 - nx, cy - dy / 2 - ny, cx + dx / 2 - nx, cy + dy / 2 - ny, ink, thick);
    return;
  }

  if (id === "cursor") {
    const u = (dim / 2 - margin) * 0.72;
    line(rgba, dim, cx, cy - u * 1.15, cx + u, cy - u * 0.45, ink, stroke);
    line(rgba, dim, cx + u, cy - u * 0.45, cx + u, cy + u * 0.45, ink, stroke);
    line(rgba, dim, cx + u, cy + u * 0.45, cx, cy + u * 1.15, ink, stroke);
    line(rgba, dim, cx, cy + u * 1.15, cx - u, cy + u * 0.45, ink, stroke);
    line(rgba, dim, cx - u, cy + u * 0.45, cx - u, cy - u * 0.45, ink, stroke);
    line(rgba, dim, cx - u, cy - u * 0.45, cx, cy - u * 1.15, ink, stroke);
    line(rgba, dim, cx - u, cy - u * 0.45, cx, cy, ink, stroke * 0.9);
    line(rgba, dim, cx + u, cy - u * 0.45, cx, cy, ink, stroke * 0.9);
    line(rgba, dim, cx, cy, cx, cy + u * 1.15, ink, stroke * 0.9);
    return;
  }

  if (id === "claude") {
    const r = dim / 2 - margin;
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
        stroke * 1.05,
      );
    }
    return;
  }

  if (id === "openai") {
    // SF Symbol brain.head.profile — head silhouette + inner brain folds.
    drawOpenAIBrain(rgba, dim, ink, margin);
    return;
  }

  // Fallback ChatGPT-ish bloom if PNG missing.
  const r = dim / 2 - margin;
  ring(rgba, dim, cx, cy, r * 0.85, stroke, ink);
}

function drawOpenAIBrain(
  rgba: Buffer,
  dim: number,
  ink: [number, number, number],
  margin: number,
): void {
  const cx = dim * 0.48;
  const cy = dim * 0.5;
  const s = dim - margin * 2;
  const stroke = Math.max(1.6, dim * 0.09);

  // Head profile outline (facing right).
  const head: [number, number][] = [];
  for (let t = 0; t <= 1; t += 0.02) {
    const a = -Math.PI * 0.55 + t * Math.PI * 1.35;
    head.push([cx + Math.cos(a) * s * 0.38, cy + Math.sin(a) * s * 0.42]);
  }
  // chin / neck
  head.push([cx + s * 0.08, cy + s * 0.42]);
  head.push([cx - s * 0.05, cy + s * 0.42]);
  head.push([cx - s * 0.18, cy + s * 0.28]);
  for (let i = 0; i < head.length - 1; i++) {
    line(rgba, dim, head[i][0], head[i][1], head[i + 1][0], head[i + 1][1], ink, stroke);
  }
  line(rgba, dim, head[head.length - 1][0], head[head.length - 1][1], head[0][0], head[0][1], ink, stroke);

  // Brain folds inside the cranium.
  const folds: [number, number, number, number][] = [
    [-0.12, -0.18, 0.12, -0.22],
    [-0.18, -0.05, 0.1, -0.08],
    [-0.16, 0.08, 0.06, 0.04],
    [-0.08, -0.12, 0.02, 0.02],
  ];
  for (const [x0, y0, x1, y1] of folds) {
    line(
      rgba,
      dim,
      cx + x0 * s,
      cy + y0 * s,
      cx + x1 * s,
      cy + y1 * s,
      ink,
      stroke * 0.75,
    );
  }
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
  const steps = Math.max(8, Math.ceil(Math.hypot(x1 - x0, y1 - y0) * 3));
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
  const steps = Math.max(32, Math.ceil(2 * Math.PI * r * 3));
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
      const cover = d <= radius - 0.5 ? 1 : d >= radius + 0.5 ? 0 : radius + 0.5 - d;
      if (cover > 0) put(rgba, dim, x, y, ink[0], ink[1], ink[2], Math.round(255 * cover));
    }
  }
}
