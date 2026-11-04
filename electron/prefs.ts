import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { BAR_DESIGNS, resolveBarDesign, type BarDesign } from "./barDesign";
import { restrictFile } from "./fsSecure";
import {
  REFRESH_CHOICES,
  SOURCE_ACCOUNTS,
  PROVIDER_ORDER,
  SOURCE_IDS,
  menuBarScaleFromRaw,
  type OpenAIBalanceBaseline,
  type Prefs,
  type SourceId,
  type SourcePrefs,
} from "./types";

const BAR_IDS = new Set(BAR_DESIGNS.map((d) => d.id));
const PROVIDER_SET = new Set<string>(PROVIDER_ORDER);

/** Keep a saved order, drop unknown ids, and append any provider that was left out. */
export function menuBarOrderFromRaw(raw: unknown): SourceId[] {
  const seen = new Set<SourceId>();
  const out: SourceId[] = [];
  if (Array.isArray(raw)) {
    for (const id of raw) {
      if (typeof id !== "string" || !PROVIDER_SET.has(id) || seen.has(id as SourceId)) continue;
      seen.add(id as SourceId);
      out.push(id as SourceId);
    }
  }
  for (const id of PROVIDER_ORDER) {
    if (!seen.has(id)) out.push(id);
  }
  return out;
}

function defaultSource(id: SourceId): SourcePrefs {
  const accounts = SOURCE_ACCOUNTS[id];
  return {
    enabled: false,
    showInTray: false,
    account: accounts.includes("personal") ? "personal" : accounts[0],
    sharedPill: false,
    barDesign: "divider",
    showDailyInBar: true,
    showMonthlyInBar: true,
    showBalanceInBar: true,
  };
}

/** Fresh install: every provider off, and personal when that source has a personal mode. */
export function defaultPrefs(): Prefs {
  return {
    version: 1,
    sources: {
      claude: defaultSource("claude"),
      cursor: defaultSource("cursor"),
      chatgpt: defaultSource("chatgpt"),
      openai: defaultSource("openai"),
      grokbot: defaultSource("grokbot"),
    },
    refreshMinutes: 1,
    cursorPersonalAllowanceUSD: 20,
    openAtLogin: false,
    themedProviderLogos: false,
    darkBarBackground: true,
    menuBarScale: 100,
    spendColorsEnabled: true,
    pastelBarColors: true,
    sharedRingLetters: false,
    menuBarOrder: [...PROVIDER_ORDER],
    rememberPanelPlace: false,
    notificationsEnabled: true,
    allowanceAlertsEnabled: true,
    opusAlertsEnabled: true,
    notificationSounds: false,
    alertThresholds: [15, 10, 5],
    disabledAlertThresholds: [],
  };
}

/** Swift AllowanceAlertLedger.parseThresholds — 1–10 ints in 1…99, unique, high→low. */
export function parseAlertThresholds(text: string): number[] | null {
  const parts = text
    .replaceAll("%", "")
    .split(/[,;\s]+/)
    .map((p) => p.trim())
    .filter(Boolean);
  if (parts.length === 0 || parts.length > 10) return null;
  const values: number[] = [];
  for (const p of parts) {
    if (!/^\d+$/.test(p)) return null;
    const n = Number(p);
    if (!Number.isInteger(n) || n < 1 || n > 99) return null;
    values.push(n);
  }
  return [...new Set(values)].sort((a, b) => b - a);
}

function normalizeThresholds(raw: unknown, fallback: number[]): number[] {
  if (!Array.isArray(raw)) return [...fallback];
  const parsed = parseAlertThresholds(raw.map(String).join(","));
  return parsed ?? [...fallback];
}

function normalizeDisabled(raw: unknown, thresholds: number[]): number[] {
  if (!Array.isArray(raw)) return [];
  const set = new Set(thresholds);
  return [
    ...new Set(
      raw.filter((n): n is number => typeof n === "number" && set.has(n)),
    ),
  ];
}

function parseBarDesign(raw: unknown, spendOnly: boolean): BarDesign {
  const id = typeof raw === "string" && BAR_IDS.has(raw as BarDesign) ? (raw as BarDesign) : "divider";
  return resolveBarDesign(id, spendOnly);
}

function spendOnlyFor(id: SourceId, account: SourcePrefs["account"]): boolean {
  if (id === "openai") return true;
  if (id === "grokbot") return false;
  return account === "work";
}

function normalizeSource(id: SourceId, s: Partial<SourcePrefs> | undefined, base: SourcePrefs): SourcePrefs {
  const account =
    s?.account && SOURCE_ACCOUNTS[id].includes(s.account) ? s.account : base.account;
  const spendOnly = spendOnlyFor(id, account);
  return {
    enabled: typeof s?.enabled === "boolean" ? s.enabled : base.enabled,
    showInTray: typeof s?.showInTray === "boolean" ? s.showInTray : base.showInTray,
    account,
    sharedPill: typeof s?.sharedPill === "boolean" ? s.sharedPill : false,
    barDesign: parseBarDesign(s?.barDesign, spendOnly),
    showDailyInBar: typeof s?.showDailyInBar === "boolean" ? s.showDailyInBar : base.showDailyInBar,
    showMonthlyInBar:
      typeof s?.showMonthlyInBar === "boolean" ? s.showMonthlyInBar : base.showMonthlyInBar,
    showBalanceInBar:
      typeof s?.showBalanceInBar === "boolean" ? s.showBalanceInBar : base.showBalanceInBar,
  };
}

/** Pull a few display prefs from the Swift app's UserDefaults when Electron prefs are fresh. */
function readSwiftDefaults(): Partial<Prefs> {
  if (process.platform !== "darwin") return {};
  try {
    const raw = execFileSync("defaults", ["read", "com.kris.tokenpulse"], {
      encoding: "utf8",
      timeout: 2000,
    });
    const out: Partial<Prefs> = {};
    if (/themedProviderLogos\s*=\s*1/.test(raw)) out.themedProviderLogos = true;
    if (/themedProviderLogos\s*=\s*0/.test(raw)) out.themedProviderLogos = false;
    if (/darkMenuBarBackground\s*=\s*1/.test(raw)) out.darkBarBackground = true;
    if (/darkMenuBarBackground\s*=\s*0/.test(raw)) out.darkBarBackground = false;
    if (/spendColorsEnabled\s*=\s*1/.test(raw)) out.spendColorsEnabled = true;
    if (/spendColorsEnabled\s*=\s*0/.test(raw)) out.spendColorsEnabled = false;
    if (/pastelMenuBarColors\s*=\s*1/.test(raw)) out.pastelBarColors = true;
    if (/pastelMenuBarColors\s*=\s*0/.test(raw)) out.pastelBarColors = false;
    if (/rememberPanelPlace\s*=\s*1/.test(raw)) out.rememberPanelPlace = true;
    if (/rememberPanelPlace\s*=\s*0/.test(raw)) out.rememberPanelPlace = false;
    const design = raw.match(/statusBarDesign\s*=\s*([a-z]+)/);
    if (design && BAR_IDS.has(design[1] as BarDesign)) {
      // Applied per-source below when sources lack an explicit design.
      (out as Prefs & { _legacyDesign?: BarDesign })._legacyDesign = design[1] as BarDesign;
    }
    const cursorDesign = raw.match(/"statusBarDesign\.cursor"\s*=\s*([a-z]+)/);
    if (cursorDesign && BAR_IDS.has(cursorDesign[1] as BarDesign)) {
      (out as Prefs & { _cursorDesign?: BarDesign })._cursorDesign = cursorDesign[1] as BarDesign;
    }
    return out;
  } catch {
    return {};
  }
}

/** Swift `OpenAIBalancePrefs` keys in a `defaults read` dump. */
export function parseSwiftOpenAIBalance(raw: string): OpenAIBalanceBaseline | undefined {
  const balance = raw.match(/openAIEstimatedBalanceBaselineUSD\s*=\s*"?(-?\d+(?:\.\d+)?)"?/);
  const spent = raw.match(/openAIEstimatedBalanceDaySpendUSD\s*=\s*"?(-?\d+(?:\.\d+)?)"?/);
  const day = raw.match(
    /openAIEstimatedBalanceDayStart\s*=\s*"?(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})"?/,
  );
  if (!balance || !spent || !day) return undefined;
  const enteredUSD = Number(balance[1]);
  const spendAlreadyReportedUSD = Number(spent[1]);
  const stamp = day[1].replace(" ", "T").replace(/ ([+-]\d{2})(\d{2})$/, "$1:$2");
  const dayStart = new Date(stamp);
  if (!Number.isFinite(enteredUSD) || !Number.isFinite(spendAlreadyReportedUSD)) return undefined;
  if (Number.isNaN(dayStart.getTime())) return undefined;
  return { enteredUSD, dayStart: dayStart.toISOString(), spendAlreadyReportedUSD };
}

function readSwiftOpenAIBalance(): OpenAIBalanceBaseline | undefined {
  if (process.platform !== "darwin") return undefined;
  try {
    const raw = execFileSync("defaults", ["read", "com.kris.tokenpulse"], {
      encoding: "utf8",
      timeout: 2000,
    });
    return parseSwiftOpenAIBalance(raw);
  } catch {
    return undefined;
  }
}

export class PrefsStore {
  private data: Prefs;
  private readonly file: string;
  private writeAfterLoad = false;

  constructor(file: string) {
    this.file = file;
    this.data = this.load();
    if (this.writeAfterLoad) this.persist();
  }

  get(): Prefs {
    return structuredClone(this.data);
  }

  source(id: SourceId): SourcePrefs {
    return { ...this.data.sources[id] };
  }

  setSource(id: SourceId, patch: Partial<SourcePrefs>): Prefs {
    const current = this.data.sources[id];
    const next: SourcePrefs = { ...current };
    if (typeof patch.enabled === "boolean") next.enabled = patch.enabled;
    if (typeof patch.showInTray === "boolean") next.showInTray = patch.showInTray;
    if (patch.account && SOURCE_ACCOUNTS[id].includes(patch.account)) {
      next.account = patch.account;
    }
    if (typeof patch.showDailyInBar === "boolean") next.showDailyInBar = patch.showDailyInBar;
    if (typeof patch.showMonthlyInBar === "boolean") next.showMonthlyInBar = patch.showMonthlyInBar;
    if (typeof patch.showBalanceInBar === "boolean") next.showBalanceInBar = patch.showBalanceInBar;
    if (typeof patch.sharedPill === "boolean") next.sharedPill = patch.sharedPill;
    if (patch.barDesign) {
      next.barDesign = parseBarDesign(patch.barDesign, spendOnlyFor(id, next.account));
    } else {
      next.barDesign = resolveBarDesign(next.barDesign, spendOnlyFor(id, next.account));
    }
    this.data.sources[id] = next;
    this.persist();
    return this.get();
  }

  update(patch: Partial<Omit<Prefs, "version" | "sources">>): Prefs {
    if (
      typeof patch.refreshMinutes === "number" &&
      REFRESH_CHOICES.includes(patch.refreshMinutes)
    ) {
      this.data.refreshMinutes = patch.refreshMinutes;
    }
    if (
      typeof patch.cursorPersonalAllowanceUSD === "number" &&
      Number.isFinite(patch.cursorPersonalAllowanceUSD) &&
      patch.cursorPersonalAllowanceUSD > 0
    ) {
      this.data.cursorPersonalAllowanceUSD = patch.cursorPersonalAllowanceUSD;
    }
    if (typeof patch.openAtLogin === "boolean") {
      this.data.openAtLogin = patch.openAtLogin;
    }
    if ("openAIBalance" in patch) {
      this.data.openAIBalance = patch.openAIBalance
        ? { ...patch.openAIBalance }
        : undefined;
      this.data.openAIBalanceMigrated = true;
    }
    if (typeof patch.darkBarBackground === "boolean") {
      this.data.darkBarBackground = patch.darkBarBackground;
    }
    if (typeof patch.menuBarScale === "number") {
      this.data.menuBarScale = menuBarScaleFromRaw(patch.menuBarScale, false);
    }
    if (typeof patch.spendColorsEnabled === "boolean") {
      this.data.spendColorsEnabled = patch.spendColorsEnabled;
    }
    if (typeof patch.pastelBarColors === "boolean") {
      this.data.pastelBarColors = patch.pastelBarColors;
    }
    if (typeof patch.sharedRingLetters === "boolean") {
      this.data.sharedRingLetters = patch.sharedRingLetters;
    }
    if (Array.isArray(patch.menuBarOrder)) {
      this.data.menuBarOrder = menuBarOrderFromRaw(patch.menuBarOrder);
    }
    if (typeof patch.rememberPanelPlace === "boolean") {
      this.data.rememberPanelPlace = patch.rememberPanelPlace;
    }
    if (typeof patch.notificationsEnabled === "boolean") {
      this.data.notificationsEnabled = patch.notificationsEnabled;
    }
    if (typeof patch.allowanceAlertsEnabled === "boolean") {
      this.data.allowanceAlertsEnabled = patch.allowanceAlertsEnabled;
    }
    if (typeof patch.opusAlertsEnabled === "boolean") {
      this.data.opusAlertsEnabled = patch.opusAlertsEnabled;
    }
    if (typeof patch.notificationSounds === "boolean") {
      this.data.notificationSounds = patch.notificationSounds;
    }
    if (Array.isArray(patch.alertThresholds)) {
      const parsed = parseAlertThresholds(patch.alertThresholds.map(String).join(","));
      if (parsed) {
        this.data.alertThresholds = parsed;
        this.data.disabledAlertThresholds = [];
      }
    }
    if (Array.isArray(patch.disabledAlertThresholds)) {
      this.data.disabledAlertThresholds = normalizeDisabled(
        patch.disabledAlertThresholds,
        this.data.alertThresholds,
      );
    }
    this.persist();
    return this.get();
  }

  /** Clears layout and visibility choices. Saved API keys are kept. */
  reset(): Prefs {
    const keepBalance = this.data.openAIBalance;
    this.data = defaultPrefs();
    this.data.openAIBalance = keepBalance;
    this.persist();
    return this.get();
  }

  private load(): Prefs {
    const base = defaultPrefs();
    let raw: Partial<Prefs> | null = null;
    try {
      raw = JSON.parse(fs.readFileSync(this.file, "utf8")) as Partial<Prefs>;
    } catch {
      raw = null;
    }

    if (!raw || raw.version !== 1) {
      const swift = readSwiftDefaults() as Partial<Prefs> & {
        _legacyDesign?: BarDesign;
        _cursorDesign?: BarDesign;
      };
      Object.assign(base, {
        darkBarBackground: swift.darkBarBackground ?? base.darkBarBackground,
        spendColorsEnabled: swift.spendColorsEnabled ?? base.spendColorsEnabled,
        pastelBarColors: swift.pastelBarColors ?? base.pastelBarColors,
        rememberPanelPlace: swift.rememberPanelPlace ?? base.rememberPanelPlace,
      });
      if (swift._legacyDesign) {
        for (const id of SOURCE_IDS) {
          base.sources[id].barDesign = resolveBarDesign(
            swift._legacyDesign,
            spendOnlyFor(id, base.sources[id].account),
          );
        }
      }
      if (swift._cursorDesign) {
        base.sources.cursor.barDesign = resolveBarDesign(
          swift._cursorDesign,
          spendOnlyFor("cursor", base.sources.cursor.account),
        );
      }
      this.adoptSwiftBalance(base);
      this.data = base;
      this.persist();
      this.writeAfterLoad = false;
      return this.get();
    }

    for (const id of SOURCE_IDS) {
      base.sources[id] = normalizeSource(id, raw.sources?.[id], base.sources[id]);
    }
    if (typeof raw.refreshMinutes === "number" && REFRESH_CHOICES.includes(raw.refreshMinutes)) {
      base.refreshMinutes = raw.refreshMinutes;
    }
    if (
      typeof raw.cursorPersonalAllowanceUSD === "number" &&
      raw.cursorPersonalAllowanceUSD > 0
    ) {
      base.cursorPersonalAllowanceUSD = raw.cursorPersonalAllowanceUSD;
    }
    if (typeof raw.openAtLogin === "boolean") base.openAtLogin = raw.openAtLogin;
    if (raw.themedProviderLogos === true) this.writeAfterLoad = true;
    if (typeof raw.darkBarBackground === "boolean") base.darkBarBackground = raw.darkBarBackground;
    base.menuBarScale = menuBarScaleFromRaw(
      raw.menuBarScale,
      (raw as { compactMenuBar?: boolean }).compactMenuBar,
    );
    if (typeof raw.spendColorsEnabled === "boolean") {
      base.spendColorsEnabled = raw.spendColorsEnabled;
    }
    if (typeof raw.pastelBarColors === "boolean") base.pastelBarColors = raw.pastelBarColors;
    if (typeof raw.sharedRingLetters === "boolean") base.sharedRingLetters = raw.sharedRingLetters;
    base.menuBarOrder = menuBarOrderFromRaw(raw.menuBarOrder);
    if (typeof raw.rememberPanelPlace === "boolean") {
      base.rememberPanelPlace = raw.rememberPanelPlace;
    } else {
      // Tray used to force pastel; keep that until the user flips the new toggle.
      base.pastelBarColors = true;
      base.rememberPanelPlace = false;
    }
    if (typeof raw.notificationsEnabled === "boolean") {
      base.notificationsEnabled = raw.notificationsEnabled;
    }
    if (typeof raw.allowanceAlertsEnabled === "boolean") {
      base.allowanceAlertsEnabled = raw.allowanceAlertsEnabled;
    }
    if (typeof raw.opusAlertsEnabled === "boolean") {
      base.opusAlertsEnabled = raw.opusAlertsEnabled;
    }
    if (typeof raw.notificationSounds === "boolean") {
      base.notificationSounds = raw.notificationSounds;
    }
    base.alertThresholds = normalizeThresholds(raw.alertThresholds, base.alertThresholds);
    base.disabledAlertThresholds = normalizeDisabled(
      raw.disabledAlertThresholds,
      base.alertThresholds,
    );

    // Existing Electron prefs without display keys → seed from Swift once.
    if (
      raw.themedProviderLogos === undefined &&
      raw.darkBarBackground === undefined &&
      raw.sources?.cursor?.barDesign === undefined
    ) {
      const swift = readSwiftDefaults() as Partial<Prefs> & {
        _legacyDesign?: BarDesign;
        _cursorDesign?: BarDesign;
      };
      if (typeof swift.darkBarBackground === "boolean") {
        base.darkBarBackground = swift.darkBarBackground;
      }
      if (typeof swift.spendColorsEnabled === "boolean") {
        base.spendColorsEnabled = swift.spendColorsEnabled;
      }
      if (typeof swift.pastelBarColors === "boolean") {
        base.pastelBarColors = swift.pastelBarColors;
      }
      if (swift._legacyDesign) {
        for (const id of SOURCE_IDS) {
          if (raw.sources?.[id]?.barDesign === undefined) {
            base.sources[id].barDesign = resolveBarDesign(
              swift._legacyDesign,
              spendOnlyFor(id, base.sources[id].account),
            );
          }
        }
      }
      if (swift._cursorDesign && raw.sources?.cursor?.barDesign === undefined) {
        base.sources.cursor.barDesign = resolveBarDesign(
          swift._cursorDesign,
          spendOnlyFor("cursor", base.sources.cursor.account),
        );
      }
    }

    const b = raw.openAIBalance;
    if (
      b &&
      typeof b.enteredUSD === "number" &&
      typeof b.dayStart === "string" &&
      typeof b.spendAlreadyReportedUSD === "number"
    ) {
      base.openAIBalance = { ...b };
    }
    if (raw.openAIBalanceMigrated === true) base.openAIBalanceMigrated = true;
    this.adoptSwiftBalance(base);
    return base;
  }

  private adoptSwiftBalance(base: Prefs): void {
    if (base.openAIBalance || base.openAIBalanceMigrated) return;
    const migrated = readSwiftOpenAIBalance();
    if (!migrated) return;
    base.openAIBalance = migrated;
    base.openAIBalanceMigrated = true;
    this.writeAfterLoad = true;
  }

  private persist(): void {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, this.file);
    restrictFile(this.file);
  }
}
