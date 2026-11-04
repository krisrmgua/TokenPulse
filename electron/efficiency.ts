import type { Pricing } from "./pricing";
import type { ScoreHistory } from "./scoreHistory";
import type { ClaudeRollup, SessionMeta, UsageRecord } from "./sources/claude";
import { dayString, formatTokens, startOfMonth } from "./format";
import type { ScoreboardModel } from "./types";

export interface SessionAgg {
  id: string;
  cwd: string;
  firstPrompt: string;
  turns: number;
  input: number;
  cacheWrite: number;
  cacheRead: number;
  output: number;
  toolUses: number;
  models: string[];
  totalCost: number;
  opusCost: number;
  opusAsSonnetCost: number;
  lightTurns: number;
  lightOpusCost: number;
  lightOpusAtSonnet: number;
}

export interface ModelFitOffender {
  label: string;
  reason: string;
  opusUSD: number;
  sonnetUSD: number;
  savingsUSD: number;
}

export interface ModelFit {
  rightModelPct: number;
  recoverableUSD: number;
  lightTurnShare: number;
  offenders: ModelFitOffender[];
}

export interface BloatedSession {
  label: string;
  contextPerTurn: number;
  costUSD: number;
}

export interface ContextInsights {
  contextPerTurnMedian: number;
  churn: number;
  contextCostShare: number;
  bloated: BloatedSession[];
  bigReadFlag: boolean;
  tips: string[];
}

export interface EfficiencyResult {
  score: number;
  grade: string;
  modelFitPoints: number;
  contextPoints: number;
  costPoints: number;
  modelFit: ModelFit;
  context: ContextInsights;
  cacheHitPct: number;
  topTip: string;
}

function clamp01(x: number): number {
  return Math.min(1, Math.max(0, x));
}

export function gradeFor(score: number): string {
  if (score >= 90) return "A";
  if (score >= 80) return "B";
  if (score >= 70) return "C";
  if (score >= 60) return "D";
  return "F";
}

function contextTokens(a: SessionAgg): number {
  return a.input + a.cacheWrite + a.cacheRead;
}

function contextPerTurn(a: SessionAgg): number {
  return a.turns > 0 ? contextTokens(a) / a.turns : 0;
}

export function sessionLabel(a: SessionAgg): string {
  const base = a.cwd.split(/[/\\]/).filter(Boolean).pop() ?? "";
  const project = base || "—";
  const prompt = a.firstPrompt ? `'${a.firstPrompt.slice(0, 48)}'` : "(no prompt)";
  return `${project} — ${prompt}`;
}

export function sessionAggregates(
  records: UsageRecord[],
  sessions: Record<string, SessionMeta>,
  pricing: Pricing,
  now: Date = new Date(),
): SessionAgg[] {
  const monthStart = startOfMonth(now).getTime();
  const nextMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1).getTime();
  const byId = new Map<string, SessionAgg>();

  for (const rec of records) {
    if (rec.ts < monthStart || rec.ts >= nextMonth || !rec.sessionId) continue;
    const a = byId.get(rec.sessionId) ?? {
      id: rec.sessionId,
      cwd: "",
      firstPrompt: "",
      turns: 0,
      input: 0,
      cacheWrite: 0,
      cacheRead: 0,
      output: 0,
      toolUses: 0,
      models: [],
      totalCost: 0,
      opusCost: 0,
      opusAsSonnetCost: 0,
      lightTurns: 0,
      lightOpusCost: 0,
      lightOpusAtSonnet: 0,
    };
    a.turns += 1;
    a.input += rec.input;
    a.cacheWrite += rec.cacheWrite;
    a.cacheRead += rec.cacheRead;
    a.output += rec.output;
    a.toolUses += rec.toolUseCount;
    if (!a.models.includes(rec.model)) a.models.push(rec.model);
    const cost = pricing.cost(rec.input, rec.cacheWrite, rec.cacheRead, rec.output, rec.model);
    a.totalCost += cost;
    if (rec.model.includes("opus")) {
      a.opusCost += cost;
      const asSonnet = pricing.cost(rec.input, rec.cacheWrite, rec.cacheRead, rec.output, "claude-sonnet-5");
      a.opusAsSonnetCost += asSonnet;
      if (rec.toolUseCount === 0 && rec.output < 250) {
        a.lightTurns += 1;
        a.lightOpusCost += cost;
        a.lightOpusAtSonnet += asSonnet;
      }
    }
    byId.set(rec.sessionId, a);
  }

  for (const [id, meta] of Object.entries(sessions)) {
    const a = byId.get(id);
    if (!a) continue;
    a.cwd = meta.cwd;
    a.firstPrompt = meta.firstPrompt;
  }
  return [...byId.values()];
}

export function modelFitFromAggs(aggs: SessionAgg[], monthUSD: number): ModelFit {
  let lightCost = 0;
  let recoverable = 0;
  let opusTurns = 0;
  let lightTurns = 0;
  for (const a of aggs) {
    lightCost += a.lightOpusCost;
    recoverable += Math.max(0, a.lightOpusCost - a.lightOpusAtSonnet);
    if (a.models.some((m) => m.includes("opus"))) opusTurns += a.turns;
    lightTurns += a.lightTurns;
  }
  const offenders = aggs
    .filter((a) => a.lightOpusCost - a.lightOpusAtSonnet > 0.05)
    .sort((a, b) => b.lightOpusCost - b.lightOpusAtSonnet - (a.lightOpusCost - a.lightOpusAtSonnet))
    .slice(0, 8)
    .map((a) => ({
      label: sessionLabel(a),
      reason: `${a.lightTurns} of ${a.turns} turns lightweight on Opus`,
      opusUSD: a.lightOpusCost,
      sonnetUSD: a.lightOpusAtSonnet,
      savingsUSD: Math.max(0, a.lightOpusCost - a.lightOpusAtSonnet),
    }));
  return {
    rightModelPct: monthUSD > 0 ? Math.max(0, 1 - lightCost / monthUSD) : 1,
    recoverableUSD: recoverable,
    lightTurnShare: opusTurns > 0 ? lightTurns / opusTurns : 0,
    offenders,
  };
}

export function contextFromAggs(aggs: SessionAgg[], monthUSD: number, pricing: Pricing): ContextInsights {
  const perTurns = aggs.map(contextPerTurn).filter((n) => n > 0).sort((a, b) => a - b);
  const median = perTurns.length === 0 ? 0 : perTurns[Math.floor(perTurns.length / 2)]!;
  const totalContextTok = aggs.reduce((n, a) => n + contextTokens(a), 0);
  const totalCacheWrite = aggs.reduce((n, a) => n + a.cacheWrite, 0);
  const churn = totalContextTok > 0 ? totalCacheWrite / totalContextTok : 0;
  const outputCost = aggs.reduce((n, a) => {
    const model = a.models[0] ?? "claude-opus-4-8";
    return n + pricing.cost(0, 0, 0, a.output, model);
  }, 0);
  const share = monthUSD > 0 ? Math.max(0, (monthUSD - outputCost) / monthUSD) : 0;
  const bloated = aggs
    .filter((a) => median > 0 && contextPerTurn(a) > 2 * median && a.totalCost > 0.5)
    .sort((a, b) => contextPerTurn(b) - contextPerTurn(a))
    .slice(0, 5)
    .map((a) => ({
      label: sessionLabel(a),
      contextPerTurn: contextPerTurn(a),
      costUSD: a.totalCost,
    }));
  const bigRead = aggs.some((a) => contextPerTurn(a) > 400_000);
  const tips: string[] = [];
  if (churn > 0.15) {
    tips.push("High context churn — avoid mid-session model switches and re-reading changed files.");
  }
  if (median > 120_000) {
    tips.push("Heavy context per turn — /clear between unrelated tasks and lean on compaction.");
  }
  if (bigRead) {
    tips.push("A session dumped a huge file into context — read narrower ranges or use a subagent.");
  }
  if (tips.length === 0) tips.push("Context discipline looks healthy — keep sessions scoped.");
  return {
    contextPerTurnMedian: median,
    churn,
    contextCostShare: share,
    bloated,
    bigReadFlag: bigRead,
    tips,
  };
}

export function efficiencyFrom(
  aggs: SessionAgg[],
  rollup: Pick<ClaudeRollup, "monthUSD" | "sessions" | "cacheHitPct">,
  pricing: Pricing,
): EfficiencyResult {
  const modelFit = modelFitFromAggs(aggs, rollup.monthUSD);
  const context = contextFromAggs(aggs, rollup.monthUSD, pricing);
  const modelFitPts = 50 * clamp01(modelFit.rightModelPct);
  const band = clamp01((250_000 - context.contextPerTurnMedian) / (250_000 - 60_000));
  const churnPenalty = Math.min(1, Math.max(0, context.churn - 0.1) / 0.2);
  const contextPts = Math.max(0, 35 * band - 10 * churnPenalty);
  const cps = rollup.sessions > 0 ? rollup.monthUSD / rollup.sessions : 0;
  const costPts = 15 * clamp01((50 - cps) / (50 - 8));
  const score = Math.min(100, Math.max(0, Math.round(modelFitPts + contextPts + costPts)));
  const topTip =
    modelFit.recoverableUSD > 0.25
      ? `${Math.round(modelFit.lightTurnShare * 100)}% of Opus turns were lightweight — default to Sonnet, escalate for hard work (~$${modelFit.recoverableUSD.toFixed(2)} recoverable).`
      : (context.tips[0] ?? "Efficiency looks healthy.");
  return {
    score,
    grade: gradeFor(score),
    modelFitPoints: modelFitPts,
    contextPoints: contextPts,
    costPoints: costPts,
    modelFit,
    context,
    cacheHitPct: rollup.cacheHitPct,
    topTip,
  };
}

function badges(
  eff: EfficiencyResult,
  rollup: Pick<ClaudeRollup, "monthUSD" | "opusUSD">,
  history: ScoreHistory,
  now: Date,
): ScoreboardModel["badges"] {
  const opusShare = rollup.monthUSD > 0 ? rollup.opusUSD / rollup.monthUSD : 0;
  const streak = history.streak(80, now);
  const best = history.personalBest();
  const real = rollup.monthUSD > 0;
  const pct = (n: number) => `${Math.round(n * 100)}%`;
  const tokens = (n: number) => formatTokens(n);
  return [
    {
      name: "Cache Master",
      earned: eff.cacheHitPct >= 0.9,
      detail: `≥90% cache hits (you: ${pct(eff.cacheHitPct)})`,
    },
    {
      name: "Sonnet Saver",
      earned: real && opusShare <= 0.4,
      detail: `Opus ≤40% of spend (you: ${pct(opusShare)})`,
    },
    {
      name: "Right Model",
      earned: eff.modelFit.rightModelPct >= 0.9,
      detail: `≥90% model-fit (you: ${pct(eff.modelFit.rightModelPct)})`,
    },
    {
      name: "Lean Context",
      earned: real && eff.context.contextPerTurnMedian <= 60_000,
      detail: `≤60k context/turn (you: ${tokens(eff.context.contextPerTurnMedian)})`,
    },
    {
      name: "7-Day Streak",
      earned: streak >= 7,
      detail: `7 days at score ≥80 (current: ${streak})`,
    },
    {
      name: "30-Day Streak",
      earned: streak >= 30,
      detail: "30 days at score ≥80",
    },
    {
      name: "Personal Best",
      earned: real && eff.score >= best && eff.score > 0,
      detail: `Best score yet: ${best}`,
    },
  ];
}

/** Score today's transcripts, store the day, and return the scoreboard the panel renders. */
export function buildScoreboard(args: {
  records: UsageRecord[];
  sessions: Record<string, SessionMeta>;
  rollup: ClaudeRollup;
  pricing: Pricing;
  history: ScoreHistory;
  now?: Date;
}): ScoreboardModel {
  const now = args.now ?? new Date();
  const aggs = sessionAggregates(args.records, args.sessions, args.pricing, now);
  const eff = efficiencyFrom(aggs, args.rollup, args.pricing);
  const opusShare = args.rollup.monthUSD > 0 ? args.rollup.opusUSD / args.rollup.monthUSD : 0;
  args.history.record(
    {
      score: eff.score,
      costMTD: args.rollup.monthUSD,
      cacheHitPct: eff.cacheHitPct,
      opusShare,
      modelFitPct: eff.modelFit.rightModelPct,
    },
    dayString(now),
  );
  return {
    score: eff.score,
    grade: eff.grade,
    modelFitPoints: eff.modelFitPoints,
    contextPoints: eff.contextPoints,
    costPoints: eff.costPoints,
    rightModelPct: eff.modelFit.rightModelPct,
    recoverableUSD: eff.modelFit.recoverableUSD,
    contextPerTurn: eff.context.contextPerTurnMedian,
    churn: eff.context.churn,
    contextShare: eff.context.contextCostShare,
    cacheHitPct: eff.cacheHitPct,
    offenders: eff.modelFit.offenders,
    bloated: eff.context.bloated,
    badges: badges(eff, args.rollup, args.history, now),
    sparkScores: args.history.spark(),
    streak: args.history.streak(80, now),
    best: args.history.personalBest(),
    trend: args.history.trend7d(now),
    tip: eff.topTip,
    sessions: args.rollup.sessions,
  };
}
