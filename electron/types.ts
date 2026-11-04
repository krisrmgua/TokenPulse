import type { BarDesign } from "./barDesign";

export type SourceId = "claude" | "cursor" | "chatgpt" | "openai" | "grokbot";
export type AccountMode = "work" | "personal";
export type { BarDesign };

export const SOURCE_IDS: SourceId[] = [
  "claude",
  "cursor",
  "chatgpt",
  "openai",
  "grokbot",
];

/** Swift menu-bar / Mission Control provider order. */
export const PROVIDER_ORDER: SourceId[] = [
  "chatgpt",
  "cursor",
  "grokbot",
  "openai",
  "claude",
];

export const SOURCE_NAMES: Record<SourceId, string> = {
  claude: "Claude",
  cursor: "Cursor",
  chatgpt: "ChatGPT",
  openai: "OpenAI API",
  grokbot: "Grok Bot",
};

/** Account modes each source supports. A single entry means no picker. */
export const SOURCE_ACCOUNTS: Record<SourceId, AccountMode[]> = {
  claude: ["work"],
  cursor: ["work", "personal"],
  chatgpt: ["personal", "work"],
  openai: ["work"],
  grokbot: ["personal"],
};

export interface SourcePrefs {
  enabled: boolean;
  showInTray: boolean;
  account: AccountMode;
  /** Per-provider capsule layout (Swift Menu bar style). */
  barDesign: BarDesign;
  /** Work spend: show D in the menu bar. */
  showDailyInBar: boolean;
  /** Work spend: show M in the menu bar. */
  showMonthlyInBar: boolean;
}

export interface OpenAIBalanceBaseline {
  enteredUSD: number;
  /** ISO timestamp of local start-of-day when the balance was entered. */
  dayStart: string;
  spendAlreadyReportedUSD: number;
}

export interface Prefs {
  version: 1;
  sources: Record<SourceId, SourcePrefs>;
  refreshMinutes: number;
  cursorPersonalAllowanceUSD: number;
  openAtLogin: boolean;
  openAIBalance?: OpenAIBalanceBaseline;
  /** Cyan-on-navy provider tiles (Swift themedProviderLogos). */
  themedProviderLogos: boolean;
  /** Draw navy capsules behind each provider block. */
  darkBarBackground: boolean;
  /** Tint spend / remaining figures by threshold. */
  spendColorsEnabled: boolean;
  /** Soften hot colors in the menu bar. */
  pastelBarColors: boolean;
}

export const REFRESH_CHOICES = [1, 2, 3, 5, 10, 15, 30];

export interface Meter {
  id: string;
  label: string;
  percentLeft: number;
  resetAt?: string;
}

export interface DetailLine {
  label: string;
  value: string;
}

export type SourceStatus = "off" | "loading" | "ok" | "stale" | "error";

export interface SourceSnapshot {
  id: SourceId;
  name: string;
  enabled: boolean;
  showInTray: boolean;
  account: AccountMode;
  accounts: AccountMode[];
  status: SourceStatus;
  message?: string;
  fetchedAt?: string;
  todayUSD?: number;
  monthUSD?: number;
  projectedUSD?: number;
  meters: Meter[];
  lines: DetailLine[];
  /** Overview reset line under spend (Swift `resetNote`). */
  resetNote?: string;
  /** Short tray fragment, e.g. `CU $2.10/$84`. */
  barText?: string;
  /** Where the credential comes from on this machine. */
  credential: string;
}

export interface ChartPoint {
  day: number;
  date: string;
  actualUSD: number | null;
  projectedUSD: number | null;
  isToday: boolean;
}

export interface CombinedSpend {
  todayUSD: number;
  monthUSD: number;
  projectedUSD: number;
}

export interface AppState {
  sources: SourceSnapshot[];
  combined: CombinedSpend | null;
  chart: ChartPoint[];
  prefs: Prefs;
  refreshing: boolean;
  updatedAt?: string;
  platform: string;
  openAIKeyConfigured: boolean;
  dataDir: string;
  version: string;
  /** data:image/png icons for the panel (themed per prefs). */
  icons: Record<SourceId, string>;
}

export interface ActionResult {
  ok: boolean;
  message?: string;
}
