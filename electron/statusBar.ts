import { nativeImage } from "electron";
import { providerMarkDataUrl } from "./providerArt";
import { shortMoney } from "./format";
import type { SourceId, SourceSnapshot } from "./types";

/** Swift menu-bar provider order (left → right). */
export const TRAY_ORDER: SourceId[] = [
  "chatgpt",
  "cursor",
  "grokbot",
  "openai",
  "claude",
];

const PANEL = "rgba(19, 41, 59, 0.95)";
const EXHAUSTED = "rgba(77, 19, 20, 0.95)";
const TRACK = "rgb(59, 82, 99)";
const LABEL = "rgb(153, 173, 199)";
const INK = "rgb(237, 245, 255)";
const GREEN = "rgb(117, 224, 179)";
const AMBER = "rgb(240, 204, 133)";
const RED = "rgb(255, 143, 156)";

export interface StatusMetric {
  label: string;
  value: string;
  percent?: number;
  color: string;
}

export interface StatusBlock {
  id: SourceId;
  metrics: StatusMetric[];
  stale: boolean;
  allowanceEmpty: boolean;
  /** Spend-only → stack layout; otherwise divider. */
  stacked: boolean;
}

export function blocksFromSources(sources: SourceSnapshot[]): StatusBlock[] {
  const byId = new Map(sources.map((s) => [s.id, s]));
  const out: StatusBlock[] = [];
  for (const id of TRAY_ORDER) {
    const s = byId.get(id);
    if (!s || !s.enabled || !s.showInTray) continue;
    const metrics = metricsFor(s);
    if (metrics.length === 0) continue;
    out.push({
      id,
      metrics,
      stale: s.status === "stale",
      allowanceEmpty: metrics.some((m) => m.percent !== undefined && m.percent <= 0),
      stacked: isSpendOnly(s),
    });
  }
  return out;
}

function isSpendOnly(s: SourceSnapshot): boolean {
  if (s.id === "openai") return true;
  if (s.id === "grokbot") return false;
  return s.account === "work" && s.meters.length === 0;
}

function metricsFor(s: SourceSnapshot): StatusMetric[] {
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
        color: tintRemaining(pct),
      };
    });
  }

  const metrics: StatusMetric[] = [];
  if (s.id === "openai") {
    const balLine = s.lines.find((l) => /balance/i.test(l.label));
    if (balLine) {
      metrics.push({ label: "B", value: balLine.value, color: INK });
    } else if (s.monthUSD !== undefined) {
      // No prepaid baseline — still show D/M spend.
    }
  }
  if (s.todayUSD !== undefined || s.monthUSD !== undefined) {
    if (s.todayUSD !== undefined) {
      metrics.push({
        label: "D",
        value: shortMoney(s.todayUSD),
        color: INK,
      });
    }
    if (s.monthUSD !== undefined) {
      metrics.push({
        label: "M",
        value: shortMoney(s.monthUSD),
        color: INK,
      });
    }
  }
  return metrics;
}

function tintRemaining(pct: number): string {
  if (pct <= 10) return RED;
  if (pct <= 25) return AMBER;
  if (pct <= 50) return AMBER;
  return GREEN;
}

/** Approximate text width for SF Pro / Segoe semibold at given size. */
function textWidth(s: string, fontSize: number): number {
  let w = 0;
  for (const ch of s) {
    if (ch === "." || ch === "," || ch === " ") w += fontSize * 0.35;
    else if (ch === "$" || ch === "%") w += fontSize * 0.62;
    else if (ch >= "0" && ch <= "9") w += fontSize * 0.62;
    else if (ch === "—" || ch === "…") w += fontSize * 0.7;
    else w += fontSize * 0.58;
  }
  return Math.ceil(w);
}

function escapeXml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/**
 * Compose menu-bar capsules as one Retina PNG (via SVG → nativeImage).
 * Matches Swift Divider / Compact stack chrome (height 22–24, radius 6).
 */
export function createStatusBarImage(blocks: StatusBlock[]): Electron.NativeImage {
  if (blocks.length === 0) {
    return emptyMark();
  }

  const scale = 2;
  const iconSize = 14;
  const gap = 5;
  const heights = blocks.map((b) => (b.stacked ? 24 : 22));
  const height = Math.max(...heights);

  const widths = blocks.map((b) => {
    const valueFont = b.stacked ? 11 : 12;
    const labelFont = b.stacked ? 10 : 11;
    let content: number;
    if (b.stacked) {
      const labels = Math.max(...b.metrics.map((m) => textWidth(m.label, labelFont)), 0);
      const values = Math.max(...b.metrics.map((m) => textWidth(m.value, valueFont)), 0);
      content = labels + 5 + values;
    } else {
      content =
        b.metrics.reduce((sum, m, i) => {
          const row =
            textWidth(m.label, labelFont) + 4 + textWidth(m.value, valueFont);
          return sum + row + (i > 0 ? 13 : 0);
        }, 0) || 8;
    }
    return 7 + iconSize + 7 + content + 7;
  });
  const total = widths.reduce((a, b) => a + b, 0) + gap * Math.max(0, blocks.length - 1);

  const parts: string[] = [];
  let x = 0;
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i];
    const bw = widths[i];
    const bh = heights[i];
    const y0 = (height - bh) / 2;
    const fill = b.allowanceEmpty ? EXHAUSTED : PANEL;
    const opacity = b.stale ? 0.45 : 1;
    parts.push(
      `<g opacity="${opacity}"><rect x="${x}" y="${y0}" width="${bw}" height="${bh}" rx="6" fill="${fill}"/>`,
    );
    const markHref = providerMarkDataUrl(b.id, 28, true);
    parts.push(
      `<image href="${markHref}" x="${x + 7}" y="${y0 + (bh - iconSize) / 2}" width="${iconSize}" height="${iconSize}"/>`,
    );

    const valueFont = b.stacked ? 11 : 12;
    const labelFont = b.stacked ? 10 : 11;
    let cursor = x + 7 + iconSize + 7;
    const labels = Math.max(...b.metrics.map((m) => textWidth(m.label, labelFont)), 0);
    const values = Math.max(...b.metrics.map((m) => textWidth(m.value, valueFont)), 0);

    b.metrics.forEach((m, mi) => {
      if (b.stacked) {
        const rowY = y0 + (b.metrics.length === 1 ? 15 : mi * 11 + 10);
        parts.push(
          `<text x="${cursor}" y="${rowY}" font-family="-apple-system, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif" font-size="${labelFont}" font-weight="600" fill="${LABEL}">${escapeXml(m.label)}</text>`,
        );
        const vx = cursor + labels + 5 + values - textWidth(m.value, valueFont);
        parts.push(
          `<text x="${vx}" y="${rowY}" font-family="ui-monospace, 'SF Mono', Menlo, Consolas, monospace" font-size="${valueFont}" font-weight="600" fill="${m.color}">${escapeXml(m.value)}</text>`,
        );
        return;
      }
      if (mi > 0) {
        parts.push(
          `<rect x="${cursor - 7}" y="${y0 + 5}" width="1" height="12" fill="${TRACK}"/>`,
        );
      }
      const rowY = y0 + 15;
      parts.push(
        `<text x="${cursor}" y="${rowY}" font-family="-apple-system, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif" font-size="${labelFont}" font-weight="600" fill="${LABEL}">${escapeXml(m.label)}</text>`,
      );
      const vx = cursor + textWidth(m.label, labelFont) + 4;
      parts.push(
        `<text x="${vx}" y="${rowY}" font-family="ui-monospace, 'SF Mono', Menlo, Consolas, monospace" font-size="${valueFont}" font-weight="600" fill="${m.color}">${escapeXml(m.value)}</text>`,
      );
      if (m.percent !== undefined) {
        const meterW = textWidth(m.label, labelFont) + 4 + textWidth(m.value, valueFont);
        // thin under-bar for visual parity with baseline feel on divider
        const frac = Math.max(0, Math.min(1, m.percent / 100));
        parts.push(
          `<rect x="${cursor}" y="${y0 + bh - 5}" width="${meterW}" height="2" rx="1" fill="${TRACK}"/>`,
        );
        if (frac > 0) {
          parts.push(
            `<rect x="${cursor}" y="${y0 + bh - 5}" width="${meterW * frac}" height="2" rx="1" fill="${m.color}"/>`,
          );
        }
      }
      cursor +=
        textWidth(m.label, labelFont) + 4 + textWidth(m.value, valueFont) + 13;
    });
    parts.push(`</g>`);
    x += bw + gap;
  }

  const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${total * scale}" height="${height * scale}" viewBox="0 0 ${total} ${height}">
${parts.join("\n")}
</svg>`;

  const img = nativeImage.createFromDataURL(
    `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`,
  );
  if (img.isEmpty()) return emptyMark();
  // Logical size for the menu bar
  const sized = img.resize({ width: Math.round(total), height: Math.round(height), quality: "best" });
  return sized;
}

function emptyMark(): Electron.NativeImage {
  const size = 18;
  const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${size * 2}" height="${size * 2}" viewBox="0 0 ${size} ${size}">
  <circle cx="9" cy="9" r="7" fill="none" stroke="#58d2ec" stroke-width="1.6"/>
  <polyline points="4,9 7,9 8.2,6.2 10.5,12.2 12,9 14.5,9" fill="none" stroke="#58d2ec" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`;
  const img = nativeImage.createFromDataURL(
    `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`,
  );
  return img.isEmpty() ? nativeImage.createEmpty() : img.resize({ width: size, height: size });
}
