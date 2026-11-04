/**
 * Render sample tray capsules to PNG for visual QA (no Electron required).
 * Usage: npx tsx scripts/preview-statusbar.mjs
 */
import { createCanvas, Image } from "@napi-rs/canvas";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  renderStatusBarPng,
  setArtworkRoot,
  warmStatusBarIcons,
} from "../electron/statusBarRender.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
process.chdir(root);
setArtworkRoot(join(root, "menubar", "Artwork"));

const outDir = join(root, "tmp-statusbar-preview");
mkdirSync(outDir, { recursive: true });

const basePrefs = {
  darkBarBackground: true,
  themedProviderLogos: false,
};

const samples = [
  {
    name: "stack-cursor-uneven",
    blocks: [
      {
        id: "cursor",
        design: "stack",
        stale: false,
        allowanceEmpty: false,
        metrics: [
          { label: "D", value: "$91", color: [255, 179, 176] },
          { label: "M", value: "$104", color: [199, 245, 199] },
        ],
      },
    ],
  },
  {
    name: "stack-cursor-even",
    blocks: [
      {
        id: "cursor",
        design: "stack",
        stale: false,
        allowanceEmpty: false,
        metrics: [
          { label: "D", value: "$24", color: [199, 245, 199] },
          { label: "M", value: "$59", color: [199, 245, 199] },
        ],
      },
    ],
  },
  {
    name: "stack-chatgpt-meters",
    blocks: [
      {
        id: "chatgpt",
        design: "stack",
        stale: false,
        allowanceEmpty: false,
        metrics: [
          { label: "5H", value: "100%", color: [48, 209, 88] },
          { label: "W", value: "40%", color: [255, 128, 0] },
        ],
      },
    ],
  },
  {
    name: "divider-claude",
    blocks: [
      {
        id: "claude",
        design: "divider",
        stale: false,
        allowanceEmpty: false,
        metrics: [
          { label: "D", value: "$12", color: [199, 245, 199] },
          { label: "M", value: "$84", color: [255, 250, 184] },
        ],
      },
    ],
  },
  {
    name: "divider-zero",
    blocks: [
      {
        id: "claude",
        design: "divider",
        stale: false,
        allowanceEmpty: false,
        metrics: [
          { label: "D", value: "$0.00", color: [199, 245, 199] },
          { label: "M", value: "$0.00", color: [199, 245, 199] },
        ],
      },
    ],
  },
];

await warmStatusBarIcons(["cursor", "chatgpt", "claude"], false);

function enlarge(png, factor = 4) {
  const img = new Image();
  img.src = png;
  // Image.src=Buffer doesn't paint — re-encode via canvas after loadImage path.
  return png; // placeholder replaced below
}

for (const sample of samples) {
  const { png, width, height } = renderStatusBarPng(sample.blocks, basePrefs);
  const file = join(outDir, `${sample.name}.png`);
  writeFileSync(file, png);

  // 4× nearest for visual inspection in chat
  const { loadImage } = await import("@napi-rs/canvas");
  const img = await loadImage(png);
  const big = createCanvas(img.width * 4, img.height * 4);
  const ctx = big.getContext("2d");
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(img, 0, 0, img.width * 4, img.height * 4);
  writeFileSync(join(outDir, `${sample.name}-4x.png`), big.toBuffer("image/png"));

  // icon presence check
  const c = createCanvas(img.width, img.height);
  const cctx = c.getContext("2d");
  cctx.drawImage(img, 0, 0);
  const d = cctx.getImageData(0, 0, Math.min(40, img.width), img.height).data;
  let bright = 0;
  for (let i = 0; i < d.length; i += 4) {
    if (d[i] > 100 && d[i + 3] > 100) bright++;
  }
  console.log(
    `${sample.name}: ${width}x${height}pt bright-left=${bright} → ${file}`,
  );
}

void enlarge;
