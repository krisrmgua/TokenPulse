import fs from "node:fs";
import path from "node:path";
import { resourcePath } from "./paths";
import type { SourceId } from "./types";

/** Cyan mark on navy tile — matches Swift ProviderArtwork. */
export const ART_CYAN = "#58d2ec";
export const ART_NAVY = "#0e1929";

const MARK_CACHE = new Map<string, string>();

/** Sidebar / card icon size in the panel (CSS px). */
export const PANEL_ICON = 16;
export const CARD_ICON = 20;

/**
 * Inline SVG mark for a provider. Themed = cyan on navy rounded tile.
 * ChatGPT / Grok use simplified cutouts (no giant PNG decode on every paint).
 */
export function providerMarkSvg(
  id: SourceId,
  size: number,
  themed = true,
): string {
  const key = `${id}:${size}:${themed ? "t" : "p"}`;
  const hit = MARK_CACHE.get(key);
  if (hit) return hit;

  const inset = themed ? size * 0.22 : size * 0.12;
  const inner = size - inset * 2;
  const mark = glyphPaths(id, inset, inset, inner);
  const tile = themed
    ? `<rect width="${size}" height="${size}" rx="${size * 0.22}" fill="${ART_NAVY}"/>`
    : "";
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">${tile}${mark}</svg>`;
  MARK_CACHE.set(key, svg);
  return svg;
}

export function providerMarkDataUrl(id: SourceId, size: number, themed = true): string {
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(providerMarkSvg(id, size, themed))}`;
}

function glyphPaths(id: SourceId, x: number, y: number, s: number): string {
  const c = ART_CYAN;
  const cx = x + s / 2;
  const cy = y + s / 2;
  switch (id) {
    case "chatgpt": {
      // Hexagonal knot (simplified ChatGPT-style bloom)
      const r = s * 0.38;
      const pts: string[] = [];
      for (let i = 0; i < 6; i++) {
        const a = (Math.PI / 3) * i - Math.PI / 2;
        pts.push(`${cx + r * Math.cos(a)},${cy + r * Math.sin(a)}`);
      }
      return `<polygon points="${pts.join(" ")}" fill="none" stroke="${c}" stroke-width="${Math.max(1.2, s * 0.1)}" stroke-linejoin="round"/>
        <circle cx="${cx}" cy="${cy}" r="${s * 0.12}" fill="${c}"/>`;
    }
    case "cursor": {
      // Cube (isometric-ish)
      const u = s * 0.28;
      return `<path d="M ${cx} ${cy - u * 1.2} L ${cx + u} ${cy - u * 0.5} L ${cx + u} ${cy + u * 0.5} L ${cx} ${cy + u * 1.2} L ${cx - u} ${cy + u * 0.5} L ${cx - u} ${cy - u * 0.5} Z"
        fill="none" stroke="${c}" stroke-width="${Math.max(1.2, s * 0.1)}" stroke-linejoin="round"/>
        <path d="M ${cx - u} ${cy - u * 0.5} L ${cx} ${cy} L ${cx + u} ${cy - u * 0.5} M ${cx} ${cy} L ${cx} ${cy + u * 1.2}"
        fill="none" stroke="${c}" stroke-width="${Math.max(1, s * 0.08)}"/>`;
    }
    case "claude": {
      // Asterisk
      const r = s * 0.36;
      const arms = [0, 60, 120]
        .map((deg) => {
          const a = (deg * Math.PI) / 180;
          return `<line x1="${cx - r * Math.cos(a)}" y1="${cy - r * Math.sin(a)}" x2="${cx + r * Math.cos(a)}" y2="${cy + r * Math.sin(a)}" stroke="${c}" stroke-width="${Math.max(1.4, s * 0.12)}" stroke-linecap="round"/>`;
        })
        .join("");
      return arms;
    }
    case "openai": {
      // Soft brain / loops
      return `<circle cx="${cx}" cy="${cy}" r="${s * 0.34}" fill="none" stroke="${c}" stroke-width="${Math.max(1.2, s * 0.1)}"/>
        <path d="M ${cx - s * 0.22} ${cy} Q ${cx} ${cy - s * 0.28} ${cx + s * 0.22} ${cy} Q ${cx} ${cy + s * 0.28} ${cx - s * 0.22} ${cy}"
        fill="none" stroke="${c}" stroke-width="${Math.max(1, s * 0.08)}"/>`;
    }
    case "grokbot": {
      // Stylized X / spark
      const r = s * 0.32;
      return `<line x1="${cx - r}" y1="${cy - r}" x2="${cx + r}" y2="${cy + r}" stroke="${c}" stroke-width="${Math.max(1.5, s * 0.12)}" stroke-linecap="round"/>
        <line x1="${cx + r}" y1="${cy - r}" x2="${cx - r}" y2="${cy + r}" stroke="${c}" stroke-width="${Math.max(1.5, s * 0.12)}" stroke-linecap="round"/>
        <circle cx="${cx}" cy="${cy}" r="${s * 0.1}" fill="${c}"/>`;
    }
  }
}

/** Optional: load original Artwork PNGs if present (unused by tray SVG path). */
export function artworkPngPath(name: "chatgpt" | "grokbot"): string | null {
  const candidates = [
    resourcePath("assets", `icon-${name}.png`),
    path.join(resourcePath("menubar", "Artwork"), `icon-${name}.png`),
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}
