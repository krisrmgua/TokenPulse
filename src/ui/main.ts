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

type MainRoute = "overview" | "spend" | "options";
type Route = MainRoute | `source:${SourceId}`;
type NoticeKind = "ok" | "warn" | "err";

/** Mirrors REFRESH_CHOICES in electron/types.ts; prefs rejects anything else. */
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

// ---------- shared fragments ----------

function noticeHtml(): string {
  if (!notice) return "";
  const cls = notice.kind === "ok" ? "note" : `note ${notice.kind}`;
  return `<div class="${cls}">${escapeHtml(notice.text)}</div>`;
}

function figuresHtml(s: SourceSnapshot): string {
  const figs: [string, number | undefined][] = [
    ["Today", s.todayUSD],
    ["Month", s.monthUSD],
    ["Proj. eom", s.projectedUSD],
  ];
  const shown = figs.filter(([, v]) => v !== undefined);
  if (shown.length === 0) return "";
  return `<div class="figures">${shown
    .map(([k, v]) => `<div class="fig"><div class="k">${k}</div><div class="v">${money(v ?? 0)}</div></div>`)
    .join("")}</div>`;
}

function meterClass(pct: number): string {
  if (pct < 20) return "low";
  if (pct < 50) return "mid";
  return "";
}

function meterHtml(m: Meter): string {
  const pct = Math.max(0, Math.min(100, Math.round(m.percentLeft)));
  const reset = m.resetAt ? ` <span class="muted">· ${escapeHtml(resetHint(m.resetAt))}</span>` : "";
  return `<div>
    <div class="meter-top"><span>${escapeHtml(m.label)}${reset}</span><span class="pct">${pct}% left</span></div>
    <div class="bar"><span class="${meterClass(pct)}" style="width:${pct}%"></span></div>
  </div>`;
}

function metersHtml(s: SourceSnapshot): string {
  if (s.meters.length === 0) return "";
  return `<div class="meters">${s.meters.map(meterHtml).join("")}</div>`;
}

function messageHtml(s: SourceSnapshot): string {
  if (!s.message) return "";
  const cls = s.status === "error" ? "msg err" : "msg";
  return `<div class="${cls}">${escapeHtml(s.message)}</div>`;
}

function placeholderHtml(s: SourceSnapshot): string {
  if (!s.enabled) return `<div class="muted">Off. Turn on Enable to start reading it.</div>`;
  if (s.status === "loading") return `<div class="muted">Loading…</div>`;
  return "";
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
    .map((a) => `<option value="${a}" ${a === s.account ? "selected" : ""}>${escapeHtml(accountLabel(s.id, a))}</option>`)
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

// ---------- views ----------

function sourceCard(s: SourceSnapshot): string {
  const cls = ["card", s.enabled ? "" : "off", s.status === "stale" ? "stale" : ""].filter(Boolean).join(" ");
  return `<article class="${cls}">
    <div class="card-head">
      <span class="dot ${s.status}"></span>
      <span class="name" data-act="go" data-route="source:${s.id}">${escapeHtml(s.name)}</span>
      <span class="badge">${escapeHtml(accountLabel(s.id, s.account))}</span>
      <span class="spacer"></span>
      <span class="status-line ${s.status}">${STATUS_LABEL[s.status]}</span>
    </div>
    ${s.enabled ? figuresHtml(s) : ""}
    ${s.enabled ? metersHtml(s) : ""}
    ${placeholderHtml(s)}
    ${s.enabled ? messageHtml(s) : ""}
    ${togglesHtml(s)}
  </article>`;
}

function overviewView(st: AppState): string {
  const parts = [noticeHtml()];
  if (st.combined) {
    parts.push(
      `<div><h3>Work spend</h3>${metricsHtml([
        ["Today", money(st.combined.todayUSD)],
        ["Month to date", money(st.combined.monthUSD)],
        ["Projected month-end", money(st.combined.projectedUSD)],
      ])}</div>`,
    );
  }
  parts.push(`<div><h3>Sources</h3><div class="grid">${st.sources.map(sourceCard).join("")}</div></div>`);
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
    out.push(`<text class="axis" x="${L - 6}" y="${yy}" text-anchor="end" dominant-baseline="middle">${shortMoney(v)}</text>`);
  }

  const ticks = [...new Set([1, 8, 15, 22, n])].filter((d) => d >= 1 && d <= n);
  for (const d of ticks) {
    out.push(`<text class="axis" x="${x(d).toFixed(1)}" y="${H - 6}" text-anchor="middle">${d}</text>`);
  }

  // Actual MTD: break the line wherever a day was never recorded.
  let segment: string[] = [];
  const flush = () => {
    if (segment.length > 1) {
      out.push(`<polyline fill="none" stroke="${CHART_COLORS.actual}" stroke-width="2" stroke-linejoin="round" points="${segment.join(" ")}" />`);
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
    out.push(`<circle cx="${x(last.day).toFixed(1)}" cy="${y(last.projectedUSD).toFixed(1)}" r="4" fill="${CHART_COLORS.projected}" />`);
  }
  const today = points.find((p) => p.isToday && p.actualUSD !== null);
  if (today && today.actualUSD !== null) {
    out.push(`<circle cx="${x(today.day).toFixed(1)}" cy="${y(today.actualUSD).toFixed(1)}" r="4" fill="${CHART_COLORS.today}" />`);
  }

  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Month-to-date work spend">${out.join("")}</svg>`;
}

function spendView(st: AppState): string {
  const parts = [noticeHtml()];
  if (!st.combined) {
    parts.push(
      `<div class="note">Work spend shows once Claude, Cursor (work), or ChatGPT (work credits) has data. Turn one on under Overview or Options.</div>`,
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
      parts.push(
        `<div class="muted">Earlier days only appear after TokenPulse has recorded them in spend-ledger.json.</div>`,
      );
    }
  }

  const rows: [string, string][] = st.sources
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
  parts.push(`<div class="card-head">
    <span class="dot ${s.status}"></span>
    <h2>${escapeHtml(s.name)}</h2>
    <span class="badge">${escapeHtml(accountLabel(s.id, s.account))}</span>
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
    if (s.status === "loading" && !s.message) parts.push(`<div class="muted">Loading…</div>`);
  } else {
    parts.push(`<div class="muted">Off. Turn on Enable to start reading it.</div>`);
  }

  if (id === "openai" && !st.openAIKeyConfigured) {
    parts.push(
      `<div class="form-row"><button class="btn primary" data-act="go" data-route="options">Add OpenAI Admin key…</button></div>`,
    );
  }
  return parts.join("");
}

function optionsView(st: AppState): string {
  const p = st.prefs;
  const parts = [noticeHtml()];

  const refreshOpts = REFRESH_CHOICES.map(
    (m) => `<option value="${m}" ${m === p.refreshMinutes ? "selected" : ""}>${m} min</option>`,
  ).join("");
  parts.push(`<div><h3>General</h3><div class="card">
    <div class="form-row">
      <span>Refresh every</span>
      <select data-act="refresh-minutes" aria-label="Refresh interval">${refreshOpts}</select>
      <span class="muted">Remote sources still wait a few minutes between network calls.</span>
    </div>
    <label class="toggle"><input type="checkbox" data-act="login" ${p.openAtLogin ? "checked" : ""} /> Open at login</label>
  </div></div>`);

  const sourceRows = st.sources
    .map(
      (s) => `<div class="row">
        <span class="k"><span class="dot ${s.status}" style="display:inline-block;margin-right:6px"></span>${escapeHtml(s.name)}</span>
        <span class="v form-row">${togglesHtml(s)}${accountSelectHtml(s)}</span>
      </div>`,
    )
    .join("");
  parts.push(`<div><h3>Sources</h3><div class="table">${sourceRows}</div></div>`);

  parts.push(`<div><h3>Cursor</h3><div class="card">
    <div class="form-row">
      <span>Personal included allowance</span>
      <input type="number" id="opt-allowance" min="1" step="1" value="${p.cursorPersonalAllowanceUSD}" />
      <button class="btn" data-act="save-allowance">Save</button>
    </div>
    <div class="muted">Used for the Personal allowance meter when Cursor does not report a plan limit.</div>
  </div></div>`);

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
      <div class="muted">Create one in OpenAI Platform under Organization → Admin keys. A normal sk-proj- key is rejected.
        <button class="link" data-act="open-url" data-url="https://platform.openai.com/settings/organization/admin-keys">Open OpenAI Platform</button></div>`;
  const bal = p.openAIBalance;
  const balanceLine = bal
    ? `<div class="muted">Entered ${money(bal.enteredUSD)} on ${escapeHtml(dateTime(bal.dayStart))}. New costs are subtracted from that.</div>`
    : `<div class="muted">Optional. Enter the prepaid balance from OpenAI Billing and TokenPulse will count it down.</div>`;
  parts.push(`<div><h3>OpenAI API</h3><div class="card">
    ${keyBlock}
    <div class="form-row">
      <span>Current prepaid balance</span>
      <input type="number" id="opt-balance" min="0" step="0.01" placeholder="0.00" value="${bal ? bal.enteredUSD : ""}" />
      <button class="btn" data-act="set-balance">Set</button>
      ${bal ? `<button class="btn" data-act="clear-balance">Clear</button>` : ""}
    </div>
    ${balanceLine}
  </div></div>`);

  const resetArmed = Date.now() < resetArmedUntil;
  parts.push(`<div><h3>Data</h3><div class="card">
    <div class="form-row">
      <span class="muted" style="flex:1;overflow-wrap:anywhere">${escapeHtml(st.dataDir)}</span>
      <button class="btn" data-act="open-data">Open folder</button>
    </div>
    <div class="form-row">
      <button class="btn danger" data-act="reset">${resetArmed ? "Click again to reset" : "Reset to defaults"}</button>
      <span class="muted">Clears source and refresh choices. Saved API keys are kept.</span>
    </div>
  </div></div>`);

  parts.push(`<div class="muted">TokenPulse ${escapeHtml(st.version)} · ${escapeHtml(st.platform)}</div>`);
  return parts.join("");
}

// ---------- render ----------

function renderHeader(st: AppState): void {
  el.spinner.classList.toggle("hidden", !st.refreshing);
  el.refresh.disabled = st.refreshing;
  const on = st.sources.filter((s) => s.enabled).length;
  el.updated.textContent = st.updatedAt
    ? `Updated ${clockTime(st.updatedAt)} · ${on} of ${st.sources.length} sources on`
    : "Connecting to your sources…";
  el.back.hidden = !route.startsWith("source:");
}

function renderTabs(): void {
  document.querySelectorAll<HTMLButtonElement>(".tab").forEach((t) => {
    t.classList.toggle("active", t.dataset.route === route);
  });
}

function renderChips(st: AppState): void {
  if (!st.combined) {
    el.chips.innerHTML = `<span class="chip waiting">No work spend yet</span>`;
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
  const item = (r: Route, label: string, dot?: SourceStatus) =>
    `<button class="side-item${route === r ? " active" : ""}" data-act="go" data-route="${r}">${
      dot ? `<span class="dot ${dot}"></span>` : ""
    }${escapeHtml(label)}</button>`;
  el.sidebar.innerHTML = [
    item("overview", "Overview"),
    ...st.sources.map((s) => item(`source:${s.id}`, s.name, s.status)),
  ].join("");
}

function renderFoot(st: AppState): void {
  el.footLeft.textContent = `v${st.version} · refresh every ${st.prefs.refreshMinutes} min`;
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
  else if (route === "options") html = optionsView(st);
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
  if (next === "overview" || next === "spend" || next === "options") lastMainRoute = next;
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
    route = "options";
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
el.back.addEventListener("click", () => go(lastMainRoute));
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
