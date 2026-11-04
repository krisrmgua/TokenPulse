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
 * Tray renderer for macOS + Windows (same canvas path on both).
 * Divider/rings/focus sized up so type fills the capsule; stacked stays its own scale.
 */
const VALUE_FONT =
  '600 16px ".AppleSystemUIFontMonospacedDigit", "SF Pro Text", -apple-system';
const LABEL_FONT = '600 15px "SF Pro Text", -apple-system';
const VALUE_FONT_STACKED =
  '600 13px ".AppleSystemUIFontMonospacedDigit", "SF Pro Text", -apple-system';
const LABEL_FONT_STACKED = '600 12px "SF Pro Text", -apple-system';

const iconCache = new Map<string, Image>();

function rgb(c: [number, number, number], alpha = 1): string {
  return `rgba(${c[0]}, ${c[1]}, ${c[2]}, ${alpha})`;
}

function chromeHeight(design: BarDesign): number {
  if (isStacked(design)) return 28;
  // Divider/rings/focus: taller capsule around the larger type.
  return design === "baseline" ? 32 : 30;
}

function iconSizeFor(_design: BarDesign): number {
  return 18;
}

/** Horizontal padding / gaps — divider gets more air so the larger type isn't cramped. */
function padFor(design: BarDesign): number {
  return isStacked(design) ? 7 : 9;
}

function iconGapFor(design: BarDesign): number {
  return isStacked(design) ? 5 : 6;
}

function labelValueGap(design: BarDesign): number {
  return isStacked(design) ? 5 : 6;
}

function metricGap(design: BarDesign): number {
  return isStacked(design) ? 0 : 16;
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
  const lv = labelValueGap(b.design);
  const mg = metricGap(b.design);
  let content = 0;
  b.metrics.forEach((m, i) => {
    const row =
      measure(ctx, m.label, labelFont) +
      lv +
      measure(ctx, m.value, valueFont) +
      (b.design === "rings" && m.percent !== undefined ? 21 : 0);
    content += row + (i > 0 ? mg : 0);
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
  const gap = 5;
  const height = Math.max(...blocks.map((b) => chromeHeight(b.design)));

  const scratch = createCanvas(4, 4);
  const mctx = scratch.getContext("2d");
  // Measure fonts at device pixels so advances match the paint pass.
  mctx.font = VALUE_FONT_STACKED;
  const widths = blocks.map((b) => {
    const { value, label } = fontsFor(b.design);
    const pad = padFor(b.design);
    return (
      pad + iconSizeFor(b.design) + iconGapFor(b.design) + contentWidth(mctx, b, value, label) + pad
    );
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
    const iconSize = iconSizeFor(b.design);
    const pad = padFor(b.design);
    const iconGap = iconGapFor(b.design);
    const lvGap = labelValueGap(b.design);
    const mGap = metricGap(b.design);
    const y0 = (height - bh) / 2;
    const alpha = b.stale ? 0.45 : 1;
    ctx.globalAlpha = alpha;

    if (prefs.darkBarBackground) {
      ctx.fillStyle = b.allowanceEmpty ? EXHAUSTED : PANEL;
      roundRect(ctx, pt(x), pt(y0), pt(bw), pt(bh), pt(isStacked(b.design) ? 6 : 8));
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
    let cursor = x + pad + iconSize + iconGap;
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
        // Top-origin; value sits 1pt above label. Stride 12 + inset 3 → ~2pt pad in 28pt chrome.
        const rowY =
          b.metrics.length === 1 ? y0 + 7 : y0 + mi * 12 + 3;
        ctx.textBaseline = "top";
        ctx.fillStyle = LABEL;
        ctx.font = labelFontPx;
        ctx.fillText(m.label, pt(cursor), pt(rowY));
        let valueX = cursor + labelColW + 5;
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
        ctx.fillStyle = color;
        ctx.font = valueFontPx;
        ctx.fillText(m.value, pt(valueX), pt(rowY - 1));
        return;
      }

      if (b.design === "divider" && mi > 0) {
        ctx.fillStyle = TRACK;
        ctx.fillRect(pt(cursor - mGap / 2), pt(y0 + 8), pt(1), pt(14));
      }

      const labelW = measure(ctx, m.label, labelFontPx) / S;
      const valueW = measure(ctx, m.value, valueFontPx) / S;
      const rowInner =
        labelW + lvGap + valueW + (b.design === "rings" && m.percent !== undefined ? 21 : 0);

      if (b.design === "focus" && m.percent === minPct && minPct < 999) {
        ctx.fillStyle = rgb(m.color, 0.18);
        roundRect(ctx, pt(cursor - 3), pt(y0 + 5), pt(rowInner + 6), pt(20), pt(3));
        ctx.fill();
        ctx.fillStyle = color;
        roundRect(ctx, pt(cursor - 3), pt(y0 + 8), pt(2), pt(14), pt(1));
        ctx.fill();
        cursor += 3;
      }

      if (b.design === "rings" && m.percent !== undefined) {
        const cx = pt(cursor + 8);
        const cy = pt(y0 + bh / 2);
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

      // Top-origin; 16px $ vs 15px D/M — half-point keeps optical centers aligned.
      const rowY = y0 + (b.design === "baseline" ? 4 : 7);
      const labelOffset = b.design === "baseline" ? -1 : 1;
      const valueOffset = b.design === "baseline" ? -2 : 0.5;
      ctx.textBaseline = "top";
      ctx.fillStyle = LABEL;
      ctx.font = labelFontPx;
      ctx.fillText(m.label, pt(cursor), pt(rowY + labelOffset));
      ctx.fillStyle = color;
      ctx.font = valueFontPx;
      ctx.fillText(m.value, pt(cursor + labelW + lvGap), pt(rowY + valueOffset));


      if ((b.design === "baseline" || b.design === "divider") && m.percent !== undefined) {
        const my = y0 + (b.design === "baseline" ? 22 : 24);
        const meterW = labelW + lvGap + valueW;
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

      cursor += labelW + lvGap + valueW + mGap + (b.design === "focus" ? 5 : 0);
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
