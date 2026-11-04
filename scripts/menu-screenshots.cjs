// Isolated documentation entry point: no real app backend, accounts or polling.
const { app, session } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = path.resolve(__dirname,'..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(),'menu-docs-'));
app.setAppPath(root);
app.setPath('userData',temporary);
app.commandLine.appendSwitch('force-device-scale-factor','2');
app.on('window-all-closed',() => {});
app.whenReady().then(async () => {
  session.defaultSession.webRequest.onBeforeRequest((details,callback) => callback({cancel: !/^(file:|data:|devtools:)/.test(details.url)}));
  const output = path.join(root,'docs/screenshots');
  fs.mkdirSync(output,{recursive:true});
  const result = await require('./screenshots/menu.cjs')(root,output);
  const items = Array.isArray(result) ? result : [result];
  fs.writeFileSync(path.join(output,'menu-manifest.json'),JSON.stringify(items,null,2)+'\n');
  const manifestPath = path.join(output,'manifest.json');
  const previous = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath,'utf8')) : [];
  fs.writeFileSync(manifestPath,JSON.stringify([...items,...previous.filter(item => !item.file.startsWith('menu-bar'))],null,2)+'\n');
  for (const item of items) console.log(`${item.file}: ${item.size.width} × ${item.size.height}`);
  app.quit();
}).catch(error => {console.error(error);app.exit(1)});
app.on('quit',() => { try { fs.rmSync(temporary,{recursive:true,force:true,maxRetries:3,retryDelay:100}); } catch {} });
