// Writes assets/icon.png (1024x1024) from the same rasterizer the tray uses.
// electron-builder converts it to .icns (macOS) and .ico (Windows) at pack time.
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const { renderMark } = require(path.join(root, "dist-electron", "iconRaster.js"));

const out = path.join(root, "assets");
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, "icon.png"), renderMark({ size: 1024, variant: "app" }));
console.log("Wrote assets/icon.png");
