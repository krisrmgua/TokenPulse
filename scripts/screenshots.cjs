// Captures the production renderer with synthetic data; never starts the app backend.
const { app, BrowserWindow, ipcMain, session } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const fixture = require('./screenshots/fixture.cjs');
const root = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'readme-capture-'));
app.setPath('userData', temporary);
app.setAppPath(root);
app.commandLine.appendSwitch('force-device-scale-factor', '2');
app.commandLine.appendSwitch('lang', 'en-US');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
app.whenReady().then(async () => {
  // Only bundled local resources. No provider, broker, Git host, or localhost API calls.
  session.defaultSession.webRequest.onBeforeRequest((details, callback) => {
    callback({ cancel: !/^(file:|data:|devtools:)/.test(details.url) });
  });
  const output = path.join(root, 'docs/screenshots');
  fs.mkdirSync(output, { recursive: true });
  const errors = [];
  const preloadSource = fs.readFileSync(path.join(__dirname, 'screenshots/preload.cjs'), 'utf8');
  const fixtureRequire = "const fixture = require('./fixture.cjs');";
  if (!preloadSource.includes(fixtureRequire)) throw new Error('screenshot preload is missing the fixture import');
  const preloadPath = path.join(temporary, 'preload.cjs');
  fs.writeFileSync(preloadPath, preloadSource.replace(fixtureRequire, `const fixture = ${JSON.stringify(fixture)};`));
  const win = new BrowserWindow({ width: fixture.width, height: fixture.minHeight || 200,
    show: false, frame: false, useContentSize: true, backgroundColor: '#0e1929',
    webPreferences: { preload: preloadPath,
      contextIsolation: true, nodeIntegration: false, sandbox: true, backgroundThrottling: false } });
  ipcMain.on('capture:fit', (_event, width, height) => {
    win.setContentSize(Math.round(width || fixture.width),
      Math.max(fixture.minHeight || 140, Math.min(fixture.maxHeight || 760, Math.ceil(height))));
  });
  ipcMain.on('capture:error', (_event, message) => errors.push(message));
  win.webContents.on('console-message', (_event, level, message) => {
    if (level === 3 && !message.includes('Electron Security Warning')) errors.push(message);
  });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  await win.loadFile(path.join(root, 'dist/index.html'));
  await pause(500);
  const manifest = [];
  if (fs.existsSync(path.join(__dirname, 'screenshots/menu.cjs'))) {
    const menu = await require('./screenshots/menu.cjs')(root, output);
    const menuItems = Array.isArray(menu) ? menu : [menu];
    manifest.push(...menuItems);
    fs.writeFileSync(path.join(output,'menu-manifest.json'),JSON.stringify(menuItems,null,2)+'\n');
  }
  for (const shot of fixture.shots) {
    if (shot.patch) { win.webContents.send('capture:update', shot.patch); await pause(100); }
    if (shot.action) await win.webContents.executeJavaScript(shot.action);
    await pause(350);
    await win.webContents.executeJavaScript('document.fonts.ready');
    if (shot.expect) {
      const text = await win.webContents.executeJavaScript('document.body.innerText');
      if (!text.includes(shot.expect)) throw new Error(`${shot.name}: expected ${shot.expect}`);
    }
    if (shot.check && !await win.webContents.executeJavaScript(shot.check)) throw new Error(`${shot.name}: interaction assertion failed`);
    const png = await win.webContents.capturePage();
    if (png.isEmpty()) throw new Error(`Empty capture: ${shot.name}`);
    fs.writeFileSync(path.join(output, `${shot.name}.png`), png.toPNG());
    const text = await win.webContents.executeJavaScript('document.body.innerText');
    if (/krisrmgua|krsimmons|\/Users\/kris\b|kkube\//i.test(text)) throw new Error('Personal data in screenshot');
    manifest.push({ file: `${shot.name}.png`, caption: shot.caption, size: png.getSize() });
    console.log(`Captured ${shot.name}`);
  }
  if (errors.length) throw new Error(errors.join('\n'));
  fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  win.destroy();
  try { fs.rmSync(temporary, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }); }
  catch { console.warn('Temporary Chromium cache will be cleared by the OS.'); }
  app.quit();
}).catch(error => { console.error(error); app.exit(1); });
