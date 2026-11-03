import { barDesignTitle, barDesignsFor, type BarDesign } from "../../electron/barDesign";
import type {
  AccountMode,
  ActionResult,
  AppState,
  ChartPoint,
  Meter,
  Prefs,
  SourceId,
  SourcePrefs,
  SourceSnapshot,
  SourceStatus,
} from "../../electron/types";

interface TokenPulseApi {
  getState: () => Promise<AppState>;
  refresh: () => Promise<AppState>;
  setSource: (id: SourceId, patch: Partial<SourcePrefs>) => Promise<ActionResult>;
  setPrefs: (patch: Partial<Prefs>) => Promise<ActionResult>;
  resetPrefs: () => Promise<ActionResult>;
  saveOpenAIKey: (key: string) => Promise<ActionResult>;
  deleteOpenAIKey: () => Promise<ActionResult>;
  setOpenAIBalance: (usd: number | null) => Promise<ActionResult>;
  openDataDir: () => Promise<void>;
  openExternal: (url: string) => Promise<void>;
  hide: () => Promise<void>;
  fitHeight: (height: number) => Promise<void>;
  quit: () => Promise<void>;
  onChanged: (cb: () => void) => () => void;
  onOpened: (cb: () => void) => () => void;
}

declare global {
  interface Window {
    tokenpulse: TokenPulseApi;
  }
}

type MainRoute = "overview" | "spend" | "efficiency" | "scoreboard" | "alerts" | "options";
type Route = MainRoute | `source:${SourceId}` | `settings:${SourceId}`;
type NoticeKind = "ok" | "warn" | "err";

/** Sidebar / tray provider order — matches Swift Mission Control. */
const PROVIDER_ORDER: SourceId[] = ["chatgpt", "cursor", "grokbot", "openai", "claude"];

const REFRESH_CHOICES = [1, 2, 3, 5, 10, 15, 30];
const RESET_CONFIRM_MS = 4000;
const CHART_COLORS = { actual: "#58d2ec", projected: "#f0cc85", today: "#75e0b3" };

const api = window.tokenpulse;

function byId<T extends HTMLElement = HTMLElement>(id: string): T {
  return document.getElementById(id) as T;
}

const el = {
  top: byId("top"),
  updated: byId("updated"),
  spinner: byId("spinner"),
  back: byId<HTMLButtonElement>("btn-back"),
  refresh: byId<HTMLButtonElement>("btn-refresh"),
  options: byId<HTMLButtonElement>("btn-options"),
  tabbar: byId("tabbar"),
  chips: byId("chips"),
  sidebar: byId("sidebar"),
  content: byId("content"),
  inner: byId("content-inner"),
  foot: byId("foot"),
  footLeft: byId("foot-left"),
  quit: byId<HTMLButtonElement>("btn-quit"),
};

let state: AppState | null = null;
let route: Route = "overview";
let lastMainRoute: MainRoute = "overview";
let notice: { text: string; kind: NoticeKind } | null = null;
let pendingContent = false;
let focusKeyInput = false;
let busy = false;
let resetArmedUntil = 0;

// ---------- formatting ----------

function escapeHtml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function money(usd: number): string {
  return `$${usd.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function shortMoney(usd: number): string {
  const v = Math.max(0, usd);
  if (v >= 10_000) return `$${Math.round(v / 1000)}k`;
  if (v >= 1000) return `$${(v / 1000).toFixed(1)}k`;
  if (v >= 100) return `$${Math.round(v)}`;
  return `$${v.toFixed(2)}`;
}

function clockTime(iso: string): string {
  return new Date(iso).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
}

function dateTime(iso: string): string {
  return new Date(iso).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function resetHint(iso: string): string {
  const ms = new Date(iso).getTime() - Date.now();
  if (ms > 0 && ms < 24 * 3_600_000) return `resets ${clockTime(iso)}`;
  return `resets ${dateTime(iso)}`;
}

function trayWord(): string {
  return state?.platform === "darwin" ? "menu bar" : "tray";
}

const STATUS_LABEL: Record<SourceStatus, string> = {
  off: "Off",
  loading: "Loading",
  ok: "Live",
  stale: "Stale",
  error: "Error",
};

function accountLabel(id: SourceId, account: AccountMode): string {
  if (id === "chatgpt") return account === "work" ? "Work credits" : "Personal allowance";
  if (id === "grokbot") return "Weekly allowance";
  if (id === "openai") return "Org spend";
  return account === "work" ? "Work spend" : "Personal allowance";
}

function orderedSources(st: AppState): SourceSnapshot[] {
  const byId = new Map(st.sources.map((s) => [s.id, s]));
  return PROVIDER_ORDER.map((id) => byId.get(id)).filter((s): s is SourceSnapshot => Boolean(s));
}

// ---------- provider marks (Artwork / SF glyphs from main) ----------

function providerMark(id: SourceId, size: number): string {
  const src = state?.icons?.[id];
  if (src) {
    return `<img class="pmark" src="${src}" width="${size}" height="${size}" alt="" />`;
  }
  return `<span class="pmark placeholder" style="width:${size}px;height:${size}px"></span>`;
}

// ---------- shared fragments ----------

function noticeHtml(): string {
  if (!notice) return "";
  const cls = notice.kind === "ok" ? "note" : `note ${notice.kind}`;
  return `<div class="${cls}">${escapeHtml(notice.text)}</div>`;
}

function meterClass(pct: number): string {
  if (pct < 20) return "low";
  if (pct < 50) return "mid";
  return "";
}

function meterHtml(m: Meter): string {
  const pct = Math.max(0, Math.min(100, Math.round(m.percentLeft)));
  const reset = m.resetAt ? ` <span class="muted">· ${escapeHtml(resetHint(m.resetAt))}</span>` : "";
  return `<div class="meter">
    <div class="meter-top"><span>${escapeHtml(m.label)}${reset}</span><span class="pct">${pct}% left</span></div>
    <div class="bar"><span class="${meterClass(pct)}" style="width:${pct}%"></span></div>
  </div>`;
}

function metersHtml(s: SourceSnapshot): string {
  if (s.meters.length === 0) return "";
  return `<div class="meters">${s.meters.map(meterHtml).join("")}</div>`;
}

function togglesHtml(s: SourceSnapshot): string {
  return `<div class="toggles">
    <label class="toggle"><input type="checkbox" data-act="enable" data-id="${s.id}" ${s.enabled ? "checked" : ""} /> Enable</label>
    <label class="toggle"><input type="checkbox" data-act="tray" data-id="${s.id}" ${s.showInTray ? "checked" : ""} ${s.enabled ? "" : "disabled"} /> Show in ${trayWord()}</label>
  </div>`;
}

function accountSelectHtml(s: SourceSnapshot): string {
  if (s.accounts.length < 2) return "";
  const opts = s.accounts
    .map(
      (a) =>
        `<option value="${a}" ${a === s.account ? "selected" : ""}>${escapeHtml(accountLabel(s.id, a))}</option>`,
    )
    .join("");
  return `<select data-act="account" data-id="${s.id}" aria-label="${escapeHtml(s.name)} account">${opts}</select>`;
}

function rowsHtml(rows: [string, string][]): string {
  if (rows.length === 0) return "";
  return `<div class="table">${rows
    .map(([k, v]) => `<div class="row"><span class="k">${escapeHtml(k)}</span><span class="v">${escapeHtml(v)}</span></div>`)
    .join("")}</div>`;
}

function metricsHtml(items: [string, string][]): string {
  return `<div class="metrics">${items
    .map(([k, v]) => `<div class="metric"><div class="k">${escapeHtml(k)}</div><div class="v">${escapeHtml(v)}</div></div>`)
    .join("")}</div>`;
}

function spendHeadline(s: SourceSnapshot): string {
  if (s.todayUSD === undefined && s.monthUSD === undefined) return "";
  const bits: string[] = [];
  if (s.todayUSD !== undefined) bits.push(`Today ${money(s.todayUSD)}`);
  if (s.monthUSD !== undefined) bits.push(`Month ${money(s.monthUSD)}`);
  return `<div class="spend-headline">${bits.join(" · ")}</div>`;
}

// ---------- views ----------

function sourceCard(s: SourceSnapshot): string {
  if (!s.enabled) {
    return `<article class="card off compact" data-act="go" data-route="source:${s.id}">
      <div class="card-head">
        ${providerMark(s.id, 16)}
        <span class="name">${escapeHtml(s.name)}</span>
        <span class="spacer"></span>
        <span class="dot ${s.status}"></span>
        <span class="status-line">Disabled</span>
      </div>
    </article>`;
  }
  return `<article class="card${s.status === "stale" ? " stale" : ""}">
    <div class="card-head">
      ${providerMark(s.id, 20)}
      <div class="card-titles">
        <span class="name" data-act="go" data-route="source:${s.id}">${escapeHtml(s.name)}</span>
        <span class="badge">${escapeHtml(accountLabel(s.id, s.account))}</span>
      </div>
      <span class="spacer"></span>
      <span class="status-line ${s.status}">${STATUS_LABEL[s.status]}</span>
    </div>
    ${s.meters.length > 0 ? metersHtml(s) : spendHeadline(s)}
    ${s.message ? `<div class="msg${s.status === "error" ? " err" : ""}">${escapeHtml(s.message)}</div>` : ""}
    <button class="link details" data-act="go" data-route="source:${s.id}">View details ›</button>
  </article>`;
}

function overviewView(st: AppState): string {
  const parts = [noticeHtml()];
  const sources = orderedSources(st);
  const enabled = sources.filter((s) => s.enabled);
  const disabled = sources.filter((s) => !s.enabled);
  parts.push(`<div class="grid">${enabled.map(sourceCard).join("")}</div>`);
  if (disabled.length > 0) {
    parts.push(`<div class="disabled-list">${disabled.map(sourceCard).join("")}</div>`);
  }
  parts.push(
    `<div class="foot-note muted">Allowances, prepaid balances, and work spend stay separate. Combined work totals live on the spend chips.</div>`,
  );
  return parts.join("");
}

function niceMax(v: number): number {
  const mag = 10 ** Math.floor(Math.log10(v));
  for (const m of [1, 2, 2.5, 5, 10]) {
    if (m * mag >= v) return m * mag;
  }
  return 10 * mag;
}

function chartSvg(points: ChartPoint[]): string {
  const W = 574;
  const H = 220;
  const L = 46;
  const R = 12;
  const T = 12;
  const B = 22;
  const n = points.length;
  const values = points
    .flatMap((p) => [p.actualUSD, p.projectedUSD])
    .filter((v): v is number => v !== null);
  const max = niceMax(Math.max(1, ...values));
  const x = (day: number) => L + ((day - 1) / Math.max(1, n - 1)) * (W - L - R);
  const y = (v: number) => T + (1 - v / max) * (H - T - B);
  const pt = (day: number, v: number) => `${x(day).toFixed(1)},${y(v).toFixed(1)}`;

  const out: string[] = [];
  for (let i = 0; i <= 4; i++) {
    const v = (max * i) / 4;
    const yy = y(v).toFixed(1);
    out.push(`<line class="grid-line" x1="${L}" x2="${W - R}" y1="${yy}" y2="${yy}" />`);
    out.push(
      `<text class="axis" x="${L - 6}" y="${yy}" text-anchor="end" dominant-baseline="middle">${shortMoney(v)}</text>`,
    );
  }
  const ticks = [...new Set([1, 8, 15, 22, n])].filter((d) => d >= 1 && d <= n);
  for (const d of ticks) {
    out.push(`<text class="axis" x="${x(d).toFixed(1)}" y="${H - 6}" text-anchor="middle">${d}</text>`);
  }
  let segment: string[] = [];
  const flush = () => {
    if (segment.length > 1) {
      out.push(
        `<polyline fill="none" stroke="${CHART_COLORS.actual}" stroke-width="2" stroke-linejoin="round" points="${segment.join(" ")}" />`,
      );
    } else if (segment.length === 1) {
      const [cx, cy] = segment[0].split(",");
      out.push(`<circle cx="${cx}" cy="${cy}" r="2" fill="${CHART_COLORS.actual}" />`);
    }
    segment = [];
  };
  for (const p of points) {
    if (p.actualUSD === null) flush();
    else segment.push(pt(p.day, p.actualUSD));
  }
  flush();
  const projected = points.filter((p) => p.projectedUSD !== null);
  if (projected.length > 1) {
    out.push(
      `<polyline fill="none" stroke="${CHART_COLORS.projected}" stroke-width="2" stroke-dasharray="4 4" points="${projected
        .map((p) => pt(p.day, p.projectedUSD ?? 0))
        .join(" ")}" />`,
    );
  }
  const last = projected[projected.length - 1];
  if (last && last.projectedUSD !== null) {
    out.push(
      `<circle cx="${x(last.day).toFixed(1)}" cy="${y(last.projectedUSD).toFixed(1)}" r="4" fill="${CHART_COLORS.projected}" />`,
    );
  }
  const today = points.find((p) => p.isToday && p.actualUSD !== null);
  if (today && today.actualUSD !== null) {
    out.push(
      `<circle cx="${x(today.day).toFixed(1)}" cy="${y(today.actualUSD).toFixed(1)}" r="4" fill="${CHART_COLORS.today}" />`,
    );
  }
  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Month-to-date work spend">${out.join("")}</svg>`;
}

function spendView(st: AppState): string {
  const parts = [noticeHtml(), `<h2 class="page-title">Month-to-date spend</h2>`];
  if (!st.combined) {
    parts.push(
      `<div class="note">Work spend shows once Claude, Cursor (work), or ChatGPT (work credits) has data.</div>`,
    );
  } else {
    parts.push(
      metricsHtml([
        ["Today", money(st.combined.todayUSD)],
        ["Month to date", money(st.combined.monthUSD)],
        ["Projected month-end", money(st.combined.projectedUSD)],
      ]),
    );
    if (st.chart.length > 0) {
      parts.push(`<div class="chart">${chartSvg(st.chart)}</div>`);
      parts.push(`<div class="legend">
        <span><span class="swatch" style="background:${CHART_COLORS.actual}"></span>Recorded month to date</span>
        <span><span class="swatch" style="background:${CHART_COLORS.projected}"></span>Projected to month-end</span>
        <span><span class="swatch" style="background:${CHART_COLORS.today}"></span>Today</span>
      </div>`);
    }
  }
  const rows: [string, string][] = orderedSources(st)
    .filter((s) => s.enabled && s.monthUSD !== undefined)
    .map((s) => {
      const label = s.id === "openai" ? `${s.name} (not in work total)` : s.name;
      const today = s.todayUSD !== undefined ? money(s.todayUSD) : "pending";
      return [label, `${today} today · ${money(s.monthUSD ?? 0)} month`];
    });
  if (rows.length > 0) parts.push(`<div><h3>By source</h3>${rowsHtml(rows)}</div>`);
  return parts.join("");
}

function sourceView(st: AppState, id: SourceId): string {
  const s = st.sources.find((x) => x.id === id);
  if (!s) return `<div class="note err">Unknown source.</div>`;
  const parts = [noticeHtml()];
  parts.push(`<div class="card-head detail-head">
    ${providerMark(s.id, 28)}
    <div>
      <h2>${escapeHtml(s.name)}</h2>
      <span class="badge">${escapeHtml(accountLabel(s.id, s.account))}</span>
    </div>
    <span class="spacer"></span>
    <span class="status-line ${s.status}">${STATUS_LABEL[s.status]}${s.fetchedAt ? ` · ${escapeHtml(clockTime(s.fetchedAt))}` : ""}</span>
  </div>`);
  parts.push(`<div class="form-row">${togglesHtml(s)}<span class="spacer"></span>${accountSelectHtml(s)}</div>`);
  if (s.credential) parts.push(`<div class="note">${escapeHtml(s.credential)}</div>`);
  if (s.enabled) {
    const figs: [string, string][] = [];
    if (s.todayUSD !== undefined) figs.push(["Today", money(s.todayUSD)]);
    if (s.monthUSD !== undefined) figs.push(["Month to date", money(s.monthUSD)]);
    if (s.projectedUSD !== undefined) figs.push(["Projected month-end", money(s.projectedUSD)]);
    if (figs.length > 0) parts.push(metricsHtml(figs));
    const meters = metersHtml(s);
    if (meters) parts.push(`<div class="card">${meters}</div>`);
    if (s.message) {
      parts.push(`<div class="note ${s.status === "error" ? "err" : "warn"}">${escapeHtml(s.message)}</div>`);
    }
    if (s.lines.length > 0) {
      parts.push(`<div><h3>Details</h3>${rowsHtml(s.lines.map((l) => [l.label, l.value]))}</div>`);
    }
  } else {
    parts.push(`<div class="muted">Off. Turn on Enable to start reading it.</div>`);
  }
  if (id === "openai" && !st.openAIKeyConfigured) {
    parts.push(
      `<div class="form-row"><button class="btn primary" data-act="go" data-route="settings:openai">Add OpenAI Admin key…</button></div>`,
    );
  }
  parts.push(
    `<div class="form-row"><button class="btn" data-act="go" data-route="settings:${id}">Provider options</button></div>`,
  );
  return parts.join("");
}

function efficiencyView(st: AppState): string {
  const claude = st.sources.find((s) => s.id === "claude");
  const on = claude?.enabled === true;
  return `${noticeHtml()}
    <h2 class="page-title">Efficiency</h2>
    <p class="muted">Claude Code local analysis · estimates only.</p>
    ${
      on
        ? `<div class="card stub">
            <div class="stub-title">Scoreboard not wired in this build</div>
            <p class="muted">Session scoring, streaks, and badges ship with the Efficiency engine. Open the Scoreboard tab for the full shell, or use Claude provider options.</p>
            <button class="btn" data-act="go" data-route="source:claude">Claude provider options</button>
          </div>`
        : `<div class="card stub">
            <div class="stub-title">Efficiency needs Claude</div>
            <p class="muted">Turn on Claude and let local sessions accumulate, then scores appear here.</p>
            <button class="btn primary" data-act="go" data-route="source:claude">Claude provider options</button>
          </div>`
    }`;
}

function scoreboardView(st: AppState): string {
  const claude = st.sources.find((s) => s.id === "claude");
  const on = claude?.enabled === true;
  return `${noticeHtml()}
    <h2 class="page-title">Efficiency Scoreboard</h2>
    <p class="muted">Claude Code local analysis · estimate disclaimer.</p>
    <div class="metrics">
      <div class="metric stub-metric"><div class="k">Efficiency grade</div><div class="v cyan">—</div><div class="muted">/100</div></div>
      <div class="metric stub-metric"><div class="k">Current streak</div><div class="v">—</div><div class="muted">days ≥80</div></div>
    </div>
    <div class="card stub">
      <div class="stub-title">${on ? "No scored sessions yet" : "Claude is off"}</div>
      <p class="muted">${
        on
          ? "Model fit, context discipline, and cost hygiene rows appear once local Claude Code sessions are analyzed."
          : "Enable Claude to unlock the scoreboard."
      }</p>
      <button class="btn" data-act="go" data-route="source:claude">Claude provider options</button>
    </div>
    <h3>Badges</h3>
    <div class="badge-grid">
      ${["Cache Master", "Sonnet Saver", "Right Model", "Lean Context", "7-Day Streak", "30-Day Streak", "Personal Best"]
        .map((b) => `<div class="achieve off"><span class="ach-mark">○</span>${escapeHtml(b)}</div>`)
        .join("")}
    </div>`;
}

function alertsView(): string {
  return `${noticeHtml()}
    <h2 class="page-title">Alerts</h2>
    <div class="card stub empty-alerts">
      <div class="stub-title">No advisories this session.</div>
      <p class="muted">Allowance and model-spend advisories show here when they fire.</p>
    </div>`;
}

function optionsView(st: AppState): string {
  const p = st.prefs;
  const parts = [noticeHtml(), `<h2 class="page-title">Display &amp; options</h2>`];

  const refreshOpts = REFRESH_CHOICES.map(
    (m) => `<option value="${m}" ${m === p.refreshMinutes ? "selected" : ""}>${m} minutes</option>`,
  ).join("");
  parts.push(`<div class="opt-section"><h3>Check usage every</h3><div class="card">
    <div class="form-row">
      <select data-act="refresh-minutes" aria-label="Refresh interval">${refreshOpts}</select>
    </div>
  </div></div>`);

  parts.push(`<div class="opt-section"><h3>Menu bar</h3><div class="card">
    <label class="toggle"><input type="checkbox" data-act="themed-logos" ${p.themedProviderLogos ? "checked" : ""} /> Themed provider logos</label>
    <label class="toggle"><input type="checkbox" data-act="dark-bar" ${p.darkBarBackground ? "checked" : ""} /> Dark menu-bar background</label>
    <label class="toggle"><input type="checkbox" data-act="spend-colors" ${p.spendColorsEnabled ? "checked" : ""} /> Spend colors</label>
    <label class="toggle"><input type="checkbox" data-act="pastel-bar" ${p.pastelBarColors ? "checked" : ""} ${p.spendColorsEnabled ? "" : "disabled"} /> Pastel menu-bar colors</label>
    <label class="toggle"><input type="checkbox" data-act="login" ${p.openAtLogin ? "checked" : ""} /> Open at login</label>
  </div></div>`);

  parts.push(`<div class="opt-section"><h3>Providers</h3><div class="muted" style="margin-bottom:6px">Each provider has its own Enable, Show in Menu, account mode, and menu-bar style.</div>`);
  for (const s of orderedSources(st)) {
    const mode =
      s.accounts.length > 1 ? ` · ${s.account === "work" ? "Work" : "Personal"}` : "";
    const style = barDesignTitle(st.prefs.sources[s.id].barDesign);
    parts.push(`<button class="card opt-source provider-btn" data-act="go" data-route="settings:${s.id}">
      <div class="card-head">
        ${providerMark(s.id, 20)}
        <div class="card-titles">
          <span class="name">${escapeHtml(s.name)}${escapeHtml(mode)}</span>
          <span class="muted">${s.enabled ? "On" : "Off"} · ${escapeHtml(style)}</span>
        </div>
        <span class="spacer"></span>
        <span class="link">Configure ›</span>
      </div>
    </button>`);
  }
  parts.push(`</div>`);

  const resetArmed = Date.now() < resetArmedUntil;
  parts.push(`<div class="opt-section"><h3>Data</h3><div class="card">
    <div class="form-row">
      <span class="muted" style="flex:1;overflow-wrap:anywhere">${escapeHtml(st.dataDir)}</span>
      <button class="btn" data-act="open-data">Open folder</button>
    </div>
    <div class="form-row">
      <button class="btn danger" data-act="reset">${resetArmed ? "Click again to reset" : "Reset to defaults…"}</button>
      <span class="muted">Clears layout and visibility. Saved API keys are kept.</span>
    </div>
  </div></div>`);

  parts.push(`<div class="muted">TokenPulse ${escapeHtml(st.version)} · ${escapeHtml(st.platform)}</div>`);
  return parts.join("");
}

function settingsView(st: AppState, id: SourceId): string {
  const s = st.sources.find((x) => x.id === id);
  if (!s) return `<div class="note err">Unknown source.</div>`;
  const sp = st.prefs.sources[id];
  // Prefer account-based: work spend sources only get divider/stack (Swift spendCompatible).
  const spendStyleOnly =
    id === "openai" || ((id === "cursor" || id === "claude" || id === "chatgpt") && s.account === "work");
  const allowed = barDesignsFor(spendStyleOnly);

  const parts = [
    noticeHtml(),
    `<div class="card-head detail-head">
      ${providerMark(s.id, 28)}
      <div><h2>${escapeHtml(s.name)} · options</h2>
      <span class="badge">${escapeHtml(accountLabel(s.id, s.account))}</span></div>
    </div>`,
    `<div class="card">${togglesHtml(s)}</div>`,
  ];

  if (s.accounts.length > 1) {
    parts.push(`<div class="opt-section"><h3>Account</h3><div class="card">${accountSelectHtml(s)}</div></div>`);
  }

  if (spendStyleOnly) {
    parts.push(`<div class="opt-section"><h3>Menu bar figures</h3><div class="card">
      <label class="toggle"><input type="checkbox" data-act="daily-bar" data-id="${id}" ${sp.showDailyInBar ? "checked" : ""} /> Show daily in menu bar</label>
      <label class="toggle"><input type="checkbox" data-act="monthly-bar" data-id="${id}" ${sp.showMonthlyInBar ? "checked" : ""} /> Show monthly in menu bar</label>
    </div></div>`);
  }

  const designRows = allowed
    .map(
      (d) => `<label class="toggle design-choice">
        <input type="radio" name="bar-design-${id}" data-act="bar-design" data-id="${id}" value="${d.id}" ${sp.barDesign === d.id ? "checked" : ""} />
        ${escapeHtml(`${d.number} · ${d.name}`)}
      </label>`,
    )
    .join("");
  parts.push(`<div class="opt-section"><h3>Menu bar style</h3><div class="card design-list">${designRows}</div></div>`);

  if (id === "cursor" && s.account === "personal") {
    parts.push(`<div class="opt-section"><h3>Pro allowance</h3><div class="card">
      <div class="form-row">
        <input type="number" id="opt-allowance" min="1" step="1" value="${st.prefs.cursorPersonalAllowanceUSD}" />
        <button class="btn" data-act="save-allowance">Save</button>
      </div>
    </div></div>`);
  }

  if (id === "openai") {
    const keyBlock = st.openAIKeyConfigured
      ? `<div class="form-row">
          <span class="status-line ok">Admin key saved.</span>
          <span class="spacer"></span>
          <button class="btn danger" data-act="delete-key" ${busy ? "disabled" : ""}>Remove key</button>
        </div>`
      : `<div class="form-row">
          <input type="password" id="opt-key" placeholder="sk-admin-…" autocomplete="off" spellcheck="false" />
          <button class="btn primary" data-act="save-key" ${busy ? "disabled" : ""}>Save and test</button>
        </div>
        <div class="muted">Organization Admin key from OpenAI Platform.
          <button class="link" data-act="open-url" data-url="https://platform.openai.com/settings/organization/admin-keys">Open OpenAI Platform</button></div>`;
    const bal = st.prefs.openAIBalance;
    parts.push(`<div class="opt-section"><h3>Admin API</h3><div class="card">
      ${keyBlock}
      <div class="form-row">
        <span>Current prepaid balance</span>
        <input type="number" id="opt-balance" min="0" step="0.01" placeholder="0.00" value="${bal ? bal.enteredUSD : ""}" />
        <button class="btn" data-act="set-balance">Set</button>
        ${bal ? `<button class="btn" data-act="clear-balance">Clear</button>` : ""}
      </div>
    </div></div>`);
  }

  if (id === "grokbot") {
    parts.push(`<div class="note">Needs Cursor login (same account as Grok Bot).</div>`);
  }

  parts.push(
    `<div class="form-row"><button class="btn" data-act="go" data-route="source:${id}">View live data ›</button></div>`,
  );
  return parts.join("");
}

// ---------- render ----------

function isNestedRoute(): boolean {
  return (
    route.startsWith("source:") ||
    route.startsWith("settings:") ||
    route === "options" ||
    route === "spend"
  );
}

function renderHeader(st: AppState): void {
  el.spinner.classList.toggle("hidden", !st.refreshing);
  el.refresh.disabled = st.refreshing;
  const on = st.sources.filter((s) => s.enabled).length;
  el.updated.textContent = st.updatedAt
    ? `Updated ${clockTime(st.updatedAt)} · ${on} of ${st.sources.length} sources on`
    : "Connecting to your sources…";
  el.back.hidden = !isNestedRoute();
}

function renderTabs(): void {
  document.querySelectorAll<HTMLButtonElement>(".tab").forEach((t) => {
    t.classList.toggle("active", t.dataset.route === route);
  });
}

function renderChips(st: AppState): void {
  if (!st.combined) {
    el.chips.innerHTML = "";
    return;
  }
  const active = route === "spend" ? " active" : "";
  const chip = (k: string, v: number) =>
    `<button class="chip${active}" data-act="go" data-route="spend"><span class="k">${k}</span><span class="v">${money(v)}</span></button>`;
  el.chips.innerHTML =
    chip("Today", st.combined.todayUSD) +
    chip("Month", st.combined.monthUSD) +
    chip("Proj. eom", st.combined.projectedUSD);
}

function renderSidebar(st: AppState): void {
  el.sidebar.innerHTML = orderedSources(st)
    .map((s) => {
      const r = `source:${s.id}` as Route;
      const selected = route === r;
      return `<button class="side-item${selected ? " active" : ""}" data-act="go" data-route="${r}">
        ${providerMark(s.id, 16)}
        <span>${escapeHtml(s.name)}</span>
        <span class="dot ${s.status}"></span>
      </button>`;
    })
    .join("");
}

function renderFoot(st: AppState): void {
  el.footLeft.textContent = st.updatedAt
    ? `Updated ${clockTime(st.updatedAt)} · v${st.version}`
    : `v${st.version} · refresh every ${st.prefs.refreshMinutes} min`;
}

function editingInContent(): boolean {
  const a = document.activeElement;
  return a instanceof HTMLInputElement && el.inner.contains(a) && a.type !== "checkbox";
}

function renderContent(st: AppState): void {
  pendingContent = false;
  let html: string;
  if (route === "overview") html = overviewView(st);
  else if (route === "spend") html = spendView(st);
  else if (route === "efficiency") html = efficiencyView(st);
  else if (route === "scoreboard") html = scoreboardView(st);
  else if (route === "alerts") html = alertsView();
  else if (route === "options") html = optionsView(st);
  else if (route.startsWith("settings:")) html = settingsView(st, route.slice("settings:".length) as SourceId);
  else html = sourceView(st, route.slice("source:".length) as SourceId);
  el.inner.innerHTML = html;
  if (focusKeyInput) {
    focusKeyInput = false;
    byId<HTMLInputElement>("opt-key")?.focus();
  }
}

function render(force = false): void {
  if (!state) return;
  renderHeader(state);
  renderTabs();
  renderChips(state);
  renderSidebar(state);
  renderFoot(state);
  if (!force && editingInContent()) pendingContent = true;
  else renderContent(state);
  requestFit();
}

function requestFit(): void {
  requestAnimationFrame(() => {
    const chrome = el.top.offsetHeight + el.tabbar.offsetHeight + el.foot.offsetHeight;
    void api.fitHeight(chrome + el.inner.offsetHeight);
  });
}

async function load(force = false): Promise<void> {
  state = await api.getState();
  render(force);
}

function go(next: Route): void {
  if (next !== route) notice = null;
  route = next;
  if (
    next === "overview" ||
    next === "spend" ||
    next === "efficiency" ||
    next === "scoreboard" ||
    next === "alerts" ||
    next === "options"
  ) {
    lastMainRoute = next;
  }
  el.content.scrollTop = 0;
  render(true);
}

function setNotice(res: ActionResult, fallback: string): void {
  if (res.ok) notice = res.message ? { kind: "ok", text: res.message } : null;
  else notice = { kind: "err", text: res.message ?? fallback };
}

// ---------- actions ----------

async function setSource(id: SourceId, patch: Partial<SourcePrefs>): Promise<void> {
  const res = await api.setSource(id, patch);
  if (!res.ok && res.message === "needs-key") {
    notice = {
      kind: "warn",
      text: "OpenAI needs an organization Admin key (sk-admin-…). Paste it below. Saving turns the source on.",
    };
    route = "settings:openai";
    lastMainRoute = "options";
    focusKeyInput = true;
  } else if (!res.ok) {
    setNotice(res, "Could not update that source.");
  }
  await load(true);
}

function inputValue(id: string): string {
  return byId<HTMLInputElement>(id)?.value.trim() ?? "";
}

async function runAction(act: string, target: HTMLElement): Promise<void> {
  switch (act) {
    case "go":
      go((target.dataset.route ?? "overview") as Route);
      return;
    case "refresh":
      await api.refresh();
      await load(true);
      return;
    case "save-allowance": {
      const usd = Number(inputValue("opt-allowance"));
      if (!Number.isFinite(usd) || usd <= 0) {
        notice = { kind: "err", text: "Enter an allowance above $0." };
      } else {
        setNotice(await api.setPrefs({ cursorPersonalAllowanceUSD: usd }), "Could not save the allowance.");
        if (notice === null) notice = { kind: "ok", text: `Cursor allowance set to ${money(usd)}.` };
      }
      await load(true);
      return;
    }
    case "save-key": {
      const key = inputValue("opt-key");
      if (!key) {
        notice = { kind: "err", text: "Paste an Admin key first." };
        render(true);
        return;
      }
      busy = true;
      notice = { kind: "warn", text: "Checking the key against the OpenAI Costs API…" };
      render(true);
      try {
        setNotice(await api.saveOpenAIKey(key), "Could not save the key.");
      } finally {
        busy = false;
      }
      await load(true);
      return;
    }
    case "delete-key":
      setNotice(await api.deleteOpenAIKey(), "Could not remove the key.");
      await load(true);
      return;
    case "set-balance": {
      const raw = inputValue("opt-balance");
      const usd = Number(raw);
      if (raw === "" || !Number.isFinite(usd) || usd < 0) {
        notice = { kind: "err", text: "Enter a dollar amount." };
      } else {
        setNotice(await api.setOpenAIBalance(usd), "Could not save the balance.");
        if (notice === null) notice = { kind: "ok", text: `Prepaid balance set to ${money(usd)}.` };
      }
      await load(true);
      return;
    }
    case "clear-balance":
      setNotice(await api.setOpenAIBalance(null), "Could not clear the balance.");
      await load(true);
      return;
    case "open-data":
      await api.openDataDir();
      return;
    case "open-url":
      if (target.dataset.url) await api.openExternal(target.dataset.url);
      return;
    case "reset":
      if (Date.now() < resetArmedUntil) {
        resetArmedUntil = 0;
        setNotice(await api.resetPrefs(), "Could not reset.");
        if (notice === null) notice = { kind: "ok", text: "Preferences reset. Saved keys were kept." };
        await load(true);
      } else {
        resetArmedUntil = Date.now() + RESET_CONFIRM_MS;
        render(true);
        setTimeout(() => {
          if (Date.now() >= resetArmedUntil && route === "options") render();
        }, RESET_CONFIRM_MS + 50);
      }
      return;
  }
}

async function runChange(act: string, target: HTMLInputElement | HTMLSelectElement): Promise<void> {
  const id = target.dataset.id as SourceId | undefined;
  switch (act) {
    case "enable":
      if (id) await setSource(id, { enabled: (target as HTMLInputElement).checked });
      return;
    case "tray":
      if (id) await setSource(id, { showInTray: (target as HTMLInputElement).checked });
      return;
    case "account":
      if (id) await setSource(id, { account: target.value as AccountMode });
      return;
    case "refresh-minutes":
      await api.setPrefs({ refreshMinutes: Number(target.value) });
      await load(true);
      return;
    case "login":
      await api.setPrefs({ openAtLogin: (target as HTMLInputElement).checked });
      await load(true);
      return;
    case "themed-logos":
      await api.setPrefs({ themedProviderLogos: (target as HTMLInputElement).checked });
      await load(true);
      return;
    case "dark-bar":
      await api.setPrefs({ darkBarBackground: (target as HTMLInputElement).checked });
      await load(true);
      return;
    case "spend-colors":
      await api.setPrefs({ spendColorsEnabled: (target as HTMLInputElement).checked });
      await load(true);
      return;
    case "pastel-bar":
      await api.setPrefs({ pastelBarColors: (target as HTMLInputElement).checked });
      await load(true);
      return;
    case "daily-bar":
      if (id) await setSource(id, { showDailyInBar: (target as HTMLInputElement).checked });
      return;
    case "monthly-bar":
      if (id) await setSource(id, { showMonthlyInBar: (target as HTMLInputElement).checked });
      return;
    case "bar-design":
      if (id) await setSource(id, { barDesign: target.value as BarDesign });
      return;
  }
}

// ---------- wiring ----------

document.addEventListener("click", (e) => {
  const target = (e.target as HTMLElement).closest<HTMLElement>("[data-act]");
  if (!target || target instanceof HTMLInputElement || target instanceof HTMLSelectElement) return;
  const act = target.dataset.act;
  if (act) void runAction(act, target);
});

document.addEventListener("change", (e) => {
  const target = e.target;
  if (!(target instanceof HTMLInputElement || target instanceof HTMLSelectElement)) return;
  const act = target.dataset.act;
  if (act) void runChange(act, target);
});

el.inner.addEventListener("focusout", (e) => {
  const next = (e as FocusEvent).relatedTarget;
  if (next instanceof Node && el.inner.contains(next)) return;
  setTimeout(() => {
    if (pendingContent && state && !editingInContent()) {
      renderContent(state);
      requestFit();
    }
  }, 0);
});

el.inner.addEventListener("keydown", (e) => {
  if (e.key !== "Enter" || !(e.target instanceof HTMLInputElement)) return;
  const byInput: Record<string, string> = {
    "opt-key": "save-key",
    "opt-balance": "set-balance",
    "opt-allowance": "save-allowance",
  };
  const act = byInput[e.target.id];
  if (act) {
    e.preventDefault();
    void runAction(act, e.target);
  }
});

document.querySelectorAll<HTMLButtonElement>(".tab").forEach((t) => {
  t.addEventListener("click", () => go((t.dataset.route ?? "overview") as Route));
});

el.refresh.addEventListener("click", () => void runAction("refresh", el.refresh));
el.options.addEventListener("click", () => go("options"));
el.back.addEventListener("click", () => {
  if (route.startsWith("settings:")) go("options");
  else if (route.startsWith("source:")) go("overview");
  else go(lastMainRoute === "options" || lastMainRoute === "spend" ? "overview" : lastMainRoute);
});
el.quit.addEventListener("click", () => void api.quit());

document.addEventListener("keydown", (e) => {
  const mod = e.metaKey || e.ctrlKey;
  if (e.key === "Escape") {
    void api.hide();
  } else if (mod && e.key.toLowerCase() === "r") {
    e.preventDefault();
    void runAction("refresh", el.refresh);
  } else if (mod && e.key === ",") {
    e.preventDefault();
    go("options");
  } else if (mod && e.key.toLowerCase() === "q") {
    e.preventDefault();
    void api.quit();
  }
});

api.onChanged(() => void load());
api.onOpened(() => {
  route = "overview";
  lastMainRoute = "overview";
  notice = null;
  el.content.scrollTop = 0;
  void load(true);
});
window.addEventListener("load", () => requestFit());

void load(true);
