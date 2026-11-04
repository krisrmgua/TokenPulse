import { barDesignsFor, type BarDesign } from "../../electron/barDesign";
import { displayDate } from "../../electron/format";
import {
  POLICY_CAP,
  tintBalanceUSD,
  tintCombinedSpendUSD,
  tintRemainingPct,
  tintSpendUSD,
} from "../../electron/spendTint";
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
  openNotificationSettings: () => Promise<void>;
  sendTestNotification: () => Promise<ActionResult>;
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
type Route = MainRoute | "notifications" | `source:${SourceId}` | `settings:${SourceId}`;
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

/** Compact dollars — matches Swift `Fmt.money` used on overview cards. */
function compactMoney(usd: number): string {
  const a = Math.abs(usd);
  if (a < 10) return `$${usd.toFixed(2)}`;
  if (a < 1_000) return `$${Math.round(usd)}`;
  if (a < 1_000_000) return `$${(usd / 1_000).toFixed(1)}k`;
  return `$${(usd / 1_000_000).toFixed(1)}M`;
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

/** Meter reset line — same Today/Tomorrow rules as Swift. */
function displayReset(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "Reset time unavailable";
  return displayDate(date);
}

function rgbCss(rgb: [number, number, number]): string {
  return `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})`;
}

/** In-app spend/remaining tints — always bright; tray forces pastel separately. */
function appTintPrefs(prefs: Prefs): Prefs {
  return { ...prefs, pastelBarColors: false };
}

function meterShortLabel(label: string): string {
  if (label === "5-hour" || label === "5-hour window") return "5H";
  if (label === "Weekly" || label === "Weekly window") return "Weekly";
  if (label.startsWith("Included")) return "Left";
  return label.length > 8 ? "Left" : label;
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

/** Overview card subtitle — matches Swift `providerSubtitle`. */
function providerSubtitle(s: SourceSnapshot): string {
  switch (s.id) {
    case "chatgpt":
      return s.account === "personal" ? "5-hour / weekly allowances" : "Work credits · planning estimate";
    case "cursor":
      return s.account === "personal" ? "Included Pro allowance" : "Work spend · today / month";
    case "claude":
      return s.account === "personal" ? "5-hour / weekly allowances" : "Work spend · today / month";
    case "grokbot":
      return "Weekly allowance";
    default:
      return "Estimated prepaid balance";
  }
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

function meterHtml(m: Meter, prefs: Prefs): string {
  const pct = Math.max(0, Math.min(100, Math.round(m.percentLeft)));
  const tint = rgbCss(tintRemainingPct(pct, appTintPrefs(prefs)));
  const reset = m.resetAt ? displayReset(m.resetAt) : "Reset time unavailable";
  const fill = Math.max(0, Math.min(100, pct));
  return `<div class="meter">
    <div class="meter-row">
      <span class="meter-label">${escapeHtml(meterShortLabel(m.label))}</span>
      <div class="bar"><span style="width:${fill}%"></span></div>
      <span class="pct" style="color:${tint}">${pct}%</span>
    </div>
    <div class="meter-reset">Resets ${escapeHtml(reset)}</div>
  </div>`;
}

function metersHtml(s: SourceSnapshot, prefs: Prefs): string {
  if (s.meters.length === 0) return "";
  return `<div class="meters">${s.meters.map((m) => meterHtml(m, prefs)).join("")}</div>`;
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

/** Cyan Mission-style menu control (Account / Menu bar style). */
function settingsMenuSelect(
  act: string,
  id: SourceId,
  aria: string,
  options: { value: string; label: string; selected: boolean }[],
): string {
  const opts = options
    .map(
      (o) =>
        `<option value="${escapeHtml(o.value)}" ${o.selected ? "selected" : ""}>${escapeHtml(o.label)}</option>`,
    )
    .join("");
  return `<select class="settings-menu" data-act="${act}" data-id="${id}" aria-label="${escapeHtml(aria)}">${opts}</select>`;
}

function rowsHtml(rows: [string, string][]): string {
  if (rows.length === 0) return "";
  return `<div class="table">${rows
    .map(([k, v]) => `<div class="row"><span class="k">${escapeHtml(k)}</span><span class="v">${escapeHtml(v)}</span></div>`)
    .join("")}</div>`;
}

function metricsHtml(items: [string, string, string?][]): string {
  return `<div class="metrics">${items
    .map(([k, v, color]) => {
      const style = color ? ` style="color:${color}"` : "";
      return `<div class="metric"><div class="k">${escapeHtml(k)}</div><div class="v"${style}>${escapeHtml(v)}</div></div>`;
    })
    .join("")}</div>`;
}

function spendHeadline(s: SourceSnapshot, prefs: Prefs): string {
  // OpenAI overview shows the prepaid balance alone (Swift `headline`).
  if (s.id === "openai") {
    const bal = s.lines.find((l) => l.label === "Estimated prepaid balance");
    if (bal) {
      const n = Number(bal.value.replace(/[$,]/g, ""));
      const tint =
        Number.isFinite(n) && prefs.spendColorsEnabled
          ? rgbCss(tintBalanceUSD(n, appTintPrefs(prefs)))
          : "";
      const shown = Number.isFinite(n) ? compactMoney(n) : bal.value;
      return `<div class="spend-headline"${tint ? ` style="color:${tint}"` : ""}>${escapeHtml(shown)}</div>`;
    }
  }
  if (s.todayUSD === undefined && s.monthUSD === undefined) {
    return `<div class="spend-headline muted">No current data</div>`;
  }
  const bits: string[] = [];
  if (s.todayUSD !== undefined) bits.push(`Today ${compactMoney(s.todayUSD)}`);
  if (s.monthUSD !== undefined) bits.push(`Month ${compactMoney(s.monthUSD)}`);
  const tintUsd = s.monthUSD ?? s.todayUSD ?? 0;
  const tint =
    prefs.spendColorsEnabled && (POLICY_CAP[s.id] ?? 0) > 0
      ? rgbCss(
          tintSpendUSD(
            tintUsd,
            s.id,
            appTintPrefs(prefs),
            s.monthUSD !== undefined ? "month" : "day",
          ),
        )
      : "";
  return `<div class="spend-headline"${tint ? ` style="color:${tint}"` : ""}>${escapeHtml(bits.join(" · "))}</div>`;
}

// ---------- views ----------

function sourceCard(
  s: SourceSnapshot,
  prefs: Prefs,
  opts: { expand?: boolean } = {},
): string {
  if (!s.enabled) {
    return `<article class="card off compact" data-act="go" data-route="source:${s.id}">
      <div class="card-head">
        ${providerMark(s.id, 18)}
        <span class="name">${escapeHtml(s.name)}</span>
        <span class="spacer"></span>
        <span class="status-line">Disabled</span>
      </div>
    </article>`;
  }
  const body =
    s.meters.length > 0
      ? metersHtml(s, prefs)
      : spendHeadline(s, prefs) +
        (s.resetNote ? `<div class="reset-note">${escapeHtml(s.resetNote)}</div>` : "");
  const detailsLabel =
    s.status === "stale"
      ? "Last received data · refresh delayed"
      : s.id === "openai"
        ? "Estimated balance / reported spend ›"
        : "View details ›";
  const expand = opts.expand ? " card-expand" : "";
  return `<article class="card${expand}${s.status === "stale" ? " stale" : ""}">
    <div class="card-head">
      ${providerMark(s.id, 20)}
      <div class="card-titles">
        <span class="name" data-act="go" data-route="source:${s.id}">${escapeHtml(s.name)}</span>
        <span class="subtitle">${escapeHtml(providerSubtitle(s))}</span>
      </div>
      <span class="spacer"></span>
      <span class="status-line ${s.status}">${STATUS_LABEL[s.status]}</span>
    </div>
    <div class="card-body">
      ${body}
      ${s.message ? `<div class="msg${s.status === "error" ? " err" : ""}">${escapeHtml(s.message)}</div>` : ""}
      <button class="link details${s.status === "stale" ? " stale" : ""}" data-act="go" data-route="source:${s.id}">${detailsLabel}</button>
    </div>
  </article>`;
}

/** Pair providers into rows of two (Swift `providerPairRows`). */
function pairRowsHtml(cards: string[]): string {
  const rows: string[] = [];
  for (let i = 0; i < cards.length; i += 2) {
    const pair = cards.slice(i, i + 2);
    if (pair.length === 1) {
      rows.push(`<div class="grid grid-single">${pair[0]}</div>`);
    } else {
      rows.push(`<div class="grid">${pair.join("")}</div>`);
    }
  }
  return rows.join("");
}

/**
 * Overview layout — Swift `providerOverviewGrid` rules:
 * 1. Enabled providers pair left-to-right (2 per row).
 * 2. If one enabled is left over, it sits alone on the left and grows to the
 *    height of the right column (`expandVertically`).
 * 3. At most 3 disabled cards stack in that right column (besideCap = 3).
 * 4. Remaining disabled cards pair on rows below (a single leftover is full width).
 */
function overviewView(st: AppState): string {
  const parts = [noticeHtml()];
  const sources = orderedSources(st);
  const enabled = sources.filter((s) => s.enabled);
  const disabled = sources.filter((s) => !s.enabled);
  const prefs = st.prefs;

  const pairedEnabled = enabled.slice(0, enabled.length - (enabled.length % 2));
  const loneEnabled = enabled.length % 2 === 1 ? enabled[enabled.length - 1] : undefined;
  // Swift MissionControl.besideCap — keeps the live card from stretching with a tall stack.
  const besideCap = 3;
  const besideDisabled = loneEnabled ? disabled.slice(0, besideCap) : [];
  const overflowDisabled = loneEnabled ? disabled.slice(besideCap) : disabled;

  if (pairedEnabled.length > 0) {
    parts.push(pairRowsHtml(pairedEnabled.map((s) => sourceCard(s, prefs))));
  }
  if (loneEnabled) {
    const right =
      besideDisabled.length === 0
        ? `<div class="overview-spacer"></div>`
        : `<div class="disabled-stack">${besideDisabled.map((s) => sourceCard(s, prefs)).join("")}</div>`;
    // `card-expand` = Swift expandVertically: true — fill the row next to the stack.
    parts.push(
      `<div class="overview-row">${sourceCard(loneEnabled, prefs, { expand: true })}${right}</div>`,
    );
  }
  if (overflowDisabled.length > 0) {
    parts.push(pairRowsHtml(overflowDisabled.map((s) => sourceCard(s, prefs))));
  }

  parts.push(
    `<div class="foot-note muted">Allowances, estimated balances, and spend remain separate.</div>`,
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
    const prefs = st.prefs;
    const sources = st.sources;
    const tintPrefs = appTintPrefs(prefs);
    const dayTint = rgbCss(tintCombinedSpendUSD(st.combined.todayUSD, "day", sources, tintPrefs));
    const monthTint = rgbCss(tintCombinedSpendUSD(st.combined.monthUSD, "month", sources, tintPrefs));
    const projTint = rgbCss(
      tintCombinedSpendUSD(st.combined.projectedUSD, "month", sources, tintPrefs),
    );
    parts.push(
      metricsHtml([
        ["Today", money(st.combined.todayUSD), dayTint],
        ["Month", money(st.combined.monthUSD), monthTint],
        ["Proj. eom", money(st.combined.projectedUSD), projTint],
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

/** Swift-style provider prefs: switches + cyan menus (not checkboxes/radios). */
function providerOptionsPanel(st: AppState, id: SourceId, s: SourceSnapshot): string {
  const sp = st.prefs.sources[id];
  const spendStyleOnly =
    id === "openai" ||
    ((id === "cursor" || id === "claude" || id === "chatgpt") && s.account === "work");
  const allowed = barDesignsFor(spendStyleOnly);
  const rows: string[] = [
    switchRow("enable", "Enable", s.enabled, false, `data-id="${id}"`),
    switchRow(
      "tray",
      "Show in menu bar",
      s.showInTray,
      !s.enabled,
      `data-id="${id}"`,
    ),
  ];

  if (s.accounts.length > 1) {
    rows.push(`<div class="settings-row">
      <span class="settings-label">Account</span>
      ${settingsMenuSelect(
        "account",
        id,
        `${s.name} account`,
        s.accounts.map((a) => ({
          value: a,
          label: accountLabel(s.id, a),
          selected: a === s.account,
        })),
      )}
    </div>`);
  }

  rows.push(`<div class="settings-row">
    <span class="settings-label">Menu bar style</span>
    ${settingsMenuSelect(
      "bar-design",
      id,
      "Menu bar style",
      allowed.map((d) => ({
        value: d.id,
        label: `${d.number} · ${d.name}`,
        selected: sp.barDesign === d.id,
      })),
    )}
  </div>`);

  if (spendStyleOnly) {
    rows.push(
      switchRow(
        "daily-bar",
        "Show daily in menu bar",
        sp.showDailyInBar,
        false,
        `data-id="${id}"`,
      ),
      switchRow(
        "monthly-bar",
        "Show monthly in menu bar",
        sp.showMonthlyInBar,
        false,
        `data-id="${id}"`,
      ),
    );
  }

  const extras: string[] = [];
  if (id === "cursor" && s.account === "personal") {
    extras.push(`<div class="opt-section"><h3>Pro allowance</h3><div class="card">
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
    extras.push(`<div class="opt-section"><h3>Admin API</h3><div class="card">
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
    extras.push(`<div class="note">Needs Cursor login (same account as Grok Bot).</div>`);
  }

  return `<div class="settings-panel provider-opts">${rows.join("")}</div>${extras.join("")}`;
}

function sourceView(st: AppState, id: SourceId): string {
  const s = st.sources.find((x) => x.id === id);
  if (!s) return `<div class="note err">Unknown source.</div>`;
  const parts = [noticeHtml()];
  parts.push(`<div class="card-head detail-head">
    ${providerMark(s.id, 36)}
    <div>
      <h2>${escapeHtml(s.name)}</h2>
      <span class="badge">${escapeHtml(accountLabel(s.id, s.account))}</span>
    </div>
    <span class="spacer"></span>
    <span class="status-line ${s.status}">${STATUS_LABEL[s.status]}${s.fetchedAt ? ` · ${escapeHtml(clockTime(s.fetchedAt))}` : ""}</span>
  </div>`);
  if (s.enabled) {
    const figs: [string, string][] = [];
    if (s.todayUSD !== undefined) figs.push(["Today", money(s.todayUSD)]);
    if (s.monthUSD !== undefined) figs.push(["Month to date", money(s.monthUSD)]);
    if (figs.length > 0) parts.push(metricsHtml(figs));
    const meters = metersHtml(s, st.prefs);
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
  parts.push(providerOptionsPanel(st, id, s));
  if (s.credential) parts.push(`<div class="note">${escapeHtml(s.credential)}</div>`);
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
            <p class="muted">Session scoring, streaks, and badges ship with the Efficiency engine. Open the Scoreboard tab for the full shell, or open Claude.</p>
            <button class="btn" data-act="go" data-route="source:claude">Open Claude</button>
          </div>`
        : `<div class="card stub">
            <div class="stub-title">Efficiency needs Claude</div>
            <p class="muted">Turn on Claude and let local sessions accumulate, then scores appear here.</p>
            <button class="btn primary" data-act="go" data-route="source:claude">Open Claude</button>
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
      <button class="btn" data-act="go" data-route="source:claude">Open Claude</button>
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

function osNotificationStatus(): { label: string; detail: string } {
  const plat = state?.platform ?? "";
  const label = plat === "darwin" ? "macOS notifications" : plat === "win32" ? "Windows notifications" : "System notifications";
  if (typeof Notification === "undefined") {
    return { label, detail: "not available" };
  }
  if (Notification.permission === "granted") {
    return { label, detail: "enabled" };
  }
  if (Notification.permission === "denied") {
    return { label, detail: "blocked — open notification settings" };
  }
  return { label, detail: "not enabled — open notification settings" };
}

/** Swift Options → Notifications prefs (not the Alerts advisories tab). */
function notificationsView(st: AppState): string {
  const p = st.prefs;
  const threshOn = p.notificationsEnabled && p.allowanceAlertsEnabled;
  const thresholds = p.alertThresholds
    .map((t) => {
      const on = !p.disabledAlertThresholds.includes(t);
      return switchRow(
        "alert-threshold",
        `At ${t}% remaining`,
        on,
        !threshOn,
        `data-threshold="${t}"`,
      );
    })
    .join("");
  const os = osNotificationStatus();
  const settingsLabel =
    st.platform === "darwin"
      ? "Open macOS notification settings"
      : st.platform === "win32"
        ? "Open Windows notification settings"
        : "Open notification settings";

  return `${noticeHtml()}
    <h2 class="page-title">Notifications</h2>
    <div class="settings-panel">
      ${switchRow("notif-enable", "Enable notifications", p.notificationsEnabled)}
      ${switchRow("notif-allowance", "Low allowance alerts", p.allowanceAlertsEnabled, !p.notificationsEnabled)}
      ${thresholds}
      <div class="settings-row action-row">
        <button type="button" class="mission-btn" data-act="customize-thresholds">Customize thresholds…</button>
      </div>
      <div class="settings-sep"></div>
      ${switchRow("notif-opus", "Claude model-spend advisories", p.opusAlertsEnabled, !p.notificationsEnabled)}
      ${switchRow("notif-sounds", "Notification sounds", p.notificationSounds, !p.notificationsEnabled)}
      <div class="settings-sep"></div>
      <div class="settings-row status-row">
        <span class="settings-muted">${escapeHtml(os.label)}</span>
        <span class="settings-status ${os.detail === "enabled" ? "ok" : "bad"}">${escapeHtml(os.detail)}</span>
      </div>
      <div class="settings-row action-row stacked">
        <button type="button" class="mission-btn" data-act="test-notification">Send test notification</button>
        <button type="button" class="mission-btn" data-act="open-notif-settings">${escapeHtml(settingsLabel)}</button>
      </div>
    </div>`;
}

function switchRow(
  act: string,
  title: string,
  on: boolean,
  disabled = false,
  extraAttrs = "",
): string {
  return `<label class="settings-row switch-row${disabled ? " disabled" : ""}">
    <span class="settings-label">${escapeHtml(title)}</span>
    <input type="checkbox" class="switch" data-act="${act}" ${extraAttrs} ${on ? "checked" : ""} ${disabled ? "disabled" : ""} />
  </label>`;
}

function optionsView(st: AppState): string {
  const p = st.prefs;
  const resetArmed = Date.now() < resetArmedUntil;
  const refreshOpts = REFRESH_CHOICES.map((m) => {
    const label = m === 1 ? "1 minute" : `${m} minutes`;
    return `<option value="${m}" ${m === p.refreshMinutes ? "selected" : ""}>${label}</option>`;
  }).join("");
  const sourceChips = orderedSources(st)
    .map(
      (s) =>
        `<button type="button" class="mission-btn" data-act="go" data-route="source:${s.id}">${escapeHtml(s.name)}</button>`,
    )
    .join("");

  return `${noticeHtml()}
    <h2 class="page-title">Display &amp; options</h2>
    <p class="page-sub">Display, accounts, and per-source thresholds</p>
    <div class="settings-panel">
      <div class="settings-row">
        <span class="settings-label">Check</span>
        <select class="settings-menu" data-act="refresh-minutes" aria-label="Check interval">${refreshOpts}</select>
      </div>
      <button type="button" class="settings-row nav-row" data-act="go" data-route="notifications">
        <span class="settings-label">Notifications</span>
        <span class="settings-chevron" aria-hidden="true">›</span>
      </button>
      ${switchRow("login", "Open at login", p.openAtLogin)}
      ${switchRow("themed-logos", "Themed provider logos", p.themedProviderLogos)}
      ${switchRow("spend-colors", "Spend colors", p.spendColorsEnabled)}
      ${switchRow("dark-bar", "Dark menu-bar background", p.darkBarBackground)}
      ${switchRow("pastel-bar", "Pastel menu-bar colors", p.pastelBarColors, !p.spendColorsEnabled)}
      ${switchRow("remember-place", "Reopen where I left off", p.rememberPanelPlace)}
    </div>
    <div class="opt-section sources-block">
      <h3 class="sources-title">Sources</h3>
      <div class="source-chips">${sourceChips}</div>
    </div>
    <div class="note-panel">Pastel requires spend colors. Efficiency uses local Claude Code sessions in personal or work mode.</div>
    <div class="opt-actions">
      <button type="button" class="mission-btn" data-act="reset">${resetArmed ? "Click again to reset" : "Reset to defaults…"}</button>
      <button type="button" class="mission-btn" data-act="open-data">Open data folder</button>
    </div>
    <div class="muted foot-meta">TokenPulse ${escapeHtml(st.version)} · ${escapeHtml(st.platform)}</div>`;
}

/** Legacy `settings:` routes fold into the provider page. */
function settingsView(st: AppState, id: SourceId): string {
  return sourceView(st, id);
}

// ---------- render ----------

function isNestedRoute(): boolean {
  return (
    route.startsWith("source:") ||
    route.startsWith("settings:") ||
    route === "options" ||
    route === "notifications" ||
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
  const tintPrefs = appTintPrefs(st.prefs);
  const sources = st.sources;
  const chip = (k: string, v: number, kind: "day" | "month") => {
    const color = rgbCss(tintCombinedSpendUSD(v, kind, sources, tintPrefs));
    return `<button class="chip${active}" data-act="go" data-route="spend"><span class="k">${k}</span><span class="v" style="color:${color}">${money(v)}</span></button>`;
  };
  el.chips.innerHTML =
    chip("Today", st.combined.todayUSD, "day") +
    chip("Month", st.combined.monthUSD, "month") +
    chip("Proj. eom", st.combined.projectedUSD, "month");
}

function renderSidebar(st: AppState): void {
  el.sidebar.innerHTML = orderedSources(st)
    .map((s) => {
      const r = `source:${s.id}` as Route;
      const selected = route === r;
      return `<button class="side-item${selected ? " active" : ""}" data-act="go" data-route="${r}">
        ${providerMark(s.id, 24)}
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
  else if (route === "notifications") html = notificationsView(st);
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
    route = "source:openai";
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
    case "customize-thresholds": {
      const current = (state?.prefs.alertThresholds ?? [15, 10, 5]).join(", ");
      const raw = window.prompt(
        "Enter 1–10 percent-left levels between 1 and 99, separated by commas. Each level alerts once per provider window until it resets or recovers.",
        current,
      );
      if (raw === null) return;
      const parts = raw
        .replaceAll("%", "")
        .split(/[,;\s]+/)
        .map((p) => p.trim())
        .filter(Boolean);
      if (parts.length === 0 || parts.length > 10 || parts.some((p) => !/^\d+$/.test(p))) {
        notice = { kind: "err", text: "Use whole percentages from 1 to 99, for example 15, 10, 5." };
        render(true);
        return;
      }
      const values = [...new Set(parts.map(Number))]
        .filter((n) => n >= 1 && n <= 99)
        .sort((a, b) => b - a);
      if (values.length !== parts.length) {
        notice = { kind: "err", text: "Use whole percentages from 1 to 99, for example 15, 10, 5." };
        render(true);
        return;
      }
      await api.setPrefs({ alertThresholds: values, disabledAlertThresholds: [] });
      notice = { kind: "ok", text: `Thresholds set to ${values.join(", ")}%.` };
      await load(true);
      return;
    }
    case "test-notification":
      setNotice(await api.sendTestNotification(), "Could not send a test notification.");
      render(true);
      return;
    case "open-notif-settings":
      await api.openNotificationSettings();
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
    case "remember-place":
      await api.setPrefs({ rememberPanelPlace: (target as HTMLInputElement).checked });
      await load(true);
      return;
    case "notif-enable":
      await api.setPrefs({ notificationsEnabled: (target as HTMLInputElement).checked });
      await load(true);
      return;
    case "notif-allowance":
      await api.setPrefs({ allowanceAlertsEnabled: (target as HTMLInputElement).checked });
      await load(true);
      return;
    case "notif-opus":
      await api.setPrefs({ opusAlertsEnabled: (target as HTMLInputElement).checked });
      await load(true);
      return;
    case "notif-sounds":
      await api.setPrefs({ notificationSounds: (target as HTMLInputElement).checked });
      await load(true);
      return;
    case "alert-threshold": {
      const threshold = Number(target.dataset.threshold);
      if (!Number.isFinite(threshold) || !state) return;
      const disabled = new Set(state.prefs.disabledAlertThresholds);
      if ((target as HTMLInputElement).checked) disabled.delete(threshold);
      else disabled.add(threshold);
      await api.setPrefs({ disabledAlertThresholds: [...disabled] });
      await load(true);
      return;
    }
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
  if (route === "notifications") go("options");
  else if (route.startsWith("settings:") || route.startsWith("source:")) go("overview");
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
  const remember = state?.prefs.rememberPanelPlace === true;
  if (!remember) {
    route = "overview";
    lastMainRoute = "overview";
  }
  notice = null;
  el.content.scrollTop = 0;
  void load(true);
});
window.addEventListener("load", () => requestFit());

void load(true);
