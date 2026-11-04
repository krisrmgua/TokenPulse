import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { SourceError } from "../http";

/** One Claude subscription window from the official CLI `/usage` view. */
export interface ClaudeUsageWindow {
  percentLeft: number;
  resetDescription: string;
}

export interface ClaudeUsageSnapshot {
  session?: ClaudeUsageWindow;
  weekly?: ClaudeUsageWindow;
  fetchedAt: number;
  claudePath: string;
}

const USAGE_TIMEOUT_MS = 28_000;

export function stripTerminalSequences(raw: string): string {
  let out = raw;
  out = out.replace(/\u001B\[[0-9]*G/g, " ");
  out = out.replace(/\u001B\[[0-9]+C/g, " ");
  out = out.replace(/\u001B\[[0-?]*[ -/]*[@-~]/g, "");
  out = out.replace(/\u001B\][^\u0007]*(?:\u0007|\u001B\\)/g, "");
  out = out.replace(/\r/g, "\n");
  while (out.includes("\u0008")) out = out.replace(/[^\n]\u0008/g, "");
  out = out.replace(/[^\S\n]+/g, " ");
  return out;
}

/** A finished reset label ends in a clock time or Claude's `(Zone/Name)` suffix. */
export function isCompleteResetDescription(raw: string): boolean {
  const reset = raw.trim();
  if (reset.length < 4) return false;
  if (reset.endsWith(")")) return reset.includes("(");
  return /\d(?::\d{2})?\s*(am|pm)$/i.test(reset);
}

const MONTH_INDEX: Record<string, number> = {
  jan: 1,
  feb: 2,
  mar: 3,
  apr: 4,
  may: 5,
  jun: 6,
  jul: 7,
  aug: 8,
  sep: 9,
  oct: 10,
  nov: 11,
  dec: 12,
};

/**
 * Claude's `/usage` reset copy into an absolute instant.
 * Matches Swift `AllowanceReset.claudeDate`: keep the source timezone, and
 * roll a clock that has already passed to the next day (or next year when
 * the label includes a month).
 */
export function claudeResetDate(raw: string, fetchedAt: Date = new Date()): Date | undefined {
  let text = raw.trim();
  let timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const zone = text.match(/\(([^)]+)\)\s*$/);
  if (zone) {
    const id = zone[1].trim();
    if (isTimeZone(id)) timeZone = id;
    text = text.slice(0, zone.index).trim();
  }
  text = text.replace(/\s+at\s+/i, ", ");
  const tomorrow = /^tomorrow\b/i.test(text);
  text = text.replace(/^(today|tomorrow)\s*[·,]?\s*/i, "");

  const dated = text.match(
    /^([A-Za-z]{3})\s+(\d{1,2}),?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/i,
  );
  const clockOnly = dated ? null : text.match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/i);
  const time = dated
    ? clockParts(dated[3], dated[4], dated[5])
    : clockOnly
      ? clockParts(clockOnly[1], clockOnly[2], clockOnly[3])
      : undefined;
  if (!time) return undefined;

  const now = zonedParts(fetchedAt, timeZone);
  const month = dated ? MONTH_INDEX[dated[1].slice(0, 3).toLowerCase()] : now.month;
  const day = dated ? Number(dated[2]) : now.day;
  if (!month || day < 1) return undefined;

  let result = zonedDate(now.year, month, day, time.hour, time.minute, timeZone);
  if (tomorrow) {
    result = addCivilDays(result, 1, timeZone);
  } else if (result.getTime() < fetchedAt.getTime() - 60_000) {
    result = dated
      ? zonedDate(now.year + 1, month, day, time.hour, time.minute, timeZone)
      : addCivilDays(result, 1, timeZone);
  }
  return result;
}

function clockParts(
  hourRaw: string,
  minuteRaw: string | undefined,
  ampm: string,
): { hour: number; minute: number } | undefined {
  let hour = Number(hourRaw);
  const minute = minuteRaw ? Number(minuteRaw) : 0;
  if (hour < 1 || hour > 12 || minute > 59) return undefined;
  const pm = ampm.toLowerCase() === "pm";
  if (hour === 12) hour = pm ? 12 : 0;
  else if (pm) hour += 12;
  return { hour, minute };
}

function isTimeZone(id: string): boolean {
  try {
    Intl.DateTimeFormat("en-US", { timeZone: id });
    return true;
  } catch {
    return false;
  }
}

function zonedParts(date: Date, timeZone: string): { year: number; month: number; day: number; hour: number; minute: number } {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).formatToParts(date);
  const map: Record<string, string> = {};
  for (const part of parts) {
    if (part.type !== "literal") map[part.type] = part.value;
  }
  let hour = Number(map.hour);
  if (hour === 24) hour = 0;
  return {
    year: Number(map.year),
    month: Number(map.month),
    day: Number(map.day),
    hour,
    minute: Number(map.minute),
  };
}

function tzOffsetMs(date: Date, timeZone: string): number {
  const parts = zonedParts(date, timeZone);
  const asUtc = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, 0);
  return asUtc - date.getTime();
}

function zonedDate(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  timeZone: string,
): Date {
  const utcGuess = Date.UTC(year, month - 1, day, hour, minute, 0);
  const first = new Date(utcGuess - tzOffsetMs(new Date(utcGuess), timeZone));
  const second = new Date(utcGuess - tzOffsetMs(first, timeZone));
  return second;
}

function addCivilDays(date: Date, days: number, timeZone: string): Date {
  const parts = zonedParts(date, timeZone);
  return zonedDate(parts.year, parts.month, parts.day + days, parts.hour, parts.minute, timeZone);
}

/** Compact calendar date for the menu bar (`Sep 20`). Nil for time-only labels. */
export function shortBarResetDate(raw: string): string | undefined {
  const match = raw.match(
    /\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\b/i,
  );
  if (!match) return undefined;
  const day = String(Number(match[2]));
  return `${match[1]} ${day}`;
}

export function parseClaudeUsage(
  raw: string,
  now = Date.now(),
  claudePath = "claude",
): ClaudeUsageSnapshot | undefined {
  const clean = stripTerminalSequences(raw);
  const session = usageWindow(/Current\s+session/, clean);
  const weekly =
    usageWindow(/Current\s+week\s*\(\s*all\s+models\s*\)/, clean) ??
    usageWindow(/Weekly\s+limits\s*[—-]\s*All\s+models/, clean);
  if (!session && !weekly) return undefined;
  return { session, weekly, fetchedAt: now, claudePath };
}

export function isCompleteUsageFrame(snapshot: ClaudeUsageSnapshot, raw: string): boolean {
  if (snapshot.weekly) return true;
  if (!snapshot.session) return false;
  const clean = stripTerminalSequences(raw);
  const mentionsWeek = /current week/i.test(clean) || /weekly limits/i.test(clean);
  return !mentionsWeek;
}

export function personalWindowLabel(window: ClaudeUsageWindow): string {
  if (window.percentLeft === 0) {
    const date = shortBarResetDate(window.resetDescription);
    if (date) return `0% ${date}`;
  }
  return `${window.percentLeft}%`;
}

function usageWindow(label: RegExp, text: string): ClaudeUsageWindow | undefined {
  const pattern = new RegExp(
    `${label.source}.*?(\\d{1,3})%\\s*used.*?Resets\\s+([^\\n]+)`,
    "is",
  );
  const match = pattern.exec(text);
  if (!match) return undefined;
  const used = Number(match[1]);
  if (!Number.isInteger(used) || used < 0 || used > 100) return undefined;
  const reset = match[2].replace(/[│┆┊]/g, "").trim();
  if (!isCompleteResetDescription(reset)) return undefined;
  return { percentLeft: 100 - used, resetDescription: reset };
}

/** Known Claude Code binaries only. Never a path from preferences. */
export function findClaudeExecutable(
  env: NodeJS.ProcessEnv = process.env,
  home = os.homedir(),
): string | undefined {
  const candidates = [
    env.TOKENPULSE_CLAUDE_PATH,
    path.join(home, ".local", "bin", "claude"),
    path.join(home, "bin", "claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    ...desktopClaudePaths(home),
  ].filter((p): p is string => Boolean(p));
  return candidates.find((p) => {
    try {
      return fs.statSync(p).isFile() && (fs.statSync(p).mode & 0o111) !== 0;
    } catch {
      return false;
    }
  });
}

function desktopClaudePaths(home: string): string[] {
  const root = path.join(home, "Library", "Application Support", "Claude", "claude-code");
  let names: string[] = [];
  try {
    names = fs.readdirSync(root);
  } catch {
    return [];
  }
  return names
    .filter((name) => name.length > 0 && !name.includes("."))
    .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))
    .map((name) => path.join(root, name, "claude.app", "Contents", "MacOS", "claude"));
}

function usageWorkDir(): string {
  const dir = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "TokenPulse",
    "claude-usage-cwd",
  );
  fs.mkdirSync(dir, { recursive: true });
  markTrusted(dir);
  return dir;
}

/** Pre-accept Claude Code's folder trust sheet for the probe directory only. */
function markTrusted(dir: string): void {
  const config = path.join(os.homedir(), ".claude.json");
  let parsed: unknown;
  try {
    parsed = JSON.parse(fs.readFileSync(config, "utf8"));
  } catch {
    return;
  }
  if (!isRecord(parsed)) return;
  const root = parsed;
  const projects = isRecord(root.projects) ? { ...root.projects } : {};
  const entry = isRecord(projects[dir]) ? { ...projects[dir] } : {};
  if (entry.hasTrustDialogAccepted === true) return;
  entry.hasTrustDialogAccepted = true;
  if (entry.allowedTools === undefined) entry.allowedTools = [];
  projects[dir] = entry;
  root.projects = projects;
  const next = `${JSON.stringify(root, null, 2)}\n`;
  const tmp = `${config}.tokenpulse-tmp`;
  fs.writeFileSync(tmp, next, { mode: 0o600 });
  fs.renameSync(tmp, config);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Reads Pro/Max allowance through `claude` `/usage`. TokenPulse does not read
 * Claude OAuth tokens or call the private usage API.
 */
export function fetchClaudeUsage(now = new Date()): Promise<ClaudeUsageSnapshot> {
  const claude = findClaudeExecutable();
  if (!claude) {
    throw new SourceError(
      "Claude CLI was not found. Install Claude Code, run claude once and finish /login, then refresh.",
      "setup",
    );
  }
  if (process.platform !== "darwin") {
    throw new SourceError("Claude personal usage is read through the Claude CLI on macOS.", "setup");
  }
  return runUsageProbe(claude, usageWorkDir(), now);
}

/**
 * Node's pipes are sockets, and macOS `script` refuses those (`tcgetattr`).
 * A Python pty is a real terminal, which is what Claude's `/usage` screen needs.
 */
const USAGE_PTY = String.raw`
import os, pty, re, select, signal, sys, time
claude, cwd = sys.argv[1], sys.argv[2]
master, slave = pty.openpty()
env = os.environ.copy()
env["TERM"] = "xterm-256color"
env["NO_COLOR"] = "1"
env["DISABLE_AUTOUPDATER"] = "1"
home = os.path.expanduser("~")
prefix = os.pathsep.join([
    os.path.join(home, ".local", "bin"),
    os.path.join(home, "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
])
env["PATH"] = prefix + os.pathsep + env.get("PATH", "/usr/bin:/bin")
pid = os.fork()
if pid == 0:
    os.setsid()
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(master)
    os.chdir(cwd)
    os.execvpe(claude, [claude], env)
os.close(slave)
buf = b""
sent = False
trusted = False
sent_at = None
start = time.time()

def frame_ready(data):
    text = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", " ", data.decode("utf-8", "replace")).lower()
    return ("% used" in text) and ("current week" in text or "weekly limits" in text)

while time.time() - start < 22:
    ready, _, _ = select.select([master], [], [], 0.2)
    if ready:
        try:
            chunk = os.read(master, 8192)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        low = buf.lower()
        if (not trusted) and (b"trust this folder" in low or b"quick safety check" in low):
            trusted = True
            os.write(master, b"\x1b[B\r")
        prompt = b"Claude Code" in buf or b"/effort" in buf
        if (not sent) and prompt and time.time() - start > 0.8:
            os.write(master, b"/usage\r")
            sent = True
            sent_at = time.time()
    if (not sent) and time.time() - start > 4:
        os.write(master, b"/usage\r")
        sent = True
        sent_at = time.time()
    if sent and frame_ready(buf):
        time.sleep(0.6)
        while True:
            ready, _, _ = select.select([master], [], [], 0.1)
            if not ready:
                break
            try:
                more = os.read(master, 8192)
            except OSError:
                break
            if not more:
                break
            buf += more
        break
    if sent_at is not None and time.time() - sent_at > 12:
        break
sys.stdout.buffer.write(buf)
sys.stdout.flush()
try:
    os.kill(pid, signal.SIGINT)
except OSError:
    pass
os.close(master)
deadline = time.time() + 1
while time.time() < deadline:
    ended, _ = os.waitpid(pid, os.WNOHANG)
    if ended:
        break
    time.sleep(0.05)
`;

function runUsageProbe(claude: string, cwd: string, now: Date): Promise<ClaudeUsageSnapshot> {
  return new Promise((resolve, reject) => {
    const home = os.homedir();
    const child = spawn("/usr/bin/python3", ["-c", USAGE_PTY, claude, cwd], {
      env: {
        ...process.env,
        HOME: process.env.HOME || home,
        PATH: [
          path.join(home, ".local", "bin"),
          path.join(home, "bin"),
          "/opt/homebrew/bin",
          "/usr/local/bin",
          process.env.PATH || "/usr/bin:/bin",
        ].join(path.delimiter),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const chunks: Buffer[] = [];
    let stderr = "";
    let settled = false;
    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    };
    child.stdout?.on("data", (chunk: Buffer) => chunks.push(chunk));
    child.stderr?.on("data", (chunk: Buffer) => {
      if (stderr.length < 400) stderr += chunk.toString("utf8");
    });
    child.on("error", (err) => {
      finish(() => reject(new SourceError(`The Claude CLI could not be launched. ${err.message}`, "setup")));
    });
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      finish(() => reject(new SourceError("Timed out waiting for Claude /usage.", "network")));
    }, USAGE_TIMEOUT_MS);
    child.on("exit", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      const snapshot = parseClaudeUsage(raw, now.getTime(), claude);
      if (snapshot && isCompleteUsageFrame(snapshot, raw)) {
        finish(() => resolve(snapshot));
        return;
      }
      if (stderr.includes("No such file") || stderr.includes("python3")) {
        finish(() => reject(new SourceError("Python 3 is required to read Claude /usage.", "setup")));
        return;
      }
      finish(() => reject(usageFailure(raw)));
    });
  });
}

function usageFailure(raw: string): SourceError {
  if (/login|sign in/i.test(raw)) {
    return new SourceError(
      "Claude CLI is not signed in. Run claude and complete /login once, then refresh.",
      "auth",
    );
  }
  return new SourceError("Claude /usage did not include a readable session or weekly limit.", "parse");
}
