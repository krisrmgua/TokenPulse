import fs from "node:fs";
import path from "node:path";
import { createCanvas, loadImage, type Image, type SKRSContext2D } from "@napi-rs/canvas";
import { isStacked, type BarDesign } from "./barDesign";
import type { Prefs, SourceId } from "./types";
import type { StatusBlock } from "./statusBarTypes";

export type { StatusBlock, StatusMetric } from "./statusBarTypes";

const PANEL = "rgba(19, 41, 59, 0.95)";
const EXHAUSTED = "rgba(77, 19, 20, 0.95)";
const TRACK = "rgb(59, 82, 99)";
const LABEL = "rgb(153, 173, 199)";

/**
 * Stacked values use Menlo so `$` / digits share one advance and both rows
 * rasterize the same (AppleSystemUIFontMonospacedDigit was drifting per line).
 * Divider / single-line styles match Swift: monospaced-digit system font,
 * semibold — not Menlo.
 */
const VALUE_FONT_STACKED = '700 11px Menlo, "SF Mono", ui-monospace, monospace';
const LABEL_FONT_STACKED = '600 10px -apple-system, "SF Pro Text", system-ui, sans-serif';
const VALUE_FONT =
  '600 12px ".AppleSystemUIFontMonospacedDigit", -apple-system, "SF Pro Text", system-ui, sans-serif';
const LABEL_FONT = '600 11px -apple-system, "SF Pro Text", system-ui, sans-serif';

const iconCache = new Map<string, Image>();

function rgb(c: [number, number, number], alpha = 1): string {
  return `rgba(${c[0]}, ${c[1]}, ${c[2]}, ${alpha})`;
}

function chromeHeight(design: BarDesign): number {
  return isStacked(design) || design === "baseline" ? 24 : 22;
}

function fontsFor(design: BarDesign): { value: string; label: string } {
  if (isStacked(design)) {
    return { value: VALUE_FONT_STACKED, label: LABEL_FONT_STACKED };
  }
  return { value: VALUE_FONT, label: LABEL_FONT };
}

function measure(ctx: SKRSContext2D, text: string, font: string): number {
  ctx.font = font;
  return Math.ceil(ctx.measureText(text).width);
}

let artworkRootOverride: string | null = null;

/** Preview / tests: point at repo Artwork without Electron `app`. */
export function setArtworkRoot(root: string | null): void {
  artworkRootOverride = root;
  iconCache.clear();
}

function providersDir(): string {
  if (artworkRootOverride) return path.join(artworkRootOverride, "providers");
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { app } = require("electron") as typeof import("electron");
    if (app?.isPackaged) return path.join(process.resourcesPath, "Artwork", "providers");
  } catch {
    /* not in Electron */
  }
  return path.join(process.cwd(), "menubar", "Artwork", "providers");
}

function iconPath(id: SourceId, themed: boolean): string | null {
  const name = themed ? `${id}-themed.png` : `${id}.png`;
  const file = path.join(providersDir(), name);
  if (fs.existsSync(file)) return file;
  const alt = path.join(providersDir(), themed ? `${id}.png` : `${id}-themed.png`);
  return fs.existsSync(alt) ? alt : null;
}

/** Warm provider icons (napi-rs needs async loadImage — Buffer Image.src does not paint). */
export async function warmStatusBarIcons(
  ids: SourceId[],
  themed: boolean,
): Promise<void> {
  await Promise.all(
    ids.map(async (id) => {
      const key = `${id}:${themed ? "t" : "p"}`;
      if (iconCache.has(key)) return;
      const file = iconPath(id, themed);
      if (!file) return;
      iconCache.set(key, await loadImage(file));
    }),
  );
}

function cachedIcon(id: SourceId, themed: boolean): Image | null {
  return iconCache.get(`${id}:${themed ? "t" : "p"}`) ?? null;
}

function contentWidth(
  ctx: SKRSContext2D,
  b: StatusBlock,
  valueFont: string,
  labelFont: string,
): number {
  if (isStacked(b.design)) {
    const labels = Math.max(0, ...b.metrics.map((m) => measure(ctx, m.label, labelFont)));
    const values = Math.max(0, ...b.metrics.map((m) => measure(ctx, m.value, valueFont)));
    const track =
      (b.design === "lanes" || b.design === "segments") &&
      b.metrics.some((m) => m.percent !== undefined)
        ? 60
        : 0;
    return labels + 5 + track + values;
  }
  let content = 0;
  b.metrics.forEach((m, i) => {
    const row =
      measure(ctx, m.label, labelFont) +
      4 +
      measure(ctx, m.value, valueFont) +
      (b.design === "rings" && m.percent !== undefined ? 21 : 0);
    content += row + (i > 0 ? 13 : 0);
    if (b.design === "focus") content += 8;
  });
  return Math.max(content, 8);
}

function roundRect(
  ctx: SKRSContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
): void {
  const radius = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + radius, y);
  ctx.arcTo(x + w, y, x + w, y + h, radius);
  ctx.arcTo(x + w, y + h, x, y + h, radius);
  ctx.arcTo(x, y + h, x, y, radius);
  ctx.arcTo(x, y, x + w, y, radius);
  ctx.closePath();
}

/**
 * Paint Swift-matching status capsules at 1× CSS points into a 2× bitmap.
 * Call `warmStatusBarIcons` first so provider marks are available.
 */
export function renderStatusBarPng(
  blocks: StatusBlock[],
  prefs: Pick<Prefs, "darkBarBackground" | "themedProviderLogos">,
): { png: Buffer; width: number; height: number; scaleFactor: number } {
  if (blocks.length === 0) {
    return { png: Buffer.alloc(0), width: 0, height: 0, scaleFactor: 2 };
  }

  const scaleFactor = 2;
  // Larger than Swift's 14pt mark so the cube reads at menu-bar scale.
  const iconSize = 18;
  const pad = 5;
  const gap = 5;
  const height = Math.max(...blocks.map((b) => chromeHeight(b.design)));

  const scratch = createCanvas(4, 4);
  const mctx = scratch.getContext("2d");
  // Measure fonts at device pixels so advances match the paint pass.
  mctx.font = VALUE_FONT_STACKED;
  const widths = blocks.map((b) => {
    const { value, label } = fontsFor(b.design);
    return pad + iconSize + pad + contentWidth(mctx, b, value, label) + pad;
  });
  const total = widths.reduce((a, b) => a + b, 0) + gap * Math.max(0, blocks.length - 1);

  // Paint in device pixels (no ctx.scale) so every glyph hits whole pixels —
  // fractional x/y was making $91 and $104 look like different weights.
  const canvas = createCanvas(Math.ceil(total * scaleFactor), Math.ceil(height * scaleFactor));
  const ctx = canvas.getContext("2d");
  ctx.textBaseline = "top";
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  const S = scaleFactor;
  const pt = (n: number) => Math.round(n * S);

  let x = 0;
  for (let bi = 0; bi < blocks.length; bi++) {
    const b = blocks[bi];
    const bw = widths[bi];
    const bh = chromeHeight(b.design);
    const y0 = (height - bh) / 2;
    const alpha = b.stale ? 0.45 : 1;
    ctx.globalAlpha = alpha;

    if (prefs.darkBarBackground) {
      ctx.fillStyle = b.allowanceEmpty ? EXHAUSTED : PANEL;
      roundRect(ctx, pt(x), pt(y0), pt(bw), pt(bh), pt(6));
      ctx.fill();
    }

    const icon = cachedIcon(b.id, prefs.themedProviderLogos);
    if (icon) {
      ctx.drawImage(
        icon,
        pt(x + pad),
        pt(y0 + (bh - iconSize) / 2),
        pt(iconSize),
        pt(iconSize),
      );
    }

    const { value: valueFont, label: labelFont } = fontsFor(b.design);
    // Device-pixel font sizes (11pt → 22px @2x).
    const valueFontPx = valueFont.replace(/(\d+)px/, (_, n) => `${Number(n) * S}px`);
    const labelFontPx = labelFont.replace(/(\d+)px/, (_, n) => `${Number(n) * S}px`);
    let cursor = x + pad + iconSize + pad;
    const labelColW = Math.max(
      0,
      ...b.metrics.map((m) => measure(ctx, m.label, labelFontPx) / S),
    );
    const valueColW = Math.max(
      0,
      ...b.metrics.map((m) => measure(ctx, m.value, valueFontPx) / S),
    );
    void valueColW; // width reserved via left-aligned $ column
    const minPct = Math.min(
      ...b.metrics.filter((m) => m.percent !== undefined).map((m) => m.percent as number),
      999,
    );

    b.metrics.forEach((m, mi) => {
      const color = rgb(m.color);

      if (isStacked(b.design)) {
        // Two rows: even top/bottom pad in the 24pt chrome (pitch 10 → start 2).
        const rowPitch = b.metrics.length <= 1 ? 0 : 10;
        const stackH = (b.metrics.length - 1) * rowPitch + 10;
        const stackTop = y0 + (bh - stackH) / 2;
        const rowY = b.metrics.length === 1 ? y0 + (bh - 10) / 2 : stackTop + mi * rowPitch;
        ctx.fillStyle = LABEL;
        ctx.font = labelFontPx;
        ctx.fillText(m.label, pt(cursor), pt(rowY));
        let valueX = cursor + labelColW + 4;
        if ((b.design === "lanes" || b.design === "segments") && m.percent !== undefined) {
          const mw = 54;
          const my = rowY + 4;
          ctx.fillStyle = TRACK;
          roundRect(ctx, pt(valueX), pt(my), pt(mw), pt(4), pt(2));
          ctx.fill();
          const frac = Math.max(0, Math.min(1, m.percent / 100));
          if (frac > 0) {
            ctx.fillStyle = color;
            roundRect(ctx, pt(valueX), pt(my), pt(mw * frac), pt(4), pt(2));
            ctx.fill();
          }
          valueX += 60;
        }
        // Left-align values so stacked `$` share one column ($91 / $104).
        ctx.fillStyle = color;
        ctx.font = valueFontPx;
        ctx.fillText(m.value, pt(valueX), pt(rowY));
        return;
      }

      if (b.design === "divider" && mi > 0) {
        ctx.fillStyle = TRACK;
        ctx.fillRect(pt(cursor - 7), pt(y0 + 5), pt(1), pt(12));
      }

      const labelW = measure(ctx, m.label, labelFontPx) / S;
      const valueW = measure(ctx, m.value, valueFontPx) / S;
      const rowInner =
        labelW + 4 + valueW + (b.design === "rings" && m.percent !== undefined ? 21 : 0);

      if (b.design === "focus" && m.percent === minPct && minPct < 999) {
        ctx.fillStyle = rgb(m.color, 0.18);
        roundRect(ctx, pt(cursor - 3), pt(y0 + 2), pt(rowInner + 6), pt(18), pt(3));
        ctx.fill();
        ctx.fillStyle = color;
        roundRect(ctx, pt(cursor - 3), pt(y0 + 5), pt(2), pt(12), pt(1));
        ctx.fill();
        cursor += 3;
      }

      if (b.design === "rings" && m.percent !== undefined) {
        const cx = pt(cursor + 8);
        const cy = pt(y0 + 11);
        ctx.strokeStyle = TRACK;
        ctx.lineWidth = 2.5 * S;
        ctx.beginPath();
        ctx.arc(cx, cy, 8 * S, 0, Math.PI * 2);
        ctx.stroke();
        const frac = Math.max(0, Math.min(1, m.percent / 100));
        if (frac > 0) {
          ctx.strokeStyle = color;
          ctx.lineCap = "round";
          ctx.beginPath();
          ctx.arc(cx, cy, 8 * S, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * frac);
          ctx.stroke();
        }
        cursor += 21;
      }

      // Baseline keeps text high for the under-meter; divider / rings / focus
      // center the D/M row in the 22pt capsule (Swift optical mid).
      if (b.design === "baseline") {
        const rowY = y0 + 3;
        ctx.textBaseline = "top";
        ctx.fillStyle = LABEL;
        ctx.font = labelFontPx;
        ctx.fillText(m.label, pt(cursor), pt(rowY - 1));
        ctx.fillStyle = color;
        ctx.font = valueFontPx;
        ctx.fillText(m.value, pt(cursor + labelW + 4), pt(rowY - 2));
      } else {
        const midY = y0 + bh / 2;
        ctx.textBaseline = "middle";
        ctx.fillStyle = LABEL;
        ctx.font = labelFontPx;
        ctx.fillText(m.label, pt(cursor), pt(midY));
        ctx.fillStyle = color;
        ctx.font = valueFontPx;
        ctx.fillText(m.value, pt(cursor + labelW + 4), pt(midY));
        ctx.textBaseline = "top";
      }

      if ((b.design === "baseline" || b.design === "divider") && m.percent !== undefined) {
        const my = y0 + 18;
        const meterW = labelW + 4 + valueW;
        ctx.fillStyle = TRACK;
        roundRect(ctx, pt(cursor), pt(my), pt(meterW), pt(4), pt(2));
        ctx.fill();
        const frac = Math.max(0, Math.min(1, m.percent / 100));
        if (frac > 0) {
          ctx.fillStyle = color;
          roundRect(ctx, pt(cursor), pt(my), pt(meterW * frac), pt(4), pt(2));
          ctx.fill();
        }
      }

      cursor += labelW + 4 + valueW + 13 + (b.design === "focus" ? 5 : 0);
    });

    ctx.globalAlpha = 1;
    x += bw + gap;
  }

  return {
    png: canvas.toBuffer("image/png"),
    width: total,
    height,
    scaleFactor,
  };
}
