import { SourceError, requestJSON } from "../http";
import { isRecord, optionalNumber, percentLeftFromUsed } from "../format";

export interface GrokBotSnapshot {
  percentLeft: number;
  percentUsed: number;
  resetAt?: number;
  planLabel?: string;
  cursorPlanName?: string;
  /** Same weekly pool as Cursor on the X subscription. */
  unified?: boolean;
  fetchedAt: number;
}

/** Plan identity from GetSandUsageStatus, shared by Grok Bot and Cursor. */
export interface CursorPlanIdentity {
  planName?: string;
  /** The X Subscription: one weekly pool across Cursor, Grok, and Grok Bot. */
  unified: boolean;
  usagePercent?: number;
  resetAt?: number;
}

function str(obj: Record<string, unknown>, ...keys: string[]): string | undefined {
  for (const key of keys) {
    const v = obj[key];
    if (typeof v === "string" && v.length > 0) return v;
  }
  return undefined;
}

export function isPooledEnterprise(obj: Record<string, unknown>): boolean {
  return (
    obj.usesPooledEnterpriseAllowance === true ||
    obj.uses_pooled_enterprise_allowance === true
  );
}

export function parseCursorPlanIdentity(obj: unknown): CursorPlanIdentity | undefined {
  if (!isRecord(obj)) return undefined;
  const planName = str(obj, "cursorPlanName", "cursor_plan_name");
  const brand = str(obj, "billingBrand", "billing_brand");
  const unified =
    obj.isUnified === true ||
    obj.is_unified === true ||
    (brand !== undefined && brand.includes("GROK"));
  const usagePercent = optionalNumber(obj, "usagePercent") ?? optionalNumber(obj, "usage_percent");
  const resetRaw = str(obj, "nextResetTimestampUtc", "next_reset_timestamp_utc");
  const reset = resetRaw ? Date.parse(resetRaw) : NaN;
  if (!planName && !unified && usagePercent === undefined) return undefined;
  return {
    planName,
    unified,
    usagePercent,
    resetAt: Number.isFinite(reset) ? reset : undefined,
  };
}

export function parseSandUsage(obj: unknown, now = Date.now()): GrokBotSnapshot | undefined {
  if (!isRecord(obj) || isPooledEnterprise(obj)) return undefined;
  const used = optionalNumber(obj, "usagePercent") ?? optionalNumber(obj, "usage_percent");
  if (used === undefined) return undefined;
  const resetRaw = str(obj, "nextResetTimestampUtc", "next_reset_timestamp_utc");
  const reset = resetRaw ? Date.parse(resetRaw) : NaN;
  return {
    percentLeft: percentLeftFromUsed(used),
    percentUsed: used,
    resetAt: Number.isFinite(reset) ? reset : undefined,
    planLabel: str(obj, "grokPlanLabel", "grok_plan_label"),
    cursorPlanName: str(obj, "cursorPlanName", "cursor_plan_name"),
    unified:
      obj.isUnified === true ||
      obj.is_unified === true ||
      (str(obj, "billingBrand", "billing_brand") ?? "").includes("GROK"),
    fetchedAt: now,
  };
}

/** Grok Bot weekly Sand allowance, authenticated with the same Cursor login. */
export async function fetchGrokBot(token: string): Promise<GrokBotSnapshot> {
  const res = await requestJSON(
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus",
    {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Connect-Protocol-Version": "1" },
      body: {},
    },
  );
  if (res.status === 401 || res.status === 403) {
    throw new SourceError("Cursor rejected the stored login. Sign in to Cursor again.", "auth", res.status);
  }
  if (res.status !== 200) {
    throw new SourceError(`Grok Bot usage API returned HTTP ${res.status}.`, "http", res.status);
  }
  if (isRecord(res.body) && isPooledEnterprise(res.body)) {
    throw new SourceError("Grok Bot weekly usage is hidden for pooled enterprise allowances.");
  }
  const snap = parseSandUsage(res.body);
  if (!snap) throw new SourceError("Grok Bot usage response was unreadable.");
  return snap;
}
