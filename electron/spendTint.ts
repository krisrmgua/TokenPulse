/**
 * Menu-bar spend / remaining tints — mirrors Swift SpendTint + SpendPalette.
 * Spend colors off → label ink. On → bright or pastel by level.
 */

export type RGB = [number, number, number];

export type SpendLevel = "normal" | "good" | "caution" | "warning" | "over";

/** Max-chroma hot colors (#FF0000 / #FF8000 / #FFFF00) + system-ish green. */
const BRIGHT = {
  red: [255, 0, 0] as RGB,
  orange: [255, 128, 0] as RGB,
  yellow: [255, 255, 0] as RGB,
  green: [48, 209, 88] as RGB,
};

/** Swift SpendPalette pastels. */
const PASTEL = {
  red: [255, 194, 191] as RGB,
  orange: [255, 227, 184] as RGB,
  yellow: [255, 250, 184] as RGB,
  green: [199, 245, 199] as RGB,
};

const INK: RGB = [237, 245, 255];
const CYAN: RGB = [88, 210, 236];

/** Default monthly red caps (Swift Config / ChatGPT Pro equivalent). */
export const POLICY_CAP: Record<string, number> = {
  claude: 1500,
  cursor: 1500,
  chatgpt: 200,
  openai: 1500,
  grokbot: 0,
};

/** Remaining % thresholds (Swift defaults). */
const REMAINING = { red: 10, orange: 25, yellow: 50 };

/** Spend-up orange/yellow as % of the monthly red cap. */
const SPEND_UP = { orangePercent: 75, yellowPercent: 50 };

export function levelSpendUp(
  usd: number,
  cap: number,
  orangePercent = SPEND_UP.orangePercent,
  yellowPercent = SPEND_UP.yellowPercent,
): SpendLevel {
  if (!(cap > 0)) return "normal";
  const orangeAt = (cap * orangePercent) / 100;
  const yellowAt = (cap * yellowPercent) / 100;
  if (usd >= cap) return "over";
  if (usd >= orangeAt) return "warning";
  if (usd >= yellowAt) return "caution";
  return "good";
}

export function levelRemainingDown(percentLeft: number): SpendLevel {
  if (percentLeft <= REMAINING.red) return "over";
  if (percentLeft <= REMAINING.orange) return "warning";
  if (percentLeft <= REMAINING.yellow) return "caution";
  return "good";
}

export function dailyCap(monthCap: number, now = new Date()): number {
  const days = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
  return monthCap / Math.max(1, days);
}

export function barColor(
  level: SpendLevel,
  opts: { spendColorsEnabled: boolean; pastelBarColors: boolean; themedProviderLogos?: boolean },
): RGB {
  if (!opts.spendColorsEnabled || level === "normal") {
    return opts.themedProviderLogos ? CYAN : INK;
  }
  const p = opts.pastelBarColors ? PASTEL : BRIGHT;
  switch (level) {
    case "good":
      return p.green;
    case "caution":
      return p.yellow;
    case "warning":
      return p.orange;
    case "over":
      return p.red;
  }
}

export function tintSpendUSD(
  usd: number,
  sourceId: string,
  prefs: { spendColorsEnabled: boolean; pastelBarColors: boolean; themedProviderLogos?: boolean },
  kind: "day" | "month",
): RGB {
  const cap = POLICY_CAP[sourceId] ?? 1500;
  const level =
    kind === "day"
      ? levelSpendUp(usd, dailyCap(cap))
      : levelSpendUp(usd, cap);
  return barColor(level, prefs);
}

/**
 * Swift `combinedSpendColor` — sum work-source monthly caps; Today uses the
 * day-scale of that sum, Month / Proj. eom use the full month sum.
 */
export function tintCombinedSpendUSD(
  usd: number,
  kind: "day" | "month",
  workSources: { id: string; enabled: boolean; account: string }[],
  prefs: { spendColorsEnabled: boolean; pastelBarColors: boolean; themedProviderLogos?: boolean },
  now = new Date(),
): RGB {
  if (!prefs.spendColorsEnabled) return INK;
  let cap = 0;
  for (const s of workSources) {
    if (!s.enabled || s.account !== "work") continue;
    if (s.id === "cursor" || s.id === "claude" || s.id === "chatgpt") {
      cap += POLICY_CAP[s.id] ?? 0;
    }
  }
  if (!(cap > 0)) return INK;
  const effective = kind === "day" ? dailyCap(cap, now) : cap;
  return barColor(levelSpendUp(usd, effective), prefs);
}

export function tintRemainingPct(
  percentLeft: number,
  prefs: { spendColorsEnabled: boolean; pastelBarColors: boolean; themedProviderLogos?: boolean },
): RGB {
  return barColor(levelRemainingDown(percentLeft), prefs);
}

/** OpenAI prepaid balance remaining — Swift defaults $5 / $20 / $50. */
export function tintBalanceUSD(
  usd: number,
  prefs: { spendColorsEnabled: boolean; pastelBarColors: boolean; themedProviderLogos?: boolean },
): RGB {
  const level: SpendLevel =
    usd <= 5 ? "over" : usd <= 20 ? "warning" : usd <= 50 ? "caution" : "good";
  return barColor(level, prefs);
}
