/** Local calendar day as yyyy-MM-dd. */
export function dayString(date: Date = new Date()): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

export function startOfDay(date: Date = new Date()): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

export function startOfMonth(date: Date = new Date()): Date {
  return new Date(date.getFullYear(), date.getMonth(), 1);
}

export function endOfMonth(date: Date = new Date()): Date {
  return new Date(date.getFullYear(), date.getMonth() + 1, 1);
}

export function daysInMonth(date: Date = new Date()): number {
  return new Date(date.getFullYear(), date.getMonth() + 1, 0).getDate();
}

/** Linear month-end projection: month-to-date scaled to the full month. */
export function projectedMonthEnd(monthUSD: number, now: Date = new Date()): number {
  const day = now.getDate();
  return day > 0 ? (monthUSD * daysInMonth(now)) / day : monthUSD;
}

export function exactMoney(usd: number): string {
  return `$${usd.toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

/** Compact tray money: $4.12, $84, $1.2k. */
export function shortMoney(usd: number): string {
  const v = Math.max(0, usd);
  if (v >= 10_000) return `$${Math.round(v / 1000)}k`;
  if (v >= 1000) return `$${(v / 1000).toFixed(1)}k`;
  if (v >= 100) return `$${Math.round(v)}`;
  return `$${v.toFixed(2)}`;
}

/** Swift `Fmt.money` — menu-bar spend figures. */
export function barMoney(usd: number): string {
  const a = Math.abs(usd);
  if (a < 10) return `$${usd.toFixed(2)}`;
  if (a < 1_000) return `$${Math.round(usd)}`;
  if (a < 1_000_000) return `$${(usd / 1_000).toFixed(1)}k`;
  return `$${(usd / 1_000_000).toFixed(1)}M`;
}

/** Compact token counts: 940, 44k, 808k, 1.2M. Matches Swift `Fmt.tokens`. */
export function formatTokens(v: number): string {
  const a = Math.abs(v);
  if (a < 1_000) return `${Math.round(v)}`;
  if (a < 1_000_000) return `${Math.round(v / 1_000)}k`;
  return `${(v / 1_000_000).toFixed(1)}M`;
}

export function clampPercent(value: number): number {
  return Math.max(0, Math.min(100, Math.round(value)));
}

export function percentLeftFromUsed(used: number): number {
  return clampPercent(100 - used);
}

/** `Nov 3` style date for reset hints. */
export function shortDate(date: Date): string {
  return date.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

export function displayDateTime(date: Date): string {
  return date.toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

/**
 * Swift `ChatGPTUsageParse.displayDate` — Today/Tomorrow lead; else calendar form.
 * e.g. `Today at 9:43 PM MST`, `Tomorrow at 1:57 AM MST`, `Nov 7, 2026 at 2:58 PM MST`.
 */
export function displayDate(date: Date, now: Date = new Date()): string {
  const startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const startDate = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const dayDelta = Math.round((startDate.getTime() - startToday.getTime()) / 86_400_000);
  const time = date.toLocaleTimeString("en-US", {
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  });
  if (dayDelta === 0) return `Today at ${time}`;
  if (dayDelta === 1) return `Tomorrow at ${time}`;
  const cal = date.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
  return `${cal} at ${time}`;
}

/** First instant of next calendar month (Swift month-end reset for work Claude). */
export function startOfNextMonth(now: Date = new Date()): Date {
  return new Date(now.getFullYear(), now.getMonth() + 1, 1);
}

/** Tray fragment for one allowance window: `64%`, or `0% Nov 9` when exhausted. */
export function barPercent(percentLeft: number, resetAt?: Date): string {
  if (percentLeft === 0 && resetAt) return `0% ${shortDate(resetAt)}`;
  return `${percentLeft}%`;
}

export function numberField(obj: Record<string, unknown>, key: string): number {
  const v = obj[key];
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

export function optionalNumber(
  obj: Record<string, unknown>,
  key: string,
): number | undefined {
  const v = obj[key];
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "") {
    const n = Number(v);
    return Number.isFinite(n) ? n : undefined;
  }
  return undefined;
}

export function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
