import { deflateSync } from "node:zlib";

/**
 * Renders the TokenPulse mark (ring arc + pulse line) as an RGBA PNG without
 * native deps. Geometry matches menubar/Artwork/generate-icon.swift in a
 * 1024-unit, y-down space.
 */

type RGB = [number, number, number];
type Pt = [number, number];

const CYAN: RGB = [88, 210, 236];
const NAVY: RGB = [14, 25, 41];
const CENTER: Pt = [512, 512];
const RADIUS = 276;
const RING_HALF = 29;
const PULSE_HALF = 26;
/** AppKit arc 40°→310° counter-clockwise; the gap sits on the right. */
const ARC_START = (40 * Math.PI) / 180;
const ARC_END = (310 * Math.PI) / 180;
const PULSE: Pt[] = [
  [245, 512],
  [385, 512],
  [448, 389],
  [545, 654],
  [610, 512],
  [780, 512],
];

function segDist(p: Pt, a: Pt, b: Pt): number {
  const vx = b[0] - a[0];
  const vy = b[1] - a[1];
  const wx = p[0] - a[0];
  const wy = p[1] - a[1];
  const t = Math.max(0, Math.min(1, (wx * vx + wy * vy) / (vx * vx + vy * vy)));
  return Math.hypot(wx - t * vx, wy - t * vy);
}

function arcPoint(theta: number): Pt {
  return [CENTER[0] + RADIUS * Math.cos(theta), CENTER[1] - RADIUS * Math.sin(theta)];
}

function arcDist(p: Pt): number {
  const dx = p[0] - CENTER[0];
  const dy = CENTER[1] - p[1];
  let theta = Math.atan2(dy, dx);
  if (theta < 0) theta += 2 * Math.PI;
  if (theta >= ARC_START && theta <= ARC_END) {
    return Math.abs(Math.hypot(dx, dy) - RADIUS);
  }
  const s = arcPoint(ARC_START);
  const e = arcPoint(ARC_END);
  return Math.min(Math.hypot(p[0] - s[0], p[1] - s[1]), Math.hypot(p[0] - e[0], p[1] - e[1]));
}

function pulseDist(p: Pt): number {
  let d = Infinity;
  for (let i = 0; i < PULSE.length - 1; i++) d = Math.min(d, segDist(p, PULSE[i], PULSE[i + 1]));
  return d;
}

function roundedRectSdf(p: Pt): number {
  const half = 448;
  const r = 200;
  const qx = Math.abs(p[0] - 512) - (half - r);
  const qy = Math.abs(p[1] - 512) - (half - r);
  const outside = Math.hypot(Math.max(qx, 0), Math.max(qy, 0));
  return outside + Math.min(Math.max(qx, qy), 0) - r;
}

export interface RenderOptions {
  size: number;
  /** "app": navy tile + track. "tray": mark only, cropped to fill the square. */
  variant: "app" | "tray";
  /** Tray color; macOS template images should be black. */
  color?: RGB;
}

export function renderMark(opts: RenderOptions): Buffer {
  const { size, variant } = opts;
  const color = opts.color ?? CYAN;
  const view = variant === "tray" ? { x: 196, span: 632 } : { x: 0, span: 1024 };
  const unitsPerPx = view.span / size;
  const rgba = Buffer.alloc(size * size * 4);

  const coverage = (sdf: number) => Math.max(0, Math.min(1, 0.5 - sdf / unitsPerPx));

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const p: Pt = [view.x + (x + 0.5) * unitsPerPx, view.x + (y + 0.5) * unitsPerPx];
      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;
      const over = (rgb: RGB, alpha: number) => {
        if (alpha <= 0) return;
        const outA = alpha + a * (1 - alpha);
        r = (rgb[0] * alpha + r * a * (1 - alpha)) / outA;
        g = (rgb[1] * alpha + g * a * (1 - alpha)) / outA;
        b = (rgb[2] * alpha + b * a * (1 - alpha)) / outA;
        a = outA;
      };
      if (variant === "app") {
        over(NAVY, coverage(roundedRectSdf(p)));
        const ring = Math.abs(Math.hypot(p[0] - CENTER[0], p[1] - CENTER[1]) - RADIUS) - RING_HALF;
        over(color, 0.22 * coverage(ring));
      }
      over(color, coverage(arcDist(p) - RING_HALF));
      over(color, coverage(pulseDist(p) - PULSE_HALF));
      const i = (y * size + x) * 4;
      rgba[i] = Math.round(r);
      rgba[i + 1] = Math.round(g);
      rgba[i + 2] = Math.round(b);
      rgba[i + 3] = Math.round(a * 255);
    }
  }
  return encodePng(size, size, rgba);
}

function crc32(buf: Buffer): number {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Buffer): Buffer {
  const typeBuf = Buffer.from(type, "ascii");
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crc]);
}

export function encodePng(width: number, height: number, rgba: Buffer): Buffer {
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
