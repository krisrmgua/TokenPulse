const fs = require('node:fs');
const path = require('node:path');
const { createCanvas, loadImage } = require('@napi-rs/canvas');
async function board(rows, output) {
  const images = await Promise.all(rows.map(async row => ({ ...row, image: await loadImage(row.png) })));
  const width = Math.max(800, ...images.map(r => r.image.width + 48));
  const canvas = createCanvas(width, 64 + rows.length * 110);
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#182c40'; ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.fillStyle = '#e8eff8'; ctx.font = '500 24px sans-serif';
  ctx.fillText('Menu bar · sample data', 24, 38);
  for (let i = 0; i < images.length; i++) {
    const row = images[i], y = 78 + i * 110;
    ctx.fillStyle = '#a9bbce'; ctx.font = '18px sans-serif'; ctx.fillText(row.label, 24, y);
    ctx.drawImage(row.image, 24, y + 12);
  }
  const file = path.join(output, 'menu-bar.png');
  fs.writeFileSync(file, canvas.toBuffer('image/png'));
  return { file: 'menu-bar.png', caption: 'Actual menu-bar renderer with synthetic values, arranged on a presentation backdrop.', size: { width, height: canvas.height } };
}
module.exports = async (root, output) => {
  const renderer = require('../../dist-electron/statusBarRender.js');
  const { BAR_DESIGNS } = require('../../dist-electron/barDesign.js');
  renderer.setArtworkRoot(path.join(root, 'menubar/Artwork'));
  await renderer.warmStatusBarIcons(['chatgpt'], true);
  const rows = BAR_DESIGNS.map(design => ({ label: design.name,
    png: renderer.renderStatusBarPng([{ id: 'chatgpt', design: design.id,
      stale: false, allowanceEmpty: false, metrics: [
        { label: '5H', value: '78%', percent: 78, color: [117,224,179] },
        { label: 'W', value: '42%', percent: 42, color: [240,204,133] },
      ] }], { darkBarBackground: true, themedProviderLogos: true, menuBarScale: 100 }).png }));
  return board(rows, output);
};
