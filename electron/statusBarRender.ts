import fs from "node:fs";
import path from "node:path";
import { createCanvas, loadImage, type Image, type SKRSContext2D } from "@napi-rs/canvas";
import { isStacked, type BarDesign } from "./barDesign";
import { menuBarScaleFromRaw, type Prefs, type SourceId } from "./types";
import type { StatusBlock, StatusMetric } from "./statusBarTypes";

export type { StatusBlock, StatusMetric } from "./statusBarTypes";

const PANEL = "rgba(19, 41, 59, 0.95)";
const EXHAUSTED = "rgba(77, 19, 20, 0.95)";
const TRACK = "rgb(59, 82, 99)";
const LABEL = "rgb(206, 218, 232)";

/**
 * Tray renderer for macOS + Windows (same canvas path on both).
 * Divider chrome matches stacked height; divider type is larger inside that capsule.
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

/** Size factor for every menu-bar style, including Compact stack. `percent` is 100…65. */
function menuScale(percent: number): number {
  return menuBarScaleFromRaw(percent, false) / 100;
}

function chromeHeight(design: BarDesign, metricCount = 2, k = 1): number {
  // Same capsule height for stacked + divider so neighbors match in the menu bar.
  // A third stacked figure (OpenAI B) needs another row.
  const base = isStacked(design) && metricCount > 2 ? 4 + metricCount * 12 : 28;
  return base * k;
}

function iconSizeFor(_design: BarDesign, k = 1): number {
  return 18 * k;
}

/** Side inset. Shrinks with the size so a smaller pill also has less empty space. */
function pillPad(k: number): number {
  return Math.max(2, Math.round(7 * k));
}

function iconGapFor(k: number): number {
  return Math.max(2, Math.round(5 * k));
}

function labelValueGap(_design: BarDesign): number {
  return 5;
}

function metricGap(design: BarDesign): number {
  return isStacked(design) ? 0 : 13;
}

function fontsFor(design: BarDesign, k = 1): { value: string; label: string } {
  const base = isStacked(design)
    ? { value: VALUE_FONT_STACKED, label: LABEL_FONT_STACKED }
    : { value: VALUE_FONT, label: LABEL_FONT };
  if (k === 1) return base;
  const scale = (font: string) =>
    font.replace(/(\d+(?:\.\d+)?)px/, (_, n) => `${Math.max(8, Math.round(Number(n) * k))}px`);
  return { value: scale(base.value), label: scale(base.label) };
}

function measure(ctx: SKRSContext2D, text: string, font: string): number {
  ctx.font = font;
  return Math.ceil(ctx.measureText(text).width);
}

/** Alphabetic y that centers the painted glyphs on `mid` (device px). Caps sit high in the em box. */
function inkBaseline(ctx: SKRSContext2D, text: string, mid: number): number {
  const ink = ctx.measureText(text);
  const ascent = ink.actualBoundingBoxAscent || 0;
  const descent = ink.actualBoundingBoxDescent || 0;
  if (ascent <= 0) return mid;
  return mid + (ascent - descent) / 2;
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

function iconPath(id: SourceId): string | null {
  const file = path.join(providersDir(), `${id}.png`);
  return fs.existsSync(file) ? file : null;
}

/** Warm provider icons (napi-rs needs async loadImage — Buffer Image.src does not paint). */
export async function warmStatusBarIcons(ids: SourceId[]): Promise<void> {
  await Promise.all(
    ids.map(async (id) => {
      if (iconCache.has(id)) return;
      const file = iconPath(id);
      if (!file) return;
      iconCache.set(id, lightenTowardWhite(await loadImage(file)));
    }),
  );
}

function cachedIcon(id: SourceId): Image | null {
  return iconCache.get(id) ?? null;
}

/** Pull a menu-bar mark a step toward white without changing its shape. */
function lightenTowardWhite(icon: Image): Image {
  const canvas = createCanvas(icon.width, icon.height);
  const g = canvas.getContext("2d");
  g.drawImage(icon, 0, 0);
  g.globalCompositeOperation = "source-atop";
  g.fillStyle = "rgba(255,255,255,0.42)";
  g.fillRect(0, 0, icon.width, icon.height);
  return canvas as unknown as Image;
}

function contentWidth(
  ctx: SKRSContext2D,
  b: StatusBlock,
  valueFont: string,
  labelFont: string,
  k = 1,
): number {
  if (isStacked(b.design)) {
    const labels = Math.max(0, ...b.metrics.map((m) => measure(ctx, m.label, labelFont)));
    const values = Math.max(0, ...b.metrics.map((m) => measure(ctx, m.value, valueFont)));
    const track =
      (b.design === "lanes" || b.design === "segments") &&
      b.metrics.some((m) => m.percent !== undefined)
        ? 60 * k
        : 0;
    return labels + 5 * k + track + values;
  }
  const lv = labelValueGap(b.design) * k;
  const mg = metricGap(b.design) * k;
  let content = 0;
  b.metrics.forEach((m, i) => {
    const row =
      measure(ctx, m.label, labelFont) +
      lv +
      measure(ctx, m.value, valueFont) +
      (b.design === "rings" && m.percent !== undefined ? 21 * k : 0);
    content += row + (i > 0 ? mg : 0);
    if (b.design === "focus") content += 8 * k;
  });
  return Math.max(content, 8 * k);
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

/** Twin-gauge ring, sized so a 3-digit percent fits in the middle. */
const SHARED_RING = 26;

interface BarSegment {
  blocks: StatusBlock[];
  shared: boolean;
}

/** One shared pill where the first opted-in provider sits. Opted-out providers keep their own capsules. */
function barSegments(blocks: StatusBlock[]): BarSegment[] {
  const shared = blocks.filter((b) => b.sharedPill === true);
  let placed = false;
  const out: BarSegment[] = [];
  for (const block of blocks) {
    if (block.sharedPill === true) {
      if (!placed) {
        out.push({ blocks: shared, shared: true });
        placed = true;
      }
      continue;
    }
    out.push({ blocks: [block], shared: false });
  }
  return out;
}

function segmentHeight(seg: BarSegment, k: number): number {
  if (seg.shared) return 28 * k;
  const b = seg.blocks[0];
  return chromeHeight(b.design, b.metrics.length, k);
}

/** A letter in the ring needs less room than a 3-digit percent. */
function ringSlot(letters: boolean, label: string): number {
  if (!letters) return SHARED_RING;
  return label.length >= 3 ? SHARED_RING : 22;
}

function prefixBesideRing(metricCount: number, metric: StatusMetric, letters: boolean): boolean {
  if (metricCount <= 1) return false;
  return !(letters && metric.percent !== undefined);
}

function sharedInnerWidth(
  ctx: SKRSContext2D,
  blocks: StatusBlock[],
  k: number,
  valueFont: string,
  labelFont: string,
  letters: boolean,
): number {
  let width = 0;
  const icon = iconSizeFor("rings", k);
  const iconGap = iconGapFor(k);
  blocks.forEach((b, bi) => {
    if (bi > 0) width += 8 * k;
    width += icon + iconGap;
    b.metrics.forEach((m, mi) => {
      if (mi > 0) width += 6 * k;
      if (prefixBesideRing(b.metrics.length, m, letters)) {
        width += measure(ctx, m.label, labelFont) + 4 * k;
      }
      width += m.percent !== undefined ? ringSlot(letters, m.label) * k : measure(ctx, m.value, valueFont);
    });
  });
  return width;
}

function paintSharedPill(
  ctx: SKRSContext2D,
  blocks: StatusBlock[],
  x: number,
  y0: number,
  bw: number,
  bh: number,
  k: number,
  S: number,
  prefs: { darkBarBackground: boolean; sharedRingLetters?: boolean },
): void {
  const pt = (n: number) => Math.round(n * S);
  const pad = pillPad(k);
  const iconSize = iconSizeFor("rings", k);
  const iconGap = iconGapFor(k);
  const { value: valueFont, label: labelFont } = fontsFor("rings", k);
  const valueFontPx = valueFont.replace(/(\d+(?:\.\d+)?)px/, (_, n) => `${Number(n) * S}px`);
  const labelFontPx = labelFont.replace(/(\d+(?:\.\d+)?)px/, (_, n) => `${Number(n) * S}px`);
  const letters = prefs.sharedRingLetters === true;
  const midY = y0 + bh / 2;

  ctx.globalAlpha = 1;
  ctx.textAlign = "left";
  ctx.textBaseline = "middle";
  ctx.lineCap = "butt";
  if (prefs.darkBarBackground) {
    ctx.fillStyle = PANEL;
    roundRect(ctx, pt(x), pt(y0), pt(bw), pt(bh), pt(6 * k));
    ctx.fill();
  }

  let cursor = x + pad;
  blocks.forEach((b, bi) => {
    if (bi > 0) cursor += 8 * k;
    ctx.globalAlpha = b.stale ? 0.45 : 1;
    const icon = cachedIcon(b.id);
    if (icon) {
      ctx.drawImage(icon, pt(cursor), pt(midY - iconSize / 2), pt(iconSize), pt(iconSize));
    }
    cursor += iconSize + iconGap;
    b.metrics.forEach((m, mi) => {
      if (mi > 0) cursor += 6 * k;
      if (prefixBesideRing(b.metrics.length, m, letters)) {
        ctx.fillStyle = LABEL;
        ctx.font = labelFontPx;
        ctx.textAlign = "left";
        ctx.textBaseline = "middle";
        ctx.fillText(m.label, pt(cursor), pt(midY));
        cursor += measure(ctx, m.label, labelFontPx) / S + 4 * k;
      }
      if (m.percent === undefined) {
        ctx.fillStyle = rgb(m.color);
        ctx.font = valueFontPx;
        ctx.textAlign = "left";
        ctx.textBaseline = "middle";
        ctx.fillText(m.value, pt(cursor), pt(midY));
        cursor += measure(ctx, m.value, valueFontPx) / S;
        return;
      }
      const slot = ringSlot(letters, m.label) * k;
      const radius = (letters && m.label.length < 3 ? 9 : 11) * k;
      const cx = pt(cursor + slot / 2);
      const cy = pt(midY);
      ctx.strokeStyle = TRACK;
      ctx.lineWidth = 2.5 * k * S;
      ctx.lineCap = "butt";
      ctx.beginPath();
      ctx.arc(cx, cy, radius * S, 0, Math.PI * 2);
      ctx.stroke();
      const frac = Math.max(0, Math.min(1, m.percent / 100));
      if (frac > 0) {
        ctx.strokeStyle = rgb(m.color);
        ctx.lineCap = "round";
        ctx.beginPath();
        ctx.arc(cx, cy, radius * S, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * frac);
        ctx.stroke();
        ctx.lineCap = "butt";
      }
      const num = letters ? m.label : String(Math.round(m.percent));
      const numPt = (letters ? (num.length >= 3 ? 8 : 12) : num.length >= 3 ? 8 : 11) * k;
      ctx.fillStyle = rgb(m.color);
      ctx.font = `600 ${Math.round(numPt * S)}px ".AppleSystemUIFontMonospacedDigit", "SF Pro Text", -apple-system`;
      ctx.textAlign = "center";
      ctx.textBaseline = "alphabetic";
      const ink = ctx.measureText(num);
      const ascent = ink.actualBoundingBoxAscent || 0;
      const descent = ink.actualBoundingBoxDescent || 0;
      // Center the painted letters, not the em box. Caps sit high inside that box.
      const drop = ascent > 0 ? (ascent - descent) / 2 : numPt * S * 0.36;
      ctx.fillText(num, cx, cy + drop);
      cursor += slot;
    });
  });

  ctx.globalAlpha = 1;
  ctx.textAlign = "left";
  ctx.textBaseline = "top";
  ctx.lineCap = "butt";
}

/**
 * Paint Swift-matching status capsules at 1× CSS points into a 2× bitmap.
 * Call `warmStatusBarIcons` first so provider marks are available.
 */
export function renderStatusBarPng(
  blocks: StatusBlock[],
  prefs: Pick<Prefs, "darkBarBackground"> & {
    menuBarScale?: number;
    sharedRingLetters?: boolean;
  },
): { png: Buffer; width: number; height: number; scaleFactor: number } {
  if (blocks.length === 0) {
    return { png: Buffer.alloc(0), width: 0, height: 0, scaleFactor: 2 };
  }

  const scaleFactor = 2;
  const gapScale = menuScale(prefs.menuBarScale ?? 100);
  const gap = 5 * gapScale;
  const kBar = gapScale;
  const segs = barSegments(blocks);
  const height = Math.max(...segs.map((seg) => segmentHeight(seg, kBar)));

  const scratch = createCanvas(4, 4);
  const mctx = scratch.getContext("2d");
  // Measure fonts at device pixels so advances match the paint pass.
  mctx.font = VALUE_FONT_STACKED;
  const widths = segs.map((seg) => {
    if (seg.shared) {
      const { value, label } = fontsFor("rings", kBar);
      return (
        pillPad(kBar) +
        sharedInnerWidth(mctx, seg.blocks, kBar, value, label, prefs.sharedRingLetters === true) +
        pillPad(kBar)
      );
    }
    const b = seg.blocks[0];
    const { value, label } = fontsFor(b.design, kBar);
    const pad = pillPad(kBar);
    return pad + iconSizeFor(b.design, kBar) + iconGapFor(kBar) + contentWidth(mctx, b, value, label, kBar) + pad;
  });
  const total = widths.reduce((a, b) => a + b, 0) + gap * Math.max(0, segs.length - 1);

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
  for (let bi = 0; bi < segs.length; bi++) {
    const seg = segs[bi];
    const bw = widths[bi];
    if (seg.shared) {
      const bh = 28 * kBar;
      paintSharedPill(ctx, seg.blocks, x, (height - bh) / 2, bw, bh, kBar, S, prefs);
      x += bw + gap;
      continue;
    }
    const b = seg.blocks[0];
    const k = kBar;
    const bh = chromeHeight(b.design, b.metrics.length, k);
    const iconSize = iconSizeFor(b.design, k);
    const pad = pillPad(k);
    const iconGap = iconGapFor(k);
    const lvGap = labelValueGap(b.design) * k;
    const mGap = metricGap(b.design) * k;
    const y0 = (height - bh) / 2;
    const alpha = b.stale ? 0.45 : 1;
    ctx.globalAlpha = alpha;

    if (prefs.darkBarBackground) {
      ctx.fillStyle = b.allowanceEmpty ? EXHAUSTED : PANEL;
      roundRect(ctx, pt(x), pt(y0), pt(bw), pt(bh), pt(6 * k));
      ctx.fill();
    }

    const icon = cachedIcon(b.id);
    if (icon) {
      ctx.drawImage(
        icon,
        pt(x + pad),
        pt(y0 + (bh - iconSize) / 2),
        pt(iconSize),
        pt(iconSize),
      );
    }

    const { value: valueFont, label: labelFont } = fontsFor(b.design, k);
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
        const rowY = b.metrics.length === 1 ? y0 + 7 * k : y0 + mi * 12 * k + 3 * k;
        ctx.textBaseline = "top";
        ctx.fillStyle = LABEL;
        ctx.font = labelFontPx;
        ctx.fillText(m.label, pt(cursor), pt(rowY));
        let valueX = cursor + labelColW + 5 * k;
        if ((b.design === "lanes" || b.design === "segments") && m.percent !== undefined) {
          const mw = 54 * k;
          const my = rowY + 4 * k;
          ctx.fillStyle = TRACK;
          roundRect(ctx, pt(valueX), pt(my), pt(mw), pt(4 * k), pt(2 * k));
          ctx.fill();
          const frac = Math.max(0, Math.min(1, m.percent / 100));
          if (frac > 0) {
            ctx.fillStyle = color;
            roundRect(ctx, pt(valueX), pt(my), pt(mw * frac), pt(4 * k), pt(2 * k));
            ctx.fill();
          }
          // Swift segments: ten slots, nine capsule-colored ticks so the bar reads as dashes.
          if (b.design === "segments") {
            ctx.fillStyle = PANEL;
            for (let n = 1; n < 10; n++) {
              ctx.fillRect(
                pt(valueX + (n * mw) / 10 - 0.7 * k),
                pt(my),
                Math.max(1, pt(1.4 * k)),
                pt(4 * k),
              );
            }
          }
          valueX += 60 * k;
        }
        ctx.fillStyle = color;
        ctx.font = valueFontPx;
        ctx.fillText(m.value, pt(valueX), pt(rowY - 1 * k));
        return;
      }

      if (b.design === "divider" && mi > 0) {
        ctx.fillStyle = TRACK;
        ctx.fillRect(pt(cursor - mGap / 2), pt(y0 + 8 * k), pt(1), pt(12 * k));
      }

      const labelW = measure(ctx, m.label, labelFontPx) / S;
      const valueW = measure(ctx, m.value, valueFontPx) / S;
      const rowInner =
        labelW + lvGap + valueW + (b.design === "rings" && m.percent !== undefined ? 21 * k : 0);

      if (b.design === "focus" && m.percent === minPct && minPct < 999) {
        ctx.fillStyle = rgb(m.color, 0.18);
        roundRect(ctx, pt(cursor - 3 * k), pt(y0 + 4 * k), pt(rowInner + 6 * k), pt(20 * k), pt(3 * k));
        ctx.fill();
        ctx.fillStyle = color;
        roundRect(ctx, pt(cursor - 3 * k), pt(y0 + 7 * k), pt(2 * k), pt(14 * k), pt(1 * k));
        ctx.fill();
        cursor += 3 * k;
      }

      if (b.design === "rings" && m.percent !== undefined) {
        const cx = pt(cursor + 8 * k);
        const cy = pt(y0 + bh / 2);
        ctx.strokeStyle = TRACK;
        ctx.lineWidth = 2.5 * k * S;
        ctx.beginPath();
        ctx.arc(cx, cy, 8 * k * S, 0, Math.PI * 2);
        ctx.stroke();
        const frac = Math.max(0, Math.min(1, m.percent / 100));
        if (frac > 0) {
          ctx.strokeStyle = color;
          ctx.lineCap = "round";
          ctx.beginPath();
          ctx.arc(cx, cy, 8 * k * S, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * frac);
          ctx.stroke();
        }
        cursor += 21 * k;
      }

      // Baseline text stays high so it meets the underline meter.
      // Divider, rings, and focus center the painted glyphs on the capsule midline.
      if (b.design === "baseline") {
        const rowY = y0 + 8 * k;
        ctx.textBaseline = "top";
        ctx.fillStyle = LABEL;
        ctx.font = labelFontPx;
        ctx.fillText(m.label, pt(cursor), pt(rowY - 1 * k));
        ctx.fillStyle = color;
        ctx.font = valueFontPx;
        ctx.fillText(m.value, pt(cursor + labelW + lvGap), pt(rowY - 2 * k));
      } else {
        const mid = pt(y0 + bh / 2);
        ctx.textBaseline = "alphabetic";
        ctx.fillStyle = LABEL;
        ctx.font = labelFontPx;
        ctx.fillText(m.label, pt(cursor), inkBaseline(ctx, m.label, mid));
        ctx.fillStyle = color;
        ctx.font = valueFontPx;
        ctx.fillText(m.value, pt(cursor + labelW + lvGap), inkBaseline(ctx, m.value, mid));
      }


      // Baseline is the underline meter. Divider stays text plus the vertical rule.
      if (b.design === "baseline" && m.percent !== undefined) {
        const my = y0 + 22 * k;
        const meterW = labelW + lvGap + valueW;
        ctx.fillStyle = TRACK;
        roundRect(ctx, pt(cursor), pt(my), pt(meterW), pt(4 * k), pt(2 * k));
        ctx.fill();
        const frac = Math.max(0, Math.min(1, m.percent / 100));
        if (frac > 0) {
          ctx.fillStyle = color;
          roundRect(ctx, pt(cursor), pt(my), pt(meterW * frac), pt(4 * k), pt(2 * k));
          ctx.fill();
        }
      }

      cursor += labelW + lvGap + valueW + mGap + (b.design === "focus" ? 5 * k : 0);
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
