import fs from "node:fs";
import path from "node:path";
import { restrictFile } from "./fsSecure";
import {
  REFRESH_CHOICES,
  SOURCE_ACCOUNTS,
  SOURCE_IDS,
  type Prefs,
  type SourceId,
  type SourcePrefs,
} from "./types";

/** Claude and Cursor start on; the others stay off until enabled (same as Swift). */
export function defaultPrefs(): Prefs {
  return {
    version: 1,
    sources: {
      claude: { enabled: true, showInTray: true, account: "work" },
      cursor: { enabled: true, showInTray: true, account: "work" },
      chatgpt: { enabled: false, showInTray: false, account: "personal" },
      openai: { enabled: false, showInTray: false, account: "work" },
      grokbot: { enabled: false, showInTray: false, account: "personal" },
    },
    refreshMinutes: 1,
    cursorPersonalAllowanceUSD: 20,
    openAtLogin: false,
  };
}

export class PrefsStore {
  private data: Prefs;

  constructor(private readonly file: string) {
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
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, "utf8")) as Partial<Prefs>;
      if (raw.version !== 1) return base;
      for (const id of SOURCE_IDS) {
        const s = raw.sources?.[id];
        if (!s) continue;
        base.sources[id] = {
          enabled: typeof s.enabled === "boolean" ? s.enabled : base.sources[id].enabled,
          showInTray:
            typeof s.showInTray === "boolean" ? s.showInTray : base.sources[id].showInTray,
          account: SOURCE_ACCOUNTS[id].includes(s.account)
            ? s.account
            : base.sources[id].account,
        };
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
    } catch {
      return base;
    }
  }

  private persist(): void {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, this.file);
    restrictFile(this.file);
  }
}
