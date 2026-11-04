import {
  app,
  BrowserWindow,
  Menu,
  Notification,
  Tray,
  ipcMain,
  nativeImage,
  screen,
  shell,
} from "electron";
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { Engine } from "./engine";
import { SpendLedger } from "./ledger";
import { OpenAIKeyStore } from "./openaiAdmin";
import { dataDir, ledgerPath, prefsPath, pricingCandidates } from "./paths";
import { PrefsStore } from "./prefs";
import { Pricing } from "./pricing";
import { createTrayIcon } from "./tray";
import { renderMark } from "./iconRaster";
import { providerIconMap } from "./providerArt";
import { blocksFromSources, createStatusBarImage } from "./statusBar";
import { startOfDay } from "./format";
import { fetchOpenAISpend } from "./sources/openai";
import { SourceError } from "./http";
import {
  SOURCE_IDS,
  type ActionResult,
  type AppState,
  type Prefs,
  type SourceId,
  type SourcePrefs,
} from "./types";

const execFileAsync = promisify(execFile);

const isDev = process.env.TOKENPULSE_DEV === "1";
const PANEL_WIDTH = 780;
const PANEL_MIN_HEIGHT = 460;
const PANEL_PAD = 2;
/** Windows truncates tray tooltips at 127 characters. */
const WIN_TOOLTIP_MAX = 127;

let tray: Tray | null = null;
let panel: BrowserWindow | null = null;
let engine: Engine;
let prefs: PrefsStore;
let keys: OpenAIKeyStore;
let timer: NodeJS.Timeout | undefined;
/** Keep alive — Electron GCs unreferenced Notification before the banner shows. */
let activeNotification: Notification | null = null;

/** App mark for banners — ad-hoc builds often omit the bundle icon otherwise. */
function notificationIcon(): Electron.NativeImage {
  const candidates = [
    path.join(process.resourcesPath, "Artwork", "TokenPulseMark.png"),
    path.join(process.resourcesPath, "icon.icns"),
    path.join(app.getAppPath(), "menubar", "Artwork", "TokenPulseMark.png"),
    path.join(app.getAppPath(), "menubar", "Artwork", "TokenPulse.icns"),
  ];
  for (const file of candidates) {
    if (!fs.existsSync(file)) continue;
    const img = nativeImage.createFromPath(file);
    if (!img.isEmpty()) return img;
  }
  return nativeImage.createFromBuffer(renderMark({ size: 128, variant: "app" }));
}

/** Swift menu-bar binary — its UNUserNotificationCenter path is what works on this Mac. */
function swiftNotificationBinary(): string | null {
  const home = os.homedir();
  const candidates = [
    path.join(home, "Applications", "TokenPulse-Swift.app", "Contents", "MacOS", "TokenPulse"),
    path.join(app.getAppPath(), "menubar", "TokenPulse-Swift.app", "Contents", "MacOS", "TokenPulse"),
    path.join(app.getAppPath(), "menubar", "TokenPulse.app", "Contents", "MacOS", "TokenPulse"),
  ];
  return candidates.find((file) => fs.existsSync(file)) ?? null;
}

async function sendViaSwiftPreview(): Promise<ActionResult | null> {
  const bin = swiftNotificationBinary();
  if (!bin) return null;
  try {
    const { stdout, stderr } = await execFileAsync(bin, ["--notification-preview"], {
      timeout: 12_000,
      encoding: "utf8",
    });
    if ((stdout || "").includes("queued") || (stdout || "").includes("preview")) {
      return { ok: true, message: "Test notification sent." };
    }
    if (stderr && /Enable TokenPulse notifications/i.test(stderr)) {
      return {
        ok: false,
        message:
          "Enable TokenPulse-Swift in System Settings → Notifications, then try again.",
      };
    }
    return { ok: true, message: "Test notification sent." };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (/Enable TokenPulse notifications/i.test(msg) || /exit code 2/i.test(msg)) {
      return {
        ok: false,
        message:
          "Enable TokenPulse-Swift in System Settings → Notifications, then try again.",
      };
    }
    return null;
  }
}

async function sendViaOsascript(body: string): Promise<boolean> {
  if (process.platform !== "darwin") return false;
  try {
    await execFileAsync(
      "osascript",
      [
        "-e",
        `display notification ${JSON.stringify(body)} with title "TokenPulse" subtitle "Notification preview"`,
      ],
      { timeout: 5000 },
    );
    return true;
  } catch {
    return false;
  }
}

function panelUrl(): string {
  if (isDev) return "http://127.0.0.1:5173";
  return `file://${path.join(app.getAppPath(), "dist", "index.html")}`;
}

function createPanel(): BrowserWindow {
  const win = new BrowserWindow({
    width: PANEL_WIDTH,
    height: PANEL_MIN_HEIGHT,
    show: false,
    frame: false,
    resizable: false,
    useContentSize: true,
    skipTaskbar: true,
    alwaysOnTop: true,
    fullscreenable: false,
    backgroundColor: "#0e1929",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  void win.loadURL(panelUrl());
  win.on("blur", () => {
    if (!isDev) win.hide();
  });
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith("https://")) void shell.openExternal(url);
    return { action: "deny" };
  });
  return win;
}

function anchorPoint(): Electron.Point {
  if (tray) {
    const b = tray.getBounds();
    if (b.width > 0) return { x: b.x, y: b.y };
  }
  return screen.getCursorScreenPoint();
}

function positionPanel(win: BrowserWindow): void {
  const anchor = anchorPoint();
  const trayBounds = tray?.getBounds() ?? { x: anchor.x, y: anchor.y, width: 0, height: 0 };
  const winBounds = win.getBounds();
  const wa = screen.getDisplayNearestPoint(anchor).workArea;
  let x = Math.round(trayBounds.x + trayBounds.width / 2 - winBounds.width / 2);
  const trayAtTop = trayBounds.y < wa.y + wa.height / 2;
  let y = trayAtTop
    ? Math.round(trayBounds.y + trayBounds.height + 4)
    : Math.round(trayBounds.y - winBounds.height - 4);
  x = Math.min(Math.max(x, wa.x + 8), wa.x + wa.width - winBounds.width - 8);
  y = Math.min(Math.max(y, wa.y + 8), wa.y + wa.height - winBounds.height - 8);
  win.setPosition(x, y, false);
}

function fitPanel(contentHeight: number): void {
  if (!panel) return;
  const wa = screen.getDisplayNearestPoint(anchorPoint()).workArea;
  const maxH = Math.floor(wa.height * 0.85);
  const height = Math.min(Math.max(Math.ceil(contentHeight) + PANEL_PAD, PANEL_MIN_HEIGHT), maxH);
  panel.setContentSize(PANEL_WIDTH, height);
  if (panel.isVisible()) positionPanel(panel);
}

function togglePanel(): void {
  if (!panel || panel.isDestroyed()) panel = createPanel();
  if (panel.isVisible()) {
    panel.hide();
    return;
  }
  positionPanel(panel);
  panel.show();
  panel.focus();
  panel.webContents.send("tp:opened");
  void engine.refresh(false);
}

function withIcons(st: AppState): AppState {
  return {
    ...st,
    icons: providerIconMap(64),
  };
}

async function updateTray(): Promise<void> {
  if (!tray) return;
  const st = engine.state();
  const blocks = blocksFromSources(st.sources, st.prefs);
  const { title, tooltip } = engine.trayText();
  try {
    const image =
      blocks.length > 0 ? await createStatusBarImage(blocks, st.prefs) : createTrayIcon();
    if (!image.isEmpty()) tray.setImage(image);
    else tray.setImage(createTrayIcon());
  } catch {
    tray.setImage(createTrayIcon());
  }
  if (process.platform === "darwin") {
    // Capsules carry the metrics; keep title empty so we don't double-paint.
    tray.setTitle("");
    tray.setToolTip(tooltip);
  } else {
    const compact = title ? `TokenPulse\n${title.split("  ").join("\n")}` : tooltip;
    tray.setToolTip(
      compact.length > WIN_TOOLTIP_MAX
        ? `${compact.slice(0, WIN_TOOLTIP_MAX - 1)}…`
        : compact,
    );
  }
}

function broadcast(): void {
  void updateTray();
  if (panel && !panel.isDestroyed()) panel.webContents.send("tp:changed");
}

function schedule(): void {
  if (timer) clearInterval(timer);
  const minutes = prefs.get().refreshMinutes;
  timer = setInterval(() => void engine.refresh(false), minutes * 60_000);
}

function isSourceId(v: unknown): v is SourceId {
  return typeof v === "string" && (SOURCE_IDS as string[]).includes(v);
}

async function testOpenAIKey(key: string): Promise<ActionResult> {
  try {
    await fetchOpenAISpend(key, undefined, new Date());
    return { ok: true, message: "Key saved and verified against the OpenAI Costs API." };
  } catch (err) {
    const message = err instanceof SourceError ? err.message : "OpenAI check failed.";
    if (err instanceof SourceError && err.kind === "auth") return { ok: false, message };
    return { ok: true, message: `Key saved, but the check did not finish: ${message}` };
  }
}

function wireIpc(): void {
  ipcMain.handle("tp:getState", () => withIcons(engine.state()));

  ipcMain.handle("tp:refresh", async () => {
    await engine.refresh(true);
    return withIcons(engine.state());
  });

  ipcMain.handle("tp:setSource", (_e, id: unknown, patch: Partial<SourcePrefs>): ActionResult => {
    if (!isSourceId(id) || typeof patch !== "object" || patch === null) {
      return { ok: false, message: "Unknown source." };
    }
    if (id === "openai" && patch.enabled === true && !keys.isConfigured()) {
      return { ok: false, message: "needs-key" };
    }
    const before = prefs.source(id);
    const after = prefs.setSource(id, patch).sources[id];
    if (before.account !== after.account || (after.enabled && !before.enabled)) {
      engine.clear(id);
    }
    if (patch.enabled === true && (id === "grokbot" || id === "cursor")) {
      engine.clear(id);
    }
    broadcast();
    void engine.refresh(false);
    return { ok: true };
  });

  ipcMain.handle("tp:setPrefs", (_e, patch: Partial<Prefs>): ActionResult => {
    if (typeof patch !== "object" || patch === null) return { ok: false };
    prefs.update({
      refreshMinutes: patch.refreshMinutes,
      cursorPersonalAllowanceUSD: patch.cursorPersonalAllowanceUSD,
      openAtLogin: patch.openAtLogin,
      darkBarBackground: patch.darkBarBackground,
      menuBarScale: patch.menuBarScale,
      spendColorsEnabled: patch.spendColorsEnabled,
      pastelBarColors: patch.pastelBarColors,
      sharedRingLetters: patch.sharedRingLetters,
      menuBarOrder: patch.menuBarOrder,
      rememberPanelPlace: patch.rememberPanelPlace,
      notificationsEnabled: patch.notificationsEnabled,
      allowanceAlertsEnabled: patch.allowanceAlertsEnabled,
      opusAlertsEnabled: patch.opusAlertsEnabled,
      notificationSounds: patch.notificationSounds,
      alertThresholds: patch.alertThresholds,
      disabledAlertThresholds: patch.disabledAlertThresholds,
    });
    if (typeof patch.openAtLogin === "boolean") {
      app.setLoginItemSettings({ openAtLogin: patch.openAtLogin });
    }
    if (typeof patch.refreshMinutes === "number") schedule();
    broadcast();
    return { ok: true };
  });

  ipcMain.handle("tp:resetPrefs", (): ActionResult => {
    prefs.reset();
    app.setLoginItemSettings({ openAtLogin: false });
    schedule();
    broadcast();
    void engine.refresh(false);
    return { ok: true };
  });

  ipcMain.handle("tp:saveOpenAIKey", async (_e, raw: unknown): Promise<ActionResult> => {
    if (typeof raw !== "string") return { ok: false, message: "Paste an Admin key." };
    const saved = keys.save(raw);
    if (!saved.ok) return { ok: false, message: saved.error };
    const check = await testOpenAIKey(raw.trim());
    if (!check.ok) {
      keys.delete();
      broadcast();
      return check;
    }
    prefs.setSource("openai", { enabled: true, showInTray: true });
    engine.clear("openai");
    broadcast();
    void engine.refresh(true);
    return check;
  });

  ipcMain.handle("tp:deleteOpenAIKey", (): ActionResult => {
    keys.delete();
    prefs.setSource("openai", { enabled: false });
    engine.clear("openai");
    broadcast();
    return { ok: true, message: "Admin key removed." };
  });

  ipcMain.handle("tp:setOpenAIBalance", (_e, usd: unknown): ActionResult => {
    if (usd === null) {
      prefs.update({ openAIBalance: undefined });
    } else if (typeof usd === "number" && Number.isFinite(usd) && usd >= 0) {
      prefs.update({
        openAIBalance: {
          enteredUSD: usd,
          dayStart: startOfDay().toISOString(),
          spendAlreadyReportedUSD: engine.openAITodaySpend(),
        },
      });
    } else {
      return { ok: false, message: "Enter a dollar amount." };
    }
    engine.clear("openai");
    broadcast();
    void engine.refresh(true);
    return { ok: true };
  });

  ipcMain.handle("tp:openDataDir", () => {
    void shell.openPath(dataDir());
  });

  ipcMain.handle("tp:openExternal", (_e, url: unknown) => {
    if (typeof url === "string" && url.startsWith("https://")) void shell.openExternal(url);
  });

  ipcMain.handle("tp:openNotificationSettings", () => {
    if (process.platform === "darwin") {
      void shell.openExternal(
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
      );
    } else if (process.platform === "win32") {
      void shell.openExternal("ms-settings:notifications");
    }
  });

  ipcMain.handle("tp:sendTestNotification", async (): Promise<ActionResult> => {
    const body =
      "Allowance alerts use this icon and include the provider, window and reset time.";

    // macOS suppresses banners for the frontmost app. Always drop the panel first.
    if (panel && !panel.isDestroyed() && panel.isVisible()) {
      panel.hide();
      await new Promise((r) => setTimeout(r, 200));
    }

    // 1) Swift UNUserNotificationCenter helper — proven to banner on this machine.
    const viaSwift = await sendViaSwiftPreview();
    if (viaSwift) return viaSwift;

    // 2) Electron Notification (needs permission for com.kris.tokenpulse).
    if (Notification.isSupported()) {
      const sound = prefs.get().notificationSounds;
      const icon = notificationIcon();
      const iconPath = path.join(os.tmpdir(), "tokenpulse-notification-icon.png");
      try {
        fs.writeFileSync(iconPath, icon.toPNG());
      } catch {
        /* NativeImage fallback below */
      }
      activeNotification = new Notification({
        title: "TokenPulse",
        subtitle: "Notification preview",
        body,
        silent: !sound,
        icon: fs.existsSync(iconPath) ? iconPath : icon,
      });
      const shown = await new Promise<boolean>((resolve) => {
        let settled = false;
        const done = (ok: boolean) => {
          if (settled) return;
          settled = true;
          resolve(ok);
        };
        activeNotification!.once("show", () => done(true));
        activeNotification!.show();
        setTimeout(() => done(false), 1200);
      });
      if (shown) return { ok: true, message: "Test notification sent." };
    }

    // 3) Last resort — visible, but no TokenPulse icon.
    if (await sendViaOsascript(body)) {
      return { ok: true, message: "Test notification sent." };
    }

    return {
      ok: false,
      message:
        "Could not show a notification. Enable TokenPulse in System Settings → Notifications, then try again.",
    };
  });

  ipcMain.handle("tp:hide", () => panel?.hide());

  ipcMain.handle("tp:fitHeight", (_e, height: unknown) => {
    if (typeof height === "number" && Number.isFinite(height)) fitPanel(height);
  });

  ipcMain.handle("tp:quit", () => app.quit());
}

function boot(): void {
  const dir = dataDir();
  prefs = new PrefsStore(prefsPath());
  keys = new OpenAIKeyStore(dir);
  const ledger = new SpendLedger(ledgerPath());
  const pricing = new Pricing(pricingCandidates());
  engine = new Engine(prefs, keys, ledger, pricing, {
    dataDir: dir,
    version: app.getVersion(),
    platform: process.platform,
  });
  engine.onChange(broadcast);

  if (process.platform === "darwin") app.dock?.hide();

  tray = new Tray(createTrayIcon());
  tray.setToolTip("TokenPulse");
  tray.on("click", () => togglePanel());
  tray.on("right-click", () => {
    const menu = Menu.buildFromTemplate([
      { label: "Open TokenPulse", click: () => togglePanel() },
      { label: "Refresh now", click: () => void engine.refresh(true) },
      { type: "separator" },
      { label: "Quit TokenPulse", click: () => app.quit() },
    ]);
    tray?.popUpContextMenu(menu);
  });

  wireIpc();
  panel = createPanel();
  schedule();
  void updateTray();
  void engine.refresh(true);
}

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.whenReady().then(boot);
  app.on("second-instance", () => togglePanel());
  app.on("before-quit", () => {
    if (timer) clearInterval(timer);
  });
  // Tray app: stay alive with no windows.
  app.on("window-all-closed", () => {});
}
