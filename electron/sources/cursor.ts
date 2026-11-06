import { SourceError, requestJSON } from "../http";
import { parseCursorPlanIdentity, type CursorPlanIdentity } from "./grokbot";
import {
  isRecord,
  numberField,
  optionalNumber,
  percentLeftFromUsed,
  startOfDay,
  startOfMonth,
} from "../format";

const BASE = "https://api2.cursor.sh";

export interface CursorUsageAgg {
  model: string;
  spendUSD: number;
  inputTokens: number;
  outputTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
}

export interface CursorPlanUsage {
  /** Positive only for a legacy dollar allowance. The shared weekly pool sends no limit. */
  limitUSD: number;
  includedSpendUSD: number;
  /** Legacy Pro/Team included dollars. False for the shared weekly X subscription. */
  dollarAllowance: boolean;
  totalPercentUsed: number;
  percentLeft: number;
  billingCycleStart?: number;
  billingCycleEnd?: number;
}

export interface CursorSpendSnapshot {
  todaySpendUSD: number;
  totalSpendUSD: number;
  byModel: CursorUsageAgg[];
  userId: number;
  planUsage?: CursorPlanUsage;
  /** From GetSandUsageStatus, e.g. Pro or Premium. */
  planName?: string;
  /** One weekly pool shared with Grok and Grok Bot. */
  unifiedWeekly: boolean;
  /** Enterprise pooled allowance (included-in-business usage). */
  pooledEnterprise?: boolean;
  /** Latest usage event timestamp from Cursor, when known. */
  lastEventAt?: number;
  fetchedAt: number;
}

export function parseAggregations(obj: unknown): CursorUsageAgg[] | undefined {
  if (!isRecord(obj) || !Array.isArray(obj.aggregations)) return undefined;
  const rows: CursorUsageAgg[] = [];
  for (const row of obj.aggregations) {
    if (!isRecord(row)) continue;
    rows.push({
      model: typeof row.modelIntent === "string" ? row.modelIntent : "unknown",
      spendUSD: numberField(row, "totalCents") / 100,
      inputTokens: numberField(row, "inputTokens"),
      outputTokens: numberField(row, "outputTokens"),
      cacheWriteTokens: numberField(row, "cacheWriteTokens"),
      cacheReadTokens: numberField(row, "cacheReadTokens"),
    });
  }
  return rows.sort((a, b) => b.spendUSD - a.spendUSD);
}

/** Charged amount (list + Cursor fee, net of discounts). Today and Month both use it. */
export function parseTotalSpendUSD(obj: unknown): number {
  return isRecord(obj) ? numberField(obj, "totalCostCents") / 100 : 0;
}

export function parsePlanUsage(obj: unknown): CursorPlanUsage | undefined {
  if (!isRecord(obj) || !isRecord(obj.planUsage)) return undefined;
  const plan = obj.planUsage;
  const limitCents = numberField(plan, "limit");
  const totalPct = optionalNumber(plan, "totalPercentUsed");
  // A zero limit with no percent is an empty payload. The shared weekly pool
  // omits the dollar limit and still sends totalPercentUsed.
  if (limitCents <= 0 && totalPct === undefined) return undefined;
  const used = totalPct ?? 0;
  const start = optionalNumber(obj, "billingCycleStart");
  const end = optionalNumber(obj, "billingCycleEnd");
  const dollarAllowance = limitCents > 0;
  return {
    limitUSD: dollarAllowance ? limitCents / 100 : 0,
    includedSpendUSD: dollarAllowance ? numberField(plan, "includedSpend") / 100 : 0,
    dollarAllowance,
    totalPercentUsed: used,
    percentLeft: percentLeftFromUsed(used),
    billingCycleStart: start && start > 0 ? start : undefined,
    billingCycleEnd: end && end > 0 ? end : undefined,
  };
}

/** Personal % left: Cursor's own plan meter when present, else month spend vs allowance. */
export function cursorPersonalPercentLeft(
  snap: CursorSpendSnapshot,
  allowanceUSD: number,
): number {
  if (snap.planUsage) return snap.planUsage.percentLeft;
  if (allowanceUSD <= 0) return 0;
  return percentLeftFromUsed((snap.totalSpendUSD / allowanceUSD) * 100);
}

function planFromIdentity(identity: CursorPlanIdentity | undefined): CursorPlanUsage | undefined {
  if (!identity || identity.usagePercent === undefined) return undefined;
  return {
    limitUSD: 0,
    includedSpendUSD: 0,
    dollarAllowance: false,
    totalPercentUsed: identity.usagePercent,
    percentLeft: percentLeftFromUsed(identity.usagePercent),
    billingCycleEnd: identity.resetAt,
  };
}

function headers(token: string, connect: boolean): Record<string, string> {
  const h: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (connect) h["Connect-Protocol-Version"] = "1";
  return h;
}

async function post(
  token: string,
  rpc: string,
  body: Record<string, unknown>,
  connect = false,
): Promise<unknown> {
  const res = await requestJSON(`${BASE}/aiserver.v1.DashboardService/${rpc}`, {
    method: "POST",
    headers: headers(token, connect),
    body,
  });
  if (res.status === 401 || res.status === 403) {
    throw new SourceError("Cursor rejected the stored login. Sign in to Cursor again.", "auth", res.status);
  }
  if (res.status !== 200) {
    throw new SourceError(`Cursor ${rpc} returned HTTP ${res.status}.`, "http", res.status);
  }
  return res.body;
}

/** Sum list-cost cents on filtered usage events (Enterprise included + on-demand). */
export function sumFilteredEventCents(obj: unknown): { cents: number; lastEventAt?: number } {
  if (!isRecord(obj) || !Array.isArray(obj.usageEventsDisplay)) return { cents: 0 };
  let cents = 0;
  let lastEventAt: number | undefined;
  for (const row of obj.usageEventsDisplay) {
    if (!isRecord(row)) continue;
    const ts = optionalNumber(row, "timestamp");
    if (ts !== undefined && (lastEventAt === undefined || ts > lastEventAt)) lastEventAt = ts;
    const usage = isRecord(row.tokenUsage) ? row.tokenUsage : undefined;
    if (usage) cents += numberField(usage, "totalCents");
  }
  return { cents, lastEventAt };
}

function sandPooledEnterprise(obj: unknown): boolean {
  return isRecord(obj) && obj.usesPooledEnterpriseAllowance === true;
}

export class CursorClient {
  private userId: number | undefined;
  private teamId: number | undefined;

  /**
   * Always scoped to the signed-in userId. Unfiltered aggregate calls return
   * team-wide totals for owners/admins, which must never feed a personal monitor.
   */
  async fetch(token: string, now: Date = new Date()): Promise<CursorSpendSnapshot> {
    const userId = await this.resolveUserId(token);
    const aggregates = (start: Date) =>
      post(token, "GetAggregatedUsageEvents", {
        userId,
        startDate: start.getTime(),
        endDate: now.getTime(),
      });

    const [month, today, period, sand] = await Promise.allSettled([
      aggregates(startOfMonth(now)),
      aggregates(startOfDay(now)),
      post(token, "GetCurrentPeriodUsage", {}, true),
      post(token, "GetSandUsageStatus", {}, true),
    ]);

    const planUsage =
      period.status === "fulfilled" ? parsePlanUsage(period.value) : undefined;
    const identity =
      sand.status === "fulfilled" ? parseCursorPlanIdentity(sand.value) : undefined;
    const pooledEnterprise =
      sand.status === "fulfilled" ? sandPooledEnterprise(sand.value) : false;
    const unifiedWeekly =
      identity?.unified === true || (planUsage != null && !planUsage.dollarAllowance);
    const monthRows =
      month.status === "fulfilled" ? parseAggregations(month.value) : undefined;

    let todaySpendUSD =
      today.status === "fulfilled" ? parseTotalSpendUSD(today.value) : 0;
    let totalSpendUSD = parseTotalSpendUSD(month.status === "fulfilled" ? month.value : undefined);
    let lastEventAt: number | undefined;

    // Enterprise included-in-business usage often omits totalCostCents on the
    // aggregate "today" window while GetFilteredUsageEvents still has rows.
    if (todaySpendUSD === 0 || pooledEnterprise) {
      const events = await this.filteredWindow(token, userId, startOfDay(now), now).catch(
        () => undefined,
      );
      if (events) {
        if (todaySpendUSD === 0 && events.cents > 0) todaySpendUSD = events.cents / 100;
        lastEventAt = events.lastEventAt;
      }
    }

    if (!monthRows) {
      if (!planUsage && !identity && totalSpendUSD <= 0) {
        const reason = month.status === "rejected" ? month.reason : undefined;
        if (reason instanceof SourceError) throw reason;
        throw new SourceError("Cursor returned an unreadable usage response.");
      }
      return {
        todaySpendUSD,
        totalSpendUSD,
        byModel: [],
        userId,
        planUsage: planUsage ?? (unifiedWeekly ? planFromIdentity(identity) : undefined),
        planName: identity?.planName,
        unifiedWeekly,
        pooledEnterprise,
        lastEventAt,
        fetchedAt: now.getTime(),
      };
    }
    return {
      todaySpendUSD,
      totalSpendUSD,
      byModel: monthRows,
      userId,
      planUsage: planUsage ?? (unifiedWeekly ? planFromIdentity(identity) : undefined),
      planName: identity?.planName,
      unifiedWeekly,
      pooledEnterprise,
      lastEventAt,
      fetchedAt: now.getTime(),
    };
  }

  private async filteredWindow(
    token: string,
    userId: number,
    start: Date,
    end: Date,
  ): Promise<{ cents: number; lastEventAt?: number } | undefined> {
    const teamId = await this.resolveTeamId(token);
    if (teamId === undefined) return undefined;
    const body = await post(token, "GetFilteredUsageEvents", {
      userId,
      teamId,
      startDate: start.getTime(),
      endDate: end.getTime(),
      pageSize: 200,
      page: 1,
    });
    return sumFilteredEventCents(body);
  }

  private async resolveUserId(token: string): Promise<number> {
    if (this.userId !== undefined) return this.userId;
    const me = await post(token, "GetMe", {});
    const id = isRecord(me) ? optionalNumber(me, "userId") : undefined;
    if (id === undefined) {
      throw new SourceError("Cursor GetMe did not return a userId.");
    }
    this.userId = id;
    return id;
  }

  private async resolveTeamId(token: string): Promise<number | undefined> {
    if (this.teamId !== undefined) return this.teamId;
    try {
      const teams = await post(token, "GetTeams", {});
      if (!isRecord(teams) || !Array.isArray(teams.teams)) return undefined;
      for (const row of teams.teams) {
        if (!isRecord(row)) continue;
        const id = optionalNumber(row, "id");
        if (id !== undefined) {
          this.teamId = id;
          return id;
        }
      }
    } catch {
      return undefined;
    }
    return undefined;
  }

  reset(): void {
    this.userId = undefined;
    this.teamId = undefined;
  }
}
