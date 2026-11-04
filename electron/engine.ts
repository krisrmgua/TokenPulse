import os from "node:os";
import path from "node:path";
import { SourceError } from "./http";
import {
  barPercent,
  dayString,
  displayDate,
  displayDateTime,
  exactMoney,
  projectedMonthEnd,
  shortDate,
  shortMoney,
  startOfNextMonth,
} from "./format";
import type { Pricing } from "./pricing";
import type { PrefsStore } from "./prefs";
import type { OpenAIKeyStore } from "./openaiAdmin";
import type { SpendLedger } from "./ledger";
import {
  SOURCE_ACCOUNTS,
  SOURCE_IDS,
  SOURCE_NAMES,
  type AppState,
  type CombinedSpend,
  type Meter,
  type Prefs,
  type SourceId,
  type SourceSnapshot,
  type SourceStatus,
} from "./types";
import { ClaudeTranscriptScanner, claudeProjectRoots, type ClaudeRollup } from "./sources/claude";
import {
  CursorClient,
  cursorPersonalPercentLeft,
  type CursorSpendSnapshot,
} from "./sources/cursor";
import {
  cursorAccessToken,
  cursorStateDbPath,
  type CursorToken,
} from "./sources/cursorAuth";
import { fetchGrokBot, type GrokBotSnapshot } from "./sources/grokbot";
import {
  codexAuthPath,
  codexExecutable,
  fetchChatGPTPersonal,
  fetchChatGPTWork,
  PUBLIC_USD_PER_CREDIT,
  workEstimatedUSD,
  workTodayIsPending,
  workTodayUSD,
  type ChatGPTPersonalSnapshot,
  type ChatGPTWorkSnapshot,
} from "./sources/chatgpt";
import { fetchOpenAISpend, type OpenAISpendSnapshot } from "./sources/openai";

/** Courtesy floor between network calls to any one provider (matches Swift). */
const REMOTE_MIN_MS = 5 * 60_000;
/** Last-good data older than this is dropped rather than shown. */
const DROP_AFTER_MS = 30 * 60_000;

interface Slot<T> {
  data?: T;
  fetchedAt?: number;
  lastAttempt?: number;
  error?: string;
}

function tildify(p: string): string {
  const home = os.homedir();
  return p.startsWith(home) ? `~${p.slice(home.length)}` : p;
}

function errorMessage(err: unknown): string {
  if (err instanceof SourceError) return err.message;
  return `Unexpected error: ${(err as Error)?.message ?? String(err)}`;
}

export interface EngineMeta {
  dataDir: string;
  version: string;
  platform: string;
}

export class Engine {
  private readonly claudeScanner: ClaudeTranscriptScanner;
  private readonly cursorClient = new CursorClient();
  private claude: Slot<ClaudeRollup> = {};
  private cursor: Slot<CursorSpendSnapshot> = {};
  private grokbot: Slot<GrokBotSnapshot> = {};
  private chatgptPersonal: Slot<ChatGPTPersonalSnapshot> = {};
  private chatgptWork: Slot<ChatGPTWorkSnapshot> = {};
  private openai: Slot<OpenAISpendSnapshot> = {};
  private cursorLogin?: Pick<CursorToken, "login" | "reader">;
  private inFlight?: Promise<void>;
  private refreshing = false;
  private updatedAt?: number;
  private listeners = new Set<() => void>();

  constructor(
    private readonly prefs: PrefsStore,
    private readonly keys: OpenAIKeyStore,
    private readonly ledger: SpendLedger,
    pricing: Pricing,
    private readonly meta: EngineMeta,
  ) {
    this.claudeScanner = new ClaudeTranscriptScanner(pricing);
  }

  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private emit(): void {
    for (const l of this.listeners) l();
  }

  /** Coalesces overlapping refreshes. `force` skips the remote throttle. */
  refresh(force = false): Promise<void> {
    if (this.inFlight) {
      return force ? this.inFlight.then(() => this.refresh(true)) : this.inFlight;
    }
    this.inFlight = this.doRefresh(force).finally(() => {
      this.inFlight = undefined;
    });
    return this.inFlight;
  }

  /** Forget cached data for a source (e.g. after a key change). */
  clear(id: SourceId): void {
    if (id === "openai") this.openai = {};
    if (id === "chatgpt") {
      this.chatgptPersonal = {};
      this.chatgptWork = {};
    }
    if (id === "cursor") {
      this.cursor = {};
      this.cursorClient.reset();
    }
    if (id === "grokbot") this.grokbot = {};
    if (id === "claude") this.claude = {};
  }

  /** Today's reported OpenAI cost, used to anchor a newly entered balance. */
  openAITodaySpend(): number {
    return this.usable(this.openai)?.todaySpendUSD ?? 0;
  }

  private async run<T>(slot: Slot<T>, minMs: number, force: boolean, fn: () => Promise<T>): Promise<void> {
    const now = Date.now();
    const dayChanged =
      slot.fetchedAt !== undefined && dayString(new Date(slot.fetchedAt)) !== dayString();
    if (!force && !dayChanged && slot.lastAttempt !== undefined && now - slot.lastAttempt < minMs) {
      return;
    }
    slot.lastAttempt = now;
    try {
      slot.data = await fn();
      slot.fetchedAt = Date.now();
      slot.error = undefined;
    } catch (err) {
      slot.error = errorMessage(err);
    }
  }

  private async doRefresh(force: boolean): Promise<void> {
    this.refreshing = true;
    this.emit();
    try {
      await this.refreshSources(force);
    } finally {
      this.updatedAt = Date.now();
      this.refreshing = false;
      this.emit();
    }
  }

  private async refreshSources(force: boolean): Promise<void> {
    const p = this.prefs.get();
    const s = p.sources;
    const tasks: Promise<void>[] = [];

    if (s.claude.enabled) {
      tasks.push(this.run(this.claude, 0, force, () => this.claudeScanner.rollup(new Date())));
    }

    if (s.cursor.enabled || s.grokbot.enabled) {
      let tokenPromise: Promise<CursorToken> | undefined;
      const token = async () => {
        tokenPromise ??= cursorAccessToken().then((t) => {
          this.cursorLogin = { login: t.login, reader: t.reader };
          return t;
        });
        return (await tokenPromise).token;
      };
      if (s.cursor.enabled) {
        tasks.push(
          this.run(this.cursor, REMOTE_MIN_MS, force, async () =>
            this.cursorClient.fetch(await token(), new Date()),
          ),
        );
      }
      if (s.grokbot.enabled) {
        tasks.push(
          this.run(this.grokbot, REMOTE_MIN_MS, force, async () => fetchGrokBot(await token())),
        );
      }
    }

    if (s.chatgpt.enabled) {
      if (s.chatgpt.account === "personal") {
        tasks.push(this.run(this.chatgptPersonal, REMOTE_MIN_MS, force, () => fetchChatGPTPersonal()));
      } else {
        tasks.push(this.run(this.chatgptWork, REMOTE_MIN_MS, force, () => fetchChatGPTWork(new Date())));
      }
    }

    if (s.openai.enabled) {
      tasks.push(
        this.run(this.openai, REMOTE_MIN_MS, force, async () => {
          const key = this.keys.read();
          if (!key) throw new SourceError("No OpenAI Admin API key is saved.", "setup");
          return fetchOpenAISpend(key, this.prefs.get().openAIBalance, new Date());
        }),
      );
    }

    await Promise.all(tasks);

    const combined = this.combined(this.prefs.get());
    if (combined) {
      try {
        this.ledger.record(combined.todayUSD, combined.monthUSD);
      } catch {
        // Ledger is a convenience; a write failure must not break refresh.
      }
    }
  }

  /** Data still fit to show: present, under 30 minutes old, and from today. */
  private usable<T>(slot: Slot<T>, sameDay = true): T | undefined {
    if (slot.data === undefined || slot.fetchedAt === undefined) return undefined;
    if (Date.now() - slot.fetchedAt > DROP_AFTER_MS) return undefined;
    if (sameDay && dayString(new Date(slot.fetchedAt)) !== dayString()) return undefined;
    return slot.data;
  }

  private status<T>(enabled: boolean, slot: Slot<T>, data: T | undefined, minMs: number, refreshMs: number): SourceStatus {
    if (!enabled) return "off";
    if (data === undefined) {
      if (slot.error) return "error";
      return "loading";
    }
    const age = Date.now() - (slot.fetchedAt ?? 0);
    if (slot.error || age > 2.5 * Math.max(refreshMs, minMs)) return "stale";
    return "ok";
  }

  private combined(p: Prefs): CombinedSpend | null {
    const s = p.sources;
    const claude = s.claude.enabled ? this.usable(this.claude) : undefined;
    const cursor =
      s.cursor.enabled && s.cursor.account === "work" ? this.usable(this.cursor) : undefined;
    const chat =
      s.chatgpt.enabled && s.chatgpt.account === "work" ? this.usable(this.chatgptWork) : undefined;
    if (!claude && !cursor && !chat) return null;
    const chatToday = chat && !workTodayIsPending(chat) ? workTodayUSD(chat) : 0;
    const today = (claude?.todayUSD ?? 0) + (cursor?.todaySpendUSD ?? 0) + chatToday;
    const month =
      (claude?.monthUSD ?? 0) + (cursor?.totalSpendUSD ?? 0) + (chat ? workEstimatedUSD(chat) : 0);
    return { todayUSD: today, monthUSD: month, projectedUSD: projectedMonthEnd(month) };
  }

  state(): AppState {
    const p = this.prefs.get();
    const refreshMs = p.refreshMinutes * 60_000;
    const sources = SOURCE_IDS.map((id) => this.snapshot(id, p, refreshMs));
    const combined = this.combined(p);
    return {
      sources,
      combined,
      chart: combined ? this.ledger.monthChart(combined.monthUSD, combined.projectedUSD) : [],
      prefs: p,
      refreshing: this.refreshing,
      updatedAt: this.updatedAt ? new Date(this.updatedAt).toISOString() : undefined,
      platform: this.meta.platform,
      openAIKeyConfigured: this.keys.isConfigured(),
      dataDir: this.meta.dataDir,
      version: this.meta.version,
      icons: {
        chatgpt: "",
        cursor: "",
        grokbot: "",
        openai: "",
        claude: "",
      },
    };
  }

  /** Tray title fragments for enabled + shown sources. */
  trayText(): { title: string; tooltip: string } {
    const st = this.state();
    const shown = st.sources.filter((s) => s.enabled && s.showInTray);
    const parts = shown.map((s) => s.barText).filter((t): t is string => Boolean(t));
    const tipLines = shown.map((s) => `${s.name}: ${s.barText ?? (s.message ?? s.status)}`);
    if (st.combined) {
      tipLines.push(
        `Work spend: today ${exactMoney(st.combined.todayUSD)}, month ${exactMoney(st.combined.monthUSD)}`,
      );
    }
    return {
      title: parts.join("  "),
      tooltip: ["TokenPulse", ...tipLines].join("\n"),
    };
  }

  private base(id: SourceId, p: Prefs): SourceSnapshot {
    const sp = p.sources[id];
    return {
      id,
      name: SOURCE_NAMES[id],
      enabled: sp.enabled,
      showInTray: sp.showInTray,
      account: sp.account,
      accounts: SOURCE_ACCOUNTS[id],
      status: "off",
      meters: [],
      lines: [],
      credential: "",
    };
  }

  private snapshot(id: SourceId, p: Prefs, refreshMs: number): SourceSnapshot {
    switch (id) {
      case "claude":
        return this.claudeSnapshot(p, refreshMs);
      case "cursor":
        return this.cursorSnapshot(p, refreshMs);
      case "chatgpt":
        return this.chatgptSnapshot(p, refreshMs);
      case "openai":
        return this.openaiSnapshot(p, refreshMs);
      case "grokbot":
        return this.grokSnapshot(p, refreshMs);
    }
  }

  private finish<T>(out: SourceSnapshot, slot: Slot<T>, data: T | undefined, minMs: number, refreshMs: number): SourceSnapshot {
    out.status = this.status(out.enabled, slot, data, minMs, refreshMs);
    if (out.enabled && slot.error) {
      out.message = data !== undefined ? `Last refresh failed: ${slot.error}` : slot.error;
    }
    if (data !== undefined && slot.fetchedAt) out.fetchedAt = new Date(slot.fetchedAt).toISOString();
    if (!out.enabled || data === undefined) out.barText = undefined;
    if (out.enabled && out.meters.length === 0 && !out.resetNote) {
      out.resetNote = this.defaultResetNote(out);
    }
    return out;
  }

  /** Swift AppDelegate resetNote for spend / balance cards (no meters). */
  private defaultResetNote(out: SourceSnapshot): string {
    if (out.id === "openai") return "Prepaid balance has no scheduled reset.";
    if (out.id === "claude" && out.account === "work") {
      return `Monthly totals reset ${displayDate(startOfNextMonth())}`;
    }
    if (out.id === "cursor" && out.account === "work") {
      const end = this.usable(this.cursor)?.planUsage?.billingCycleEnd;
      if (end && end > 0) return `Billing cycle resets ${displayDate(new Date(end))}`;
    }
    return "Reset time not reported by provider.";
  }

  private claudeSnapshot(p: Prefs, refreshMs: number): SourceSnapshot {
    const out = this.base("claude", p);
    const roots = claudeProjectRoots();
    out.credential =
      roots.length > 0
        ? `Local transcripts: ${roots.map(tildify).join(", ")}`
        : `No transcripts found at ${tildify(path.join(os.homedir(), ".claude", "projects"))}`;
    const r = out.enabled ? this.usable(this.claude) : undefined;
    if (r) {
      out.todayUSD = r.todayUSD;
      out.monthUSD = r.monthUSD;
      out.projectedUSD = r.projectedUSD;
      out.barText = `CL ${shortMoney(r.todayUSD)}/${shortMoney(r.monthUSD)}`;
      out.lines.push(
        { label: "Sessions this month", value: String(r.sessions) },
        { label: "Cache hit rate", value: `${Math.round(r.cacheHitPct * 100)}%` },
        {
          label: "Opus share",
          value: r.monthUSD > 0 ? `${Math.round((r.opusUSD / r.monthUSD) * 100)}%` : "0%",
        },
        { label: "Transcript files this month", value: String(r.filesScanned) },
      );
      const models = Object.entries(r.byModelUSD).sort((a, b) => b[1] - a[1]).slice(0, 6);
      for (const [model, usd] of models) out.lines.push({ label: model, value: exactMoney(usd) });
      if (r.filesScanned === 0) {
        out.message = "No Claude Code transcripts were written this month.";
      }
    }
    return this.finish(out, this.claude, r, 0, refreshMs);
  }

  private cursorCredential(): string {
    const db = tildify(cursorStateDbPath());
    if (!this.cursorLogin) return `Cursor login in ${db}`;
    const how =
      this.cursorLogin.login === "encrypted"
        ? process.platform === "darwin"
          ? "encrypted, key from Keychain item “Cursor Safe Storage”"
          : process.platform === "win32"
            ? "encrypted, key unwrapped with Windows DPAPI"
            : "encrypted"
        : "plain token";
    return `Cursor login in ${db} (${how}, read via ${this.cursorLogin.reader})`;
  }

  private cursorSnapshot(p: Prefs, refreshMs: number): SourceSnapshot {
    const out = this.base("cursor", p);
    out.credential = this.cursorCredential();
    const c = out.enabled ? this.usable(this.cursor) : undefined;
    if (c) {
      if (out.account === "work") {
        out.todayUSD = c.todaySpendUSD;
        out.monthUSD = c.totalSpendUSD;
        out.projectedUSD = projectedMonthEnd(c.totalSpendUSD);
        out.barText = `CU ${shortMoney(c.todaySpendUSD)}/${shortMoney(c.totalSpendUSD)}`;
        for (const m of c.byModel.slice(0, 6)) {
          out.lines.push({ label: m.model, value: exactMoney(m.spendUSD) });
        }
        if (c.planUsage) {
          out.lines.push({
            label: "Included usage",
            value: `${Math.round(c.planUsage.totalPercentUsed)}% of ${exactMoney(c.planUsage.limitUSD)}`,
          });
        }
      } else {
        const pct = cursorPersonalPercentLeft(c, p.cursorPersonalAllowanceUSD);
        const end = c.planUsage?.billingCycleEnd;
        const meter: Meter = {
          id: "included",
          label: "Included Pro",
          percentLeft: pct,
          resetAt: end ? new Date(end).toISOString() : undefined,
        };
        out.meters.push(meter);
        out.barText = `CU ${barPercent(pct, end ? new Date(end) : undefined)}`;
        if (c.planUsage) {
          out.lines.push(
            { label: "Plan limit", value: exactMoney(c.planUsage.limitUSD) },
            { label: "Included spend", value: exactMoney(c.planUsage.includedSpendUSD) },
          );
        } else {
          out.lines.push({
            label: "Allowance (no plan meter reported)",
            value: exactMoney(p.cursorPersonalAllowanceUSD),
          });
        }
      }
      out.lines.push({ label: "Cursor user id", value: String(c.userId) });
    }
    return this.finish(out, this.cursor, c, REMOTE_MIN_MS, refreshMs);
  }

  private chatgptSnapshot(p: Prefs, refreshMs: number): SourceSnapshot {
    const out = this.base("chatgpt", p);
    if (out.account === "personal") {
      const codex = codexExecutable();
      out.credential = codex
        ? `Codex CLI session (${tildify(codex)} app-server)`
        : "Codex CLI not found (install from chatgpt.com/codex)";
      const c = out.enabled ? this.usable(this.chatgptPersonal, false) : undefined;
      if (c) {
        if (c.session) {
          out.meters.push({
            id: "session",
            label: "5-hour",
            percentLeft: c.session.percentLeft,
            resetAt: new Date(c.session.resetAt).toISOString(),
          });
        }
        out.meters.push({
          id: "weekly",
          label: "Weekly",
          percentLeft: c.weekly.percentLeft,
          resetAt: new Date(c.weekly.resetAt).toISOString(),
        });
        const bits = c.session
          ? `5H ${barPercent(c.session.percentLeft, new Date(c.session.resetAt))} W ${barPercent(c.weekly.percentLeft, new Date(c.weekly.resetAt))}`
          : `W ${barPercent(c.weekly.percentLeft, new Date(c.weekly.resetAt))}`;
        out.barText = `GPT ${bits}`;
        out.lines.push({ label: "Weekly resets", value: displayDateTime(new Date(c.weekly.resetAt)) });
      }
      return this.finish(out, this.chatgptPersonal, c, REMOTE_MIN_MS, refreshMs);
    }

    out.credential = `Codex ChatGPT login in ${tildify(codexAuthPath())}`;
    const w = out.enabled ? this.usable(this.chatgptWork, false) : undefined;
    if (w) {
      const pending = workTodayIsPending(w);
      const month = workEstimatedUSD(w);
      out.monthUSD = month;
      out.todayUSD = pending ? undefined : workTodayUSD(w);
      out.projectedUSD = projectedMonthEnd(month);
      out.barText = `GPT ${pending ? "…" : shortMoney(workTodayUSD(w))}/${shortMoney(month)}`;
      out.lines.push(
        { label: "Credits this month", value: w.monthCredits.toFixed(1) },
        { label: "Credits today", value: pending ? "pending ingestion" : w.todayCredits.toFixed(1) },
        {
          label: "Estimate basis",
          value: w.serverEstimatedUSD !== undefined
            ? "workspace estimate"
            : `public rate card ($${PUBLIC_USD_PER_CREDIT}/credit)`,
        },
      );
      for (const [product, credits] of Object.entries(w.byProduct).sort((a, b) => b[1] - a[1])) {
        out.lines.push({ label: product, value: `${credits.toFixed(1)} credits` });
      }
      if (w.dataFreshnessAt) {
        out.lines.push({ label: "Data fresh through", value: displayDateTime(new Date(w.dataFreshnessAt)) });
      }
    }
    return this.finish(out, this.chatgptWork, w, REMOTE_MIN_MS, refreshMs);
  }

  private openaiSnapshot(p: Prefs, refreshMs: number): SourceSnapshot {
    const out = this.base("openai", p);
    out.credential = this.keys.isConfigured()
      ? `Admin key file ${tildify(this.keys.file)} (owner-only)`
      : "No Admin key saved";
    const o = out.enabled ? this.usable(this.openai) : undefined;
    if (o) {
      out.todayUSD = o.todaySpendUSD;
      out.monthUSD = o.monthSpendUSD;
      out.projectedUSD = projectedMonthEnd(o.monthSpendUSD);
      out.barText =
        o.estimatedBalanceUSD !== undefined
          ? `OAI bal ${shortMoney(o.estimatedBalanceUSD)}`
          : `OAI ${shortMoney(o.todaySpendUSD)}/${shortMoney(o.monthSpendUSD)}`;
      if (o.estimatedBalanceUSD !== undefined) {
        out.lines.push({ label: "Estimated prepaid balance", value: exactMoney(o.estimatedBalanceUSD) });
      }
      for (const line of o.byLineItem.slice(0, 8)) {
        out.lines.push({ label: line.lineItem, value: exactMoney(line.spendUSD) });
      }
    }
    return this.finish(out, this.openai, o, REMOTE_MIN_MS, refreshMs);
  }

  private grokSnapshot(p: Prefs, refreshMs: number): SourceSnapshot {
    const out = this.base("grokbot", p);
    out.credential = this.cursorCredential();
    const g = out.enabled ? this.usable(this.grokbot, false) : undefined;
    if (g) {
      out.meters.push({
        id: "weekly",
        label: "Weekly Sand",
        percentLeft: g.percentLeft,
        resetAt: g.resetAt ? new Date(g.resetAt).toISOString() : undefined,
      });
      out.barText = `GRK ${barPercent(g.percentLeft, g.resetAt ? new Date(g.resetAt) : undefined)}`;
      if (g.planLabel) out.lines.push({ label: "Grok plan", value: g.planLabel });
      if (g.cursorPlanName) out.lines.push({ label: "Cursor plan", value: g.cursorPlanName });
      if (g.resetAt) out.lines.push({ label: "Resets", value: shortDate(new Date(g.resetAt)) });
    }
    return this.finish(out, this.grokbot, g, REMOTE_MIN_MS, refreshMs);
  }
}
