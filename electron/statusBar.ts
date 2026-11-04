import { nativeImage } from "electron";
import { isStacked, type BarDesign } from "./barDesign";
import { shortMoney } from "./format";
import { encodePng } from "./iconRaster";
import { providerIconRgba } from "./providerArt";
import { tintBalanceUSD, tintRemainingPct, tintSpendUSD } from "./spendTint";
import {
  PROVIDER_ORDER,
  type Prefs,
  type SourceId,
  type SourceSnapshot,
} from "./types";

const PANEL: [number, number, number] = [19, 41, 59];
const EXHAUSTED: [number, number, number] = [77, 19, 20];
const TRACK: [number, number, number] = [59, 82, 99];
const LABEL: [number, number, number] = [153, 173, 199];

export interface StatusMetric {
  label: string;
  value: string;
  percent?: number;
  color: [number, number, number];
}

export interface StatusBlock {
  id: SourceId;
  metrics: StatusMetric[];
  stale: boolean;
  allowanceEmpty: boolean;
  design: BarDesign;
}

export function blocksFromSources(sources: SourceSnapshot[], prefs: Prefs): StatusBlock[] {
  const byId = new Map(sources.map((s) => [s.id, s]));
  const out: StatusBlock[] = [];
  for (const id of PROVIDER_ORDER) {
    const s = byId.get(id);
    if (!s || !s.enabled || !s.showInTray) continue;
    const sp = prefs.sources[id];
    const metrics = metricsFor(s, sp, prefs);
    if (metrics.length === 0) continue;
    out.push({
      id,
      metrics,
      stale: s.status === "stale",
      allowanceEmpty: metrics.some((m) => m.percent !== undefined && m.percent <= 0),
      design: sp.barDesign,
    });
  }
  return out;
}

function metricsFor(
  s: SourceSnapshot,
  sp: Prefs["sources"][SourceId],
  prefs: Prefs,
): StatusMetric[] {
  const colorOpts = {
    spendColorsEnabled: prefs.spendColorsEnabled,
    pastelBarColors: prefs.pastelBarColors,
    themedProviderLogos: prefs.themedProviderLogos,
  };

  if (s.meters.length > 0) {
    return s.meters.map((m) => {
      const pct = Math.max(0, Math.min(100, Math.round(m.percentLeft)));
      const label =
        m.id === "session" || /5.?h/i.test(m.label)
          ? "5H"
          : /week/i.test(m.label)
            ? "W"
            : /pro|included|allowance/i.test(m.label)
              ? s.id === "grokbot"
                ? "W"
                : "Pro"
              : m.label.slice(0, 3);
      return {
        label,
        value: `${pct}%`,
        percent: pct,
        color: tintRemainingPct(pct, colorOpts),
      };
    });
  }

  const metrics: StatusMetric[] = [];
  if (s.id === "openai") {
    const balLine = s.lines.find((l) => /balance/i.test(l.label));
    if (balLine) {
      const n = Number(balLine.value.replace(/[^0-9.]/g, ""));
      metrics.push({
        label: "B",
        value: balLine.value.replace(/\s/g, ""),
        color: Number.isFinite(n)
          ? tintBalanceUSD(n, colorOpts)
          : tintSpendUSD(0, s.id, colorOpts, "month"),
      });
    }
  }
  if (s.todayUSD !== undefined && sp.showDailyInBar) {
    metrics.push({
      label: "D",
      value: shortMoney(s.todayUSD),
      color: tintSpendUSD(s.todayUSD, s.id, colorOpts, "day"),
    });
  }
  if (s.monthUSD !== undefined && sp.showMonthlyInBar) {
    metrics.push({
      label: "M",
      value: shortMoney(s.monthUSD),
      color: tintSpendUSD(s.monthUSD, s.id, colorOpts, "month"),
    });
  }
  return metrics;
}

/** 5×7 glyphs for menu-bar metrics. */
const GLYPHS: Record<string, number[]> = {
  "0": [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
  "1": [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
  "2": [0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111],
  "3": [0b01110, 0b10001, 0b00001, 0b00110, 0b00001, 0b10001, 0b01110],
  "4": [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
  "5": [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],
  "6": [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
  "7": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
  "8": [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
  "9": [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],
  $: [0b00100, 0b01110, 0b10101, 0b10100, 0b01110, 0b00101, 0b11110],
  "%": [0b11001, 0b11010, 0b00010, 0b00100, 0b01000, 0b01011, 0b10011],
  ".": [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b00100],
  k: [0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010],
  H: [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
  W: [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010],
  D: [0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100],
  M: [0b10001, 0b11011, 0b10101, 0b10001, 0b10001, 0b10001, 0b10001],
  B: [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
  P: [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
  r: [0b00000, 0b00000, 0b10110, 0b11001, 0b10000, 0b10000, 0b10000],
  o: [0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110],
  "—": [0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000],
  "…": [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b10101, 0b00000],
  " ": [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000],
};

function textWidth(s: string, scale: number): number {
  let w = 0;
  for (const ch of s) {
    w += (GLYPHS[ch] ? 5 : 4) * scale + scale;
  }
  return Math.max(0, w - scale);
}

function drawText(
  buf: Buffer,
  width: number,
  height: number,
  s: string,
  x: number,
  y: number,
  rgb: [number, number, number],
  scale: number,
): void {
  let cx = Math.round(x);
  const cy = Math.round(y);
  for (const ch of s) {
    const g = GLYPHS[ch] ?? GLYPHS["."];
    for (let row = 0; row < 7; row++) {
      for (let col = 0; col < 5; col++) {
        if (((g[row] >> (4 - col)) & 1) === 0) continue;
        for (let dy = 0; dy < scale; dy++) {
          for (let dx = 0; dx < scale; dx++) {
            put(buf, width, height, cx + col * scale + dx, cy + row * scale + dy, rgb, 255);
          }
        }
      }
    }
    cx += 5 * scale + scale;
  }
}

function put(
  buf: Buffer,
  w: number,
  h: number,
  x: number,
  y: number,
  rgb: [number, number, number],
  a: number,
): void {
  if (x < 0 || y < 0 || x >= w || y >= h || a <= 0) return;
  const i = (y * w + x) * 4;
  const srcA = a / 255;
  const dstA = buf[i + 3] / 255;
  const outA = srcA + dstA * (1 - srcA);
  if (outA <= 0) return;
  buf[i] = Math.round((rgb[0] * srcA + buf[i] * dstA * (1 - srcA)) / outA);
  buf[i + 1] = Math.round((rgb[1] * srcA + buf[i + 1] * dstA * (1 - srcA)) / outA);
  buf[i + 2] = Math.round((rgb[2] * srcA + buf[i + 2] * dstA * (1 - srcA)) / outA);
  buf[i + 3] = Math.round(outA * 255);
}

function fillRoundRect(
  buf: Buffer,
  width: number,
  height: number,
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
      const cx = Math.min(Math.max(x + 0.5, r), w - r);
      const cy = Math.min(Math.max(y + 0.5, r), h - r);
      const d = Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
      const cover = d <= r - 0.5 ? 1 : d >= r + 0.5 ? 0 : r + 0.5 - d;
      if (cover > 0) put(buf, width, height, x0 + x, y0 + y, rgb, Math.round(a * cover));
    }
  }
}

function blitIcon(
  dest: Buffer,
  dw: number,
  dh: number,
  icon: Buffer,
  size: number,
  ox: number,
  oy: number,
  alphaMul: number,
): void {
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 4;
      const a = Math.round(icon[i + 3] * alphaMul);
      if (a <= 0) continue;
      put(dest, dw, dh, ox + x, oy + y, [icon[i], icon[i + 1], icon[i + 2]], a);
    }
  }
}

function chromeHeight(design: BarDesign): number {
  // Slightly taller than Swift 22/24 so the larger marks still sit with padding.
  return isStacked(design) || design === "baseline" ? 28 : 26;
}

/**
 * Compose distinct per-provider capsules as one Retina PNG for the tray.
 */
export function createStatusBarImage(blocks: StatusBlock[], prefs: Prefs): Electron.NativeImage {
  if (blocks.length === 0) {
    return nativeImage.createEmpty();
  }

  const scale = 2; // draw @2x then set scaleFactor
  // Swift uses 14pt increased; we paint a bit larger so Artwork cutouts read clearly.
  const iconSize = 18 * scale;
  const gap = 5 * scale;
  const pad = 6 * scale;
  const heights = blocks.map((b) => chromeHeight(b.design) * scale);
  const height = Math.max(...heights);
  const valueScale = 2;
  const labelScale = 2;

  const widths = blocks.map((b) => {
    if (isStacked(b.design)) {
      const labels = Math.max(...b.metrics.map((m) => textWidth(m.label, labelScale)), 0);
      const values = Math.max(...b.metrics.map((m) => textWidth(m.value, valueScale)), 0);
      const track = b.design === "lanes" || b.design === "segments" ? 60 * scale : 0;
      return pad + iconSize + pad + labels + 5 * scale + track + values + pad;
    }
    let content = 0;
    b.metrics.forEach((m, i) => {
      const row =
        textWidth(m.label, labelScale) +
        4 * scale +
        textWidth(m.value, valueScale) +
        (b.design === "rings" && m.percent !== undefined ? 21 * scale : 0);
      content += row + (i > 0 ? 13 * scale : 0);
      if (b.design === "focus") content += 8 * scale;
    });
    return pad + iconSize + pad + Math.max(content, 8 * scale) + pad;
  });

  const total = widths.reduce((a, b) => a + b, 0) + gap * Math.max(0, blocks.length - 1);
  const buf = Buffer.alloc(total * height * 4);

  let x = 0;
  for (let bi = 0; bi < blocks.length; bi++) {
    const b = blocks[bi];
    const bw = widths[bi];
    const bh = heights[bi];
    const y0 = Math.round((height - bh) / 2);
    const alphaMul = b.stale ? 0.45 : 1;
    if (prefs.darkBarBackground) {
      fillRoundRect(
        buf,
        total,
        height,
        x,
        y0,
        bw,
        bh,
        6 * scale,
        b.allowanceEmpty ? EXHAUSTED : PANEL,
        Math.round(242 * alphaMul),
      );
    }

    const icon = providerIconRgba(b.id, iconSize, prefs.themedProviderLogos);
    blitIcon(
      buf,
      total,
      height,
      icon,
      iconSize,
      x + pad,
      y0 + Math.round((bh - iconSize) / 2),
      alphaMul,
    );

    let cursor = x + pad + iconSize + pad;
    const labels = Math.max(...b.metrics.map((m) => textWidth(m.label, labelScale)), 0);
    const values = Math.max(...b.metrics.map((m) => textWidth(m.value, valueScale)), 0);
    const minPct = Math.min(
      ...b.metrics.filter((m) => m.percent !== undefined).map((m) => m.percent as number),
      999,
    );

    b.metrics.forEach((m, mi) => {
      const color: [number, number, number] = [
        Math.round(m.color[0] * alphaMul + LABEL[0] * (1 - alphaMul)),
        Math.round(m.color[1] * alphaMul + LABEL[1] * (1 - alphaMul)),
        Math.round(m.color[2] * alphaMul + LABEL[2] * (1 - alphaMul)),
      ];

      if (isStacked(b.design)) {
        // Center the D/M block as a whole in the capsule (same idea as the icon).
        const glyphH = 7 * labelScale;
        const rowPitch = Math.round(10.5 * scale);
        const n = b.metrics.length;
        const blockH = n <= 1 ? glyphH : glyphH + (n - 1) * rowPitch;
        const startY = y0 + Math.round((bh - blockH) / 2);
        const rowY = startY + mi * rowPitch;
        drawText(buf, total, height, m.label, cursor, rowY, LABEL, labelScale);
        let valueX = cursor + labels + 5 * scale;
        if ((b.design === "lanes" || b.design === "segments") && m.percent !== undefined) {
          const mw = 54 * scale;
          fillRoundRect(buf, total, height, valueX, rowY + 4 * scale, mw, 4 * scale, 2 * scale, TRACK, 255);
          const frac = Math.max(0, Math.min(1, (m.percent ?? 0) / 100));
          if (frac > 0) {
            fillRoundRect(
              buf,
              total,
              height,
              valueX,
              rowY + 4 * scale,
              Math.round(mw * frac),
              4 * scale,
              2 * scale,
              m.color,
              255,
            );
          }
          valueX += 60 * scale;
        }
        drawText(
          buf,
          total,
          height,
          m.value,
          valueX + values - textWidth(m.value, valueScale),
          rowY,
          color,
          valueScale,
        );
        return;
      }

      if (b.design === "divider" && mi > 0) {
        fillRoundRect(buf, total, height, cursor - 7 * scale, y0 + 5 * scale, scale, 12 * scale, 0, TRACK, 255);
      }

      if (b.design === "focus" && m.percent === minPct && minPct < 999) {
        const rowW =
          textWidth(m.label, labelScale) + 4 * scale + textWidth(m.value, valueScale);
        fillRoundRect(
          buf,
          total,
          height,
          cursor - 3 * scale,
          y0 + 2 * scale,
          rowW + 6 * scale,
          18 * scale,
          3 * scale,
          m.color,
          46,
        );
        fillRoundRect(
          buf,
          total,
          height,
          cursor - 3 * scale,
          y0 + 5 * scale,
          2 * scale,
          12 * scale,
          scale,
          m.color,
          255,
        );
        cursor += 3 * scale;
      }

      if (b.design === "rings" && m.percent !== undefined) {
        // simple ring track
        const cx = cursor + 8 * scale;
        const cy = y0 + 11 * scale;
        const r = 7 * scale;
        for (let a = 0; a < 360; a += 3) {
          const rad = (a * Math.PI) / 180;
          put(
            buf,
            total,
            height,
            Math.round(cx + r * Math.cos(rad)),
            Math.round(cy + r * Math.sin(rad)),
            TRACK,
            220,
          );
        }
        const frac = Math.max(0, Math.min(1, m.percent / 100));
        for (let a = -90; a < -90 + 360 * frac; a += 3) {
          const rad = (a * Math.PI) / 180;
          put(
            buf,
            total,
            height,
            Math.round(cx + r * Math.cos(rad)),
            Math.round(cy + r * Math.sin(rad)),
            m.color,
            255,
          );
        }
        cursor += 21 * scale;
      }

      const rowY = y0 + (b.design === "baseline" ? 3 * scale : 5 * scale);
      drawText(buf, total, height, m.label, cursor, rowY, LABEL, labelScale);
      const vx = cursor + textWidth(m.label, labelScale) + 4 * scale;
      drawText(buf, total, height, m.value, vx, rowY, color, valueScale);
      const rowW = textWidth(m.label, labelScale) + 4 * scale + textWidth(m.value, valueScale);
      if ((b.design === "baseline" || b.design === "divider") && m.percent !== undefined) {
        const my = y0 + bh - 5 * scale;
        fillRoundRect(buf, total, height, cursor, my, rowW, 2 * scale, scale, TRACK, 255);
        const frac = Math.max(0, Math.min(1, m.percent / 100));
        if (frac > 0) {
          fillRoundRect(
            buf,
            total,
            height,
            cursor,
            my,
            Math.round(rowW * frac),
            2 * scale,
            scale,
            m.color,
            255,
          );
        }
      }
      cursor += rowW + 13 * scale + (b.design === "focus" ? 5 * scale : 0);
    });

    x += bw + gap;
  }

  const png = encodePng(total, height, buf);
  return nativeImage.createFromBuffer(png, { scaleFactor: scale });
}
