import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { BAR_DESIGNS, resolveBarDesign, type BarDesign } from "./barDesign";
import { restrictFile } from "./fsSecure";
import {
  REFRESH_CHOICES,
  SOURCE_ACCOUNTS,
  SOURCE_IDS,
  type Prefs,
  type SourceId,
  type SourcePrefs,
} from "./types";

const BAR_IDS = new Set(BAR_DESIGNS.map((d) => d.id));

function defaultSource(id: SourceId, enabled: boolean): SourcePrefs {
  return {
    enabled,
    showInTray: enabled,
    account: SOURCE_ACCOUNTS[id][0],
    barDesign: "divider",
    showDailyInBar: true,
    showMonthlyInBar: true,
  };
}

/** Claude and Cursor start on; the others stay off until enabled (same as Swift). */
export function defaultPrefs(): Prefs {
  return {
    version: 1,
    sources: {
      claude: defaultSource("claude", true),
      cursor: defaultSource("cursor", true),
      chatgpt: { ...defaultSource("chatgpt", false), account: "personal" },
      openai: defaultSource("openai", false),
      grokbot: defaultSource("grokbot", false),
    },
    refreshMinutes: 1,
    cursorPersonalAllowanceUSD: 20,
    openAtLogin: false,
    themedProviderLogos: false,
    darkBarBackground: true,
    spendColorsEnabled: true,
    pastelBarColors: false,
  };
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
    barDesign: parseBarDesign(s?.barDesign, spendOnly),
    showDailyInBar: typeof s?.showDailyInBar === "boolean" ? s.showDailyInBar : base.showDailyInBar,
    showMonthlyInBar:
      typeof s?.showMonthlyInBar === "boolean" ? s.showMonthlyInBar : base.showMonthlyInBar,
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

export class PrefsStore {
  private data: Prefs;
  private readonly file: string;

  constructor(file: string) {
    this.file = file;
    this.data = this.load();
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
    }
    if (typeof patch.themedProviderLogos === "boolean") {
      this.data.themedProviderLogos = patch.themedProviderLogos;
    }
    if (typeof patch.darkBarBackground === "boolean") {
      this.data.darkBarBackground = patch.darkBarBackground;
    }
    if (typeof patch.spendColorsEnabled === "boolean") {
      this.data.spendColorsEnabled = patch.spendColorsEnabled;
    }
    if (typeof patch.pastelBarColors === "boolean") {
      this.data.pastelBarColors = patch.pastelBarColors;
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
        themedProviderLogos: swift.themedProviderLogos ?? base.themedProviderLogos,
        darkBarBackground: swift.darkBarBackground ?? base.darkBarBackground,
        spendColorsEnabled: swift.spendColorsEnabled ?? base.spendColorsEnabled,
        pastelBarColors: swift.pastelBarColors ?? base.pastelBarColors,
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
      this.data = base;
      this.persist();
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
    if (typeof raw.themedProviderLogos === "boolean") {
      base.themedProviderLogos = raw.themedProviderLogos;
    }
    if (typeof raw.darkBarBackground === "boolean") base.darkBarBackground = raw.darkBarBackground;
    if (typeof raw.spendColorsEnabled === "boolean") {
      base.spendColorsEnabled = raw.spendColorsEnabled;
    }
    if (typeof raw.pastelBarColors === "boolean") base.pastelBarColors = raw.pastelBarColors;

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
      if (typeof swift.themedProviderLogos === "boolean") {
        base.themedProviderLogos = swift.themedProviderLogos;
      }
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
    return base;
  }

  private persist(): void {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, this.file);
    restrictFile(this.file);
  }
}
