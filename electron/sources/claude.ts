import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { projectedMonthEnd, startOfMonth } from "../format";
import type { Pricing } from "../pricing";

export interface UsageRecord {
  ts: number;
  model: string;
  input: number;
  cacheWrite: number;
  cacheRead: number;
  output: number;
  sessionId: string;
  /** tool_use blocks in this assistant message. Lightweight Opus turns have none. */
  toolUseCount: number;
  dedupeKey: string;
}

/** Task label for a session. Stays on this machine. */
export interface SessionMeta {
  cwd: string;
  firstPrompt: string;
}

export interface ClaudeScan {
  records: UsageRecord[];
  sessions: Record<string, SessionMeta>;
}

export interface ClaudeRollup {
  todayUSD: number;
  monthUSD: number;
  projectedUSD: number;
  byModelUSD: Record<string, number>;
  opusUSD: number;
  sessions: number;
  cacheHitPct: number;
  filesScanned: number;
  roots: string[];
}

/**
 * Transcript roots. `~/.claude/projects` is `%USERPROFILE%\.claude\projects`
 * on Windows because os.homedir() resolves USERPROFILE there.
 */
export function claudeProjectRoots(): string[] {
  const home = os.homedir();
  const candidates = [
    process.env.CLAUDE_CONFIG_DIR
      ? path.join(process.env.CLAUDE_CONFIG_DIR, "projects")
      : undefined,
    path.join(home, ".claude", "projects"),
    path.join(process.env.XDG_CONFIG_HOME ?? path.join(home, ".config"), "claude", "projects"),
  ].filter((p): p is string => Boolean(p));
  const seen = new Set<string>();
  return candidates.filter((p) => {
    const key = path.resolve(p);
    if (seen.has(key)) return false;
    seen.add(key);
    return fs.existsSync(key);
  });
}

function intField(obj: Record<string, unknown>, key: string): number {
  const v = obj[key];
  return typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : 0;
}

/** One assistant message's usage, or undefined for anything else. */
export function parseTranscriptLine(obj: unknown): UsageRecord | undefined {
  if (typeof obj !== "object" || obj === null) return undefined;
  const line = obj as Record<string, unknown>;
  const message = line.message as Record<string, unknown> | undefined;
  if (!message || typeof message !== "object") return undefined;
  const usage = message.usage as Record<string, unknown> | undefined;
  if (!usage || typeof usage !== "object") return undefined;

  const input = intField(usage, "input_tokens");
  const cacheWrite = intField(usage, "cache_creation_input_tokens");
  const cacheRead = intField(usage, "cache_read_input_tokens");
  const output = intField(usage, "output_tokens");
  if (input === 0 && cacheWrite === 0 && cacheRead === 0 && output === 0) {
    return undefined;
  }
  const parsed = Date.parse(typeof line.timestamp === "string" ? line.timestamp : "");
  const messageId = typeof message.id === "string" ? message.id : randomUUID();
  const requestId = typeof line.requestId === "string" ? line.requestId : "";
  return {
    ts: Number.isFinite(parsed) ? parsed : Date.now(),
    model: typeof message.model === "string" ? message.model : "unknown",
    input,
    cacheWrite,
    cacheRead,
    output,
    sessionId: typeof line.sessionId === "string" ? line.sessionId : "",
    toolUseCount: countToolUses(message),
    dedupeKey: `${messageId}:${requestId}`,
  };
}

function countToolUses(message: Record<string, unknown>): number {
  const content = message.content;
  if (!Array.isArray(content)) return 0;
  let n = 0;
  for (const block of content) {
    if (typeof block === "object" && block !== null && (block as { type?: unknown }).type === "tool_use") {
      n += 1;
    }
  }
  return n;
}

/** First plain-text user prompt, matching the Swift transcript parser. */
export function userPromptText(line: Record<string, unknown>): string {
  const message = line.message;
  if (typeof message !== "object" || message === null) return "";
  const content = (message as Record<string, unknown>).content;
  if (typeof content === "string") return content.trim();
  if (!Array.isArray(content)) return "";
  for (const block of content) {
    if (typeof block !== "object" || block === null) continue;
    const b = block as Record<string, unknown>;
    if (b.type === "text" && typeof b.text === "string") return b.text.trim();
  }
  return "";
}

export function absorbSessionMeta(line: Record<string, unknown>, sessions: Map<string, SessionMeta>): void {
  const sessionId = typeof line.sessionId === "string" ? line.sessionId : "";
  if (!sessionId) return;
  const meta = sessions.get(sessionId) ?? { cwd: "", firstPrompt: "" };
  if (!meta.cwd && typeof line.cwd === "string") meta.cwd = line.cwd;
  if (!meta.firstPrompt && line.type === "user") {
    const text = userPromptText(line);
    if (text) meta.firstPrompt = text.slice(0, 120);
  }
  sessions.set(sessionId, meta);
}

interface FileCacheEntry {
  mtimeMs: number;
  size: number;
  records: UsageRecord[];
  sessions: Record<string, SessionMeta>;
}

/**
 * Scans Claude Code transcripts for this month's assistant usage. Files are
 * re-parsed only when their size or mtime changes, and files last written
 * before the month started are skipped.
 */
export class ClaudeTranscriptScanner {
  private cache = new Map<string, FileCacheEntry>();
  private scan: ClaudeScan = { records: [], sessions: {} };

  constructor(private readonly pricing: Pricing) {}

  /** Deduped records and session labels from the latest rollup. */
  lastScan(): ClaudeScan {
    return this.scan;
  }

  async rollup(now: Date = new Date()): Promise<ClaudeRollup> {
    const roots = claudeProjectRoots();
    const monthStart = startOfMonth(now).getTime();
    const files: { file: string; stat: fs.Stats }[] = [];
    for (const root of roots) await walk(root, files, monthStart);

    const live = new Set<string>();
    const records: UsageRecord[] = [];
    const sessions = new Map<string, SessionMeta>();
    for (const { file, stat } of files) {
      live.add(file);
      let entry = this.cache.get(file);
      if (!entry || entry.mtimeMs !== stat.mtimeMs || entry.size !== stat.size) {
        entry = { mtimeMs: stat.mtimeMs, size: stat.size, ...(await parseFile(file)) };
        this.cache.set(file, entry);
      }
      records.push(...entry.records);
      for (const [id, meta] of Object.entries(entry.sessions)) {
        const cur = sessions.get(id) ?? { cwd: "", firstPrompt: "" };
        if (!cur.cwd && meta.cwd) cur.cwd = meta.cwd;
        if (!cur.firstPrompt && meta.firstPrompt) cur.firstPrompt = meta.firstPrompt;
        sessions.set(id, cur);
      }
    }
    for (const key of this.cache.keys()) if (!live.has(key)) this.cache.delete(key);

    const seen = new Set<string>();
    const unique: UsageRecord[] = [];
    for (const rec of records) {
      if (seen.has(rec.dedupeKey)) continue;
      seen.add(rec.dedupeKey);
      unique.push(rec);
    }
    this.scan = { records: unique, sessions: Object.fromEntries(sessions) };
    return summarize(records, this.pricing, now, files.length, roots);
  }
}

async function walk(
  dir: string,
  out: { file: string; stat: fs.Stats }[],
  monthStart: number,
): Promise<void> {
  let entries: fs.Dirent[];
  try {
    entries = await fs.promises.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (entry.name.startsWith(".")) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await walk(full, out, monthStart);
    } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      try {
        const stat = await fs.promises.stat(full);
        if (stat.mtimeMs >= monthStart) out.push({ file: full, stat });
      } catch {
        // File vanished mid-scan.
      }
    }
  }
}

async function parseFile(file: string): Promise<{ records: UsageRecord[]; sessions: Record<string, SessionMeta> }> {
  let text: string;
  try {
    text = await fs.promises.readFile(file, "utf8");
  } catch {
    return { records: [], sessions: {} };
  }
  const records: UsageRecord[] = [];
  const sessions = new Map<string, SessionMeta>();
  for (const line of text.split("\n")) {
    if (!line.includes('"usage"') && !line.includes('"sessionId"')) continue;
    let obj: unknown;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (typeof obj !== "object" || obj === null) continue;
    const row = obj as Record<string, unknown>;
    absorbSessionMeta(row, sessions);
    if (!line.includes('"usage"')) continue;
    const rec = parseTranscriptLine(obj);
    if (rec) records.push(rec);
  }
  return { records, sessions: Object.fromEntries(sessions) };
}

export function summarize(
  records: UsageRecord[],
  pricing: Pricing,
  now: Date,
  filesScanned = 0,
  roots: string[] = [],
): ClaudeRollup {
  const monthStart = startOfMonth(now).getTime();
  const nextMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1).getTime();
  const dayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const dayEnd = dayStart + 24 * 60 * 60 * 1000;

  const seen = new Set<string>();
  const sessions = new Set<string>();
  const byModelUSD: Record<string, number> = {};
  let monthUSD = 0;
  let todayUSD = 0;
  let opusUSD = 0;
  let cacheRead = 0;
  let uncached = 0;

  for (const rec of records) {
    if (rec.ts < monthStart || rec.ts >= nextMonth) continue;
    if (seen.has(rec.dedupeKey)) continue;
    seen.add(rec.dedupeKey);
    const cost = pricing.cost(rec.input, rec.cacheWrite, rec.cacheRead, rec.output, rec.model);
    monthUSD += cost;
    byModelUSD[rec.model] = (byModelUSD[rec.model] ?? 0) + cost;
    if (rec.model.includes("opus")) opusUSD += cost;
    cacheRead += rec.cacheRead;
    uncached += rec.input + rec.cacheWrite;
    if (rec.sessionId) sessions.add(rec.sessionId);
    if (rec.ts >= dayStart && rec.ts < dayEnd) todayUSD += cost;
  }

  const cacheTotal = cacheRead + uncached;
  return {
    todayUSD,
    monthUSD,
    projectedUSD: projectedMonthEnd(monthUSD, now),
    byModelUSD,
    opusUSD,
    sessions: sessions.size,
    cacheHitPct: cacheTotal > 0 ? cacheRead / cacheTotal : 0,
    filesScanned,
    roots,
  };
}
