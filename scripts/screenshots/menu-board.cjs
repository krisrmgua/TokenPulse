// Presentation chrome only. Every icon/capsule PNG comes from production drawing code.
const { BrowserWindow, nativeImage } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const escape = text => String(text).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
module.exports = async function board(output, file, title, rows, caption) {
  const images = rows.map(row => ({ ...row, items: (Array.isArray(row.png) ? row.png : [row.png]).map(png => {
    const image = nativeImage.createFromBuffer(png);
    if (image.isEmpty()) throw new Error(`Missing menu artwork: ${row.label}`);
    return { url: image.toDataURL(), width: image.getSize().width, height: image.getSize().height };
  }) }));
  const width = Math.ceil(Math.max(540, ...images.map(row => row.items.reduce((n, image) => n + image.width + 12, 0) + 80)));
  const rowHeight = Math.max(96,...images.map(row => Math.max(...row.items.map(image => image.height)) + 50));
  const height = 76 + rowHeight * rows.length;
  const html = `<!doctype html><meta charset="utf-8"><style>
    *{box-sizing:border-box}body{margin:0;padding:24px;background:#182c40;color:#e8eff8;font:14px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
    h1{font-size:20px;margin:0 0 26px;font-weight:600}.sample{height:${rowHeight}px}.label{font-size:13px;color:#b6c6da;margin-bottom:12px}.strip{display:flex;align-items:center;gap:12px;min-height:34px}img{display:block;flex-shrink:0}
    </style><h1>${escape(title)}</h1>` + images.map(row => `<section class="sample"><div class="label">${escape(row.label)}</div><div class="strip" style="background:${escape(row.background || "#182c40")};border-radius:6px;padding:0 8px">${row.items.map(image => `<img src="${image.url}" style="width:${image.width}px;height:${image.height}px" alt="">`).join('')}</div></section>`).join('');
  const win = new BrowserWindow({ width, height, show:false, frame:false, useContentSize:true,
    webPreferences:{ nodeIntegration:false, contextIsolation:true, backgroundThrottling:false } });
  try {
    await win.loadURL('data:text/html;charset=utf-8,'+encodeURIComponent(html));
    await win.webContents.executeJavaScript('document.fonts.ready.then(() => Promise.all(Array.from(document.images, i => i.decode())))');
    const png = await win.webContents.capturePage();
    if (png.isEmpty()) throw new Error('Empty menu-bar board');
    fs.writeFileSync(path.join(output,file),png.toPNG());
    return { file, caption, size:png.getSize() };
  } catch(error) { throw new Error(`Cannot capture ${file}: ${error.code || error.name}`); } finally { win.destroy(); }
};
