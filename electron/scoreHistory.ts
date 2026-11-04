import fs from "node:fs";
import path from "node:path";
import { dayString } from "./format";
import { restrictFile } from "./fsSecure";

/** One day's efficiency snapshot. Same keys the Swift app writes to history.json. */
export interface ScoreSnapshot {
  date: string;
  score: number;
  costMTD: number;
  cacheHitPct: number;
  opusShare: number;
  modelFitPct: number;
}

function addDays(date: Date, days: number): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days);
}

/**
 * Append-one-per-day local history at
 * ~/Library/Application Support/TokenPulse/history.json.
 */
export class ScoreHistory {
  private snapshots: ScoreSnapshot[];

  constructor(readonly file: string) {
    this.snapshots = load(file);
  }

  entries(): ScoreSnapshot[] {
    return this.snapshots.map((s) => ({ ...s }));
  }

  record(snap: Omit<ScoreSnapshot, "date">, today: string = dayString()): void {
    const next: ScoreSnapshot = { date: today, ...snap };
    const prior = this.snapshots.find((s) => s.date === today);
    if (
      prior &&
      prior.score === next.score &&
      prior.costMTD === next.costMTD &&
      prior.cacheHitPct === next.cacheHitPct &&
      prior.opusShare === next.opusShare &&
      prior.modelFitPct === next.modelFitPct
    ) {
      return;
    }
    this.snapshots = this.snapshots.filter((s) => s.date !== today);
    this.snapshots.push(next);
    this.snapshots.sort((a, b) => a.date.localeCompare(b.date));
    this.persist();
  }

  personalBest(): number {
    return this.snapshots.reduce((best, s) => Math.max(best, s.score), 0);
  }

  /** Consecutive days ending today with score ≥ threshold. A missing day breaks it. */
  streak(threshold: number, today: Date = new Date()): number {
    const byDate = new Map(this.snapshots.map((s) => [s.date, s]));
    let count = 0;
    let day = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    while (true) {
      const snap = byDate.get(dayString(day));
      if (!snap || snap.score < threshold) break;
      count += 1;
      day = addDays(day, -1);
    }
    return count;
  }

  /** Today's score minus the snapshot on or before 7 days ago. 0 when there is no earlier day. */
  trend7d(today: Date = new Date()): number {
    const latest = this.snapshots[this.snapshots.length - 1];
    if (!latest) return 0;
    const target = dayString(addDays(today, -7));
    let prior: ScoreSnapshot | undefined;
    for (const snap of this.snapshots) {
      if (snap.date <= target) prior = snap;
    }
    return latest.score - (prior?.score ?? latest.score);
  }

  /** Last 30 recorded daily scores, oldest first. */
  spark(): number[] {
    return this.snapshots.slice(-30).map((s) => s.score);
  }

  private persist(): void {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.snapshots), { mode: 0o600 });
    fs.renameSync(tmp, this.file);
    restrictFile(this.file);
  }
}

function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

function load(file: string): ScoreSnapshot[] {
  try {
    const raw = JSON.parse(fs.readFileSync(file, "utf8")) as unknown;
    if (!Array.isArray(raw)) return [];
    const out: ScoreSnapshot[] = [];
    for (const row of raw) {
      if (typeof row !== "object" || row === null) continue;
      const r = row as Record<string, unknown>;
      const score = num(r.score);
      const costMTD = num(r.costMTD);
      const cacheHitPct = num(r.cacheHitPct);
      const opusShare = num(r.opusShare);
      const modelFitPct = num(r.modelFitPct);
      if (typeof r.date !== "string" || score === undefined || costMTD === undefined) continue;
      if (cacheHitPct === undefined || opusShare === undefined || modelFitPct === undefined) continue;
      out.push({
        date: r.date,
        score,
        costMTD,
        cacheHitPct,
        opusShare,
        modelFitPct,
      });
    }
    out.sort((a, b) => a.date.localeCompare(b.date));
    return out;
  } catch {
    return [];
  }
}
