import fs from "node:fs";
import path from "node:path";
import { dayString, daysInMonth, projectedMonthEnd } from "./format";
import type { ChartPoint } from "./types";
import { restrictFile } from "./fsSecure";

/** Same shape the Swift app writes, so both can share `spend-ledger.json`. */
export interface DailySpend {
  date: string;
  dayUSD: number;
  monthUSD: number;
}

const MAX_DAYS = 400;
const KEEP_DAYS = 366;

export class SpendLedger {
  private days: DailySpend[];

  constructor(readonly file: string) {
    this.days = load(file);
  }

  entries(): DailySpend[] {
    return this.days.map((d) => ({ ...d }));
  }

  /** Upsert today's combined work spend and persist. */
  record(dayUSD: number, monthUSD: number, today: string = dayString()): void {
    const entry: DailySpend = {
      date: today,
      dayUSD: Math.max(0, dayUSD),
      monthUSD: Math.max(0, monthUSD),
    };
    const prior = this.days.find((d) => d.date === today);
    if (
      prior &&
      Math.abs(prior.dayUSD - entry.dayUSD) < 0.005 &&
      Math.abs(prior.monthUSD - entry.monthUSD) < 0.005
    ) {
      return;
    }
    this.days = this.days.filter((d) => d.date !== today);
    this.days.push(entry);
    this.days.sort((a, b) => a.date.localeCompare(b.date));
    if (this.days.length > MAX_DAYS) this.days = this.days.slice(-KEEP_DAYS);
    this.persist();
  }

  /** Cumulative month-to-date line, then a straight climb from today to projected EOM. */
  monthChart(
    monthUSD: number,
    projectedUSD?: number,
    now: Date = new Date(),
  ): ChartPoint[] {
    const dayOfMonth = now.getDate();
    const total = daysInMonth(now);
    const year = now.getFullYear();
    const month = now.getMonth() + 1;
    const prefix = `${year}-${String(month).padStart(2, "0")}-`;
    const byDate = new Map(
      this.days.filter((d) => d.date.startsWith(prefix)).map((d) => [d.date, d]),
    );
    const todayKey = dayString(now);
    const eom = projectedUSD ?? projectedMonthEnd(monthUSD, now);
    const remaining = Math.max(0, total - dayOfMonth);

    const points: ChartPoint[] = [];
    for (let day = 1; day <= total; day++) {
      const key = `${prefix}${String(day).padStart(2, "0")}`;
      let actual: number | null = null;
      if (day < dayOfMonth) {
        const stored = byDate.get(key);
        actual = stored ? stored.monthUSD : null;
      } else if (day === dayOfMonth) {
        actual = monthUSD;
      }
      let projected: number | null = null;
      if (day === dayOfMonth) {
        projected = monthUSD;
      } else if (day > dayOfMonth) {
        projected =
          remaining > 0
            ? monthUSD + ((eom - monthUSD) * (day - dayOfMonth)) / remaining
            : eom;
      }
      points.push({
        day,
        date: key,
        actualUSD: actual,
        projectedUSD: projected,
        isToday: key === todayKey,
      });
    }
    return points;
  }

  private persist(): void {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.days), { mode: 0o600 });
    fs.renameSync(tmp, this.file);
    restrictFile(this.file);
  }
}

function load(file: string): DailySpend[] {
  try {
    const raw = JSON.parse(fs.readFileSync(file, "utf8")) as unknown;
    if (!Array.isArray(raw)) return [];
    return raw
      .filter(
        (d): d is DailySpend =>
          typeof d === "object" &&
          d !== null &&
          typeof (d as DailySpend).date === "string" &&
          typeof (d as DailySpend).dayUSD === "number" &&
          typeof (d as DailySpend).monthUSD === "number",
      )
      .sort((a, b) => a.date.localeCompare(b.date));
  } catch {
    return [];
  }
}
