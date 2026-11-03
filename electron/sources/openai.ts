import { SourceError, requestJSON } from "../http";
import { daysInMonth, isRecord, startOfDay, startOfMonth } from "../format";
import type { OpenAIBalanceBaseline } from "../types";

const ENDPOINT = "https://api.openai.com/v1/organization/costs";
const MAX_PAGES = 20;

export interface OpenAICostLine {
  lineItem: string;
  spendUSD: number;
}

export interface OpenAISpendSnapshot {
  todaySpendUSD: number;
  monthSpendUSD: number;
  estimatedBalanceUSD?: number;
  byLineItem: OpenAICostLine[];
  fetchedAt: number;
}

interface CostResult {
  value: number;
  currency?: string;
  lineItem?: string;
}

export interface CostPage {
  results: CostResult[];
  hasMore: boolean;
  nextPage?: string;
}

export function parseCostPage(body: unknown): CostPage | undefined {
  if (!isRecord(body) || !Array.isArray(body.data)) return undefined;
  const results: CostResult[] = [];
  for (const bucket of body.data) {
    if (!isRecord(bucket) || !Array.isArray(bucket.results)) return undefined;
    for (const r of bucket.results) {
      if (!isRecord(r) || !isRecord(r.amount) || typeof r.amount.value !== "number") continue;
      results.push({
        value: r.amount.value,
        currency: typeof r.amount.currency === "string" ? r.amount.currency : undefined,
        lineItem: typeof r.line_item === "string" ? r.line_item : undefined,
      });
    }
  }
  return {
    results,
    hasMore: body.has_more === true,
    nextPage: typeof body.next_page === "string" ? body.next_page : undefined,
  };
}

function isUSD(r: CostResult): boolean {
  return r.currency === undefined || r.currency.toLowerCase() === "usd";
}

export function totalUSD(results: CostResult[]): number {
  return results.filter(isUSD).reduce((sum, r) => sum + r.value, 0);
}

export function lineItems(results: CostResult[]): OpenAICostLine[] {
  const totals = new Map<string, number>();
  for (const r of results.filter(isUSD)) {
    const key = r.lineItem ?? "Other";
    totals.set(key, (totals.get(key) ?? 0) + r.value);
  }
  return [...totals.entries()]
    .map(([lineItem, spendUSD]) => ({ lineItem, spendUSD }))
    .sort((a, b) => b.spendUSD - a.spendUSD);
}

/** Pagination cursors containing a URL, `..`, a newline, or a leading `/` are dropped. */
export function requestURL(start: Date, end: Date, limit: number, page?: string): string | undefined {
  const params = new URLSearchParams({
    start_time: String(Math.floor(start.getTime() / 1000)),
    end_time: String(Math.ceil(end.getTime() / 1000)),
    bucket_width: "1d",
    limit: String(limit),
    group_by: "line_item",
  });
  if (page !== undefined) {
    if (
      page.length > 512 ||
      page.includes("://") ||
      page.includes("..") ||
      /[\r\n]/.test(page) ||
      page.startsWith("/")
    ) {
      return undefined;
    }
    params.set("page", page);
  }
  const url = new URL(`${ENDPOINT}?${params}`);
  if (url.protocol !== "https:" || url.host !== "api.openai.com") return undefined;
  return url.toString();
}

export function estimateBalance(baseline: OpenAIBalanceBaseline, reportedSinceDayStart: number): number {
  return baseline.enteredUSD - Math.max(0, reportedSinceDayStart - baseline.spendAlreadyReportedUSD);
}

async function fetchWindow(key: string, start: Date, end: Date, limit: number): Promise<CostResult[]> {
  const all: CostResult[] = [];
  let page: string | undefined;
  for (let i = 0; i < MAX_PAGES; i++) {
    const url = requestURL(start, end, limit, page);
    if (!url) throw new SourceError("OpenAI returned an unsafe pagination cursor.");
    const res = await requestJSON(url, {
      headers: { Authorization: `Bearer ${key}` },
      timeoutMs: 20_000,
    });
    if (res.status === 401 || res.status === 403) {
      throw new SourceError("OpenAI rejected the Admin API key.", "auth", res.status);
    }
    if (res.status !== 200) {
      throw new SourceError(`OpenAI Costs API returned HTTP ${res.status}.`, "http", res.status);
    }
    const parsed = parseCostPage(res.body);
    if (!parsed) throw new SourceError("OpenAI returned an unreadable costs response.");
    all.push(...parsed.results);
    if (!parsed.hasMore) return all;
    if (!parsed.nextPage) throw new SourceError("OpenAI paginated without a next_page cursor.");
    page = parsed.nextPage;
  }
  throw new SourceError("OpenAI Costs API paginated too many times.");
}

/** Organization API costs (ChatGPT subscriptions are billed separately and never included). */
export async function fetchOpenAISpend(
  key: string,
  baseline: OpenAIBalanceBaseline | undefined,
  now: Date = new Date(),
): Promise<OpenAISpendSnapshot> {
  const dayStart = startOfDay(now);
  const monthStart = startOfMonth(now);
  const monthLimit = Math.min(180, daysInMonth(now) + 2);
  const day = await fetchWindow(key, dayStart, now, 2);
  const month = await fetchWindow(key, monthStart, now, monthLimit);

  let estimatedBalanceUSD: number | undefined;
  if (baseline) {
    const since = new Date(baseline.dayStart);
    if (!Number.isNaN(since.getTime())) {
      const elapsedDays = Math.floor((now.getTime() - since.getTime()) / 86_400_000);
      try {
        const window = await fetchWindow(key, since, now, Math.min(180, Math.max(2, elapsedDays + 2)));
        estimatedBalanceUSD = estimateBalance(baseline, totalUSD(window));
      } catch {
        // Balance is best-effort and must not hide otherwise valid costs.
        estimatedBalanceUSD = undefined;
      }
    }
  }

  return {
    todaySpendUSD: totalUSD(day),
    monthSpendUSD: totalUSD(month),
    estimatedBalanceUSD,
    byLineItem: lineItems(month),
    fetchedAt: now.getTime(),
  };
}
