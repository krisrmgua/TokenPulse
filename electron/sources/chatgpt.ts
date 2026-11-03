import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { SourceError, requestJSON } from "../http";
import { dayString, isRecord, numberField, percentLeftFromUsed, startOfMonth } from "../format";

// ---------------------------------------------------------------------------
// Personal: weekly / 5-hour allowance from `codex app-server --stdio`.
// ---------------------------------------------------------------------------

export interface ChatGPTWindow {
  percentLeft: number;
  resetAt: number;
}

export interface ChatGPTPersonalSnapshot {
  weekly: ChatGPTWindow;
  session?: ChatGPTWindow;
  codexPath: string;
  fetchedAt: number;
}

function windowFrom(raw: unknown): ChatGPTWindow | undefined {
  if (!isRecord(raw)) return undefined;
  const used = raw.usedPercent;
  const reset = raw.resetsAt;
  if (typeof used !== "number" || typeof reset !== "number") return undefined;
  return { percentLeft: percentLeftFromUsed(used), resetAt: reset * 1000 };
}

/** Parses the `account/rateLimits/read` response (id 2). */
export function parseRateLimits(
  line: unknown,
  codexPath = "codex",
  now = Date.now(),
): ChatGPTPersonalSnapshot | undefined {
  if (!isRecord(line) || line.id !== 2 || !isRecord(line.result)) return undefined;
  const limits = line.result.rateLimits;
  if (!isRecord(limits)) return undefined;
  const windows = [limits.primary, limits.secondary].filter(isRecord);
  const weeklyRaw =
    windows.find((w) => w.windowDurationMins === 10080) ?? limits.secondary;
  const sessionRaw = windows.find((w) => w.windowDurationMins === 300);
  const weekly = windowFrom(weeklyRaw);
  if (!weekly) return undefined;
  return { weekly, session: windowFrom(sessionRaw), codexPath, fetchedAt: now };
}

function isExecutable(file: string): boolean {
  try {
    fs.accessSync(file, process.platform === "win32" ? fs.constants.F_OK : fs.constants.X_OK);
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

export function codexExecutable(): string | undefined {
  const home = os.homedir();
  const names = process.platform === "win32" ? ["codex.exe", "codex.cmd"] : ["codex"];
  const candidates: (string | undefined)[] = [process.env.TOKENPULSE_CODEX_PATH];
  if (process.platform === "win32") {
    const appData = process.env.APPDATA ?? path.join(home, "AppData", "Roaming");
    const local = process.env.LOCALAPPDATA ?? path.join(home, "AppData", "Local");
    candidates.push(
      path.join(home, ".local", "bin", "codex.exe"),
      path.join(appData, "npm", "codex.cmd"),
      path.join(local, "Programs", "codex", "codex.exe"),
    );
  } else {
    candidates.push(
      path.join(home, ".local", "bin", "codex"),
      path.join(home, "bin", "codex"),
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      path.join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex"),
    );
  }
  for (const dir of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!dir) continue;
    for (const name of names) candidates.push(path.join(dir, name));
  }
  return candidates.find((c): c is string => Boolean(c) && isExecutable(c as string));
}

export function fetchChatGPTPersonal(timeoutMs = 30_000): Promise<ChatGPTPersonalSnapshot> {
  const codex = codexExecutable();
  if (!codex) {
    return Promise.reject(
      new SourceError(
        "Codex CLI was not found. Install it from chatgpt.com/codex or set TOKENPULSE_CODEX_PATH.",
        "setup",
      ),
    );
  }
  return new Promise((resolve, reject) => {
    // .cmd shims cannot be spawned directly on Windows; args are constants, so a shell is safe.
    const useShell = process.platform === "win32" && codex.toLowerCase().endsWith(".cmd");
    const child = spawn(useShell ? `"${codex}"` : codex, ["app-server", "--stdio"], {
      shell: useShell,
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buffered = "";
    let done = false;
    const finish = (err: Error | null, snap?: ChatGPTPersonalSnapshot) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        child.stdin.end();
      } catch {
        // ignore
      }
      child.kill();
      if (err) reject(err);
      else resolve(snap as ChatGPTPersonalSnapshot);
    };
    const timer = setTimeout(
      () => finish(new SourceError("Timed out waiting for Codex account usage.", "network")),
      timeoutMs,
    );
    child.on("error", () =>
      finish(new SourceError("The Codex app server could not be launched.", "setup")),
    );
    child.on("exit", () => {
      if (!done) finish(new SourceError("Codex exited before reporting usage."));
    });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      buffered += chunk;
      let nl: number;
      while ((nl = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, nl).trim();
        buffered = buffered.slice(nl + 1);
        if (!line) continue;
        let obj: unknown;
        try {
          obj = JSON.parse(line);
        } catch {
          continue;
        }
        const snap = parseRateLimits(obj, codex);
        if (snap) return finish(null, snap);
        if (isRecord(obj) && obj.id === 2 && obj.error !== undefined) {
          return finish(
            /auth/i.test(line)
              ? new SourceError("Codex CLI is not signed in with ChatGPT.", "auth")
              : new SourceError("Codex did not report a readable weekly limit."),
          );
        }
      }
    });
    child.stderr.resume();
    const initialize = {
      id: 1,
      method: "initialize",
      params: { clientInfo: { name: "tokenpulse", title: "TokenPulse", version: "1.0.0" } },
    };
    const initialized = { method: "initialized", params: {} };
    const read = { id: 2, method: "account/rateLimits/read", params: {} };
    child.stdin.write(
      [initialize, initialized, read].map((m) => JSON.stringify(m)).join("\n") + "\n",
    );
  });
}

// ---------------------------------------------------------------------------
// Work: workspace credit usage via the Codex ChatGPT login in ~/.codex/auth.json.
// ---------------------------------------------------------------------------

export const PUBLIC_USD_PER_CREDIT = 0.04;

export interface ChatGPTWorkSnapshot {
  todayCredits: number;
  monthCredits: number;
  byProduct: Record<string, number>;
  dataFreshnessAt?: number;
  serverEstimatedUSD?: number;
  fetchedAt: number;
}

export function workEstimatedUSD(s: ChatGPTWorkSnapshot): number {
  return s.serverEstimatedUSD ?? s.monthCredits * PUBLIC_USD_PER_CREDIT;
}

export function workTodayUSD(s: ChatGPTWorkSnapshot): number {
  return s.todayCredits * PUBLIC_USD_PER_CREDIT;
}

/** A zero today is withheld until ChatGPT's aggregation catches up to the clock. */
export function workTodayIsPending(s: ChatGPTWorkSnapshot): boolean {
  if (s.todayCredits !== 0) return false;
  if (s.dataFreshnessAt === undefined) return true;
  return s.dataFreshnessAt < s.fetchedAt;
}

export function parseWorkUsage(
  body: unknown,
  now: Date = new Date(),
  serverEstimatedUSD?: number,
): ChatGPTWorkSnapshot | undefined {
  if (!isRecord(body) || !Array.isArray(body.data)) return undefined;
  const today = dayString(now);
  let todayCredits = 0;
  let monthCredits = 0;
  const byProduct: Record<string, number> = {};
  for (const day of body.data) {
    if (!isRecord(day) || typeof day.date !== "string" || !isRecord(day.values)) continue;
    let total = 0;
    for (const [product, credits] of Object.entries(day.values)) {
      if (typeof credits !== "number") continue;
      total += credits;
      byProduct[product] = (byProduct[product] ?? 0) + credits;
    }
    monthCredits += total;
    if (day.date === today) todayCredits += total;
  }
  const fresh =
    typeof body.data_freshness_ts === "string" ? Date.parse(body.data_freshness_ts) : NaN;
  return {
    todayCredits,
    monthCredits,
    byProduct,
    dataFreshnessAt: Number.isFinite(fresh) ? fresh : undefined,
    serverEstimatedUSD,
    fetchedAt: now.getTime(),
  };
}

export function codexAuthPath(): string {
  const base = process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex");
  return path.join(base, "auth.json");
}

interface CodexCredentials {
  accessToken: string;
  accountID: string;
}

export function readCodexCredentials(): CodexCredentials | undefined {
  try {
    const raw = JSON.parse(fs.readFileSync(codexAuthPath(), "utf8")) as unknown;
    if (!isRecord(raw) || !isRecord(raw.tokens)) return undefined;
    if (raw.auth_mode !== undefined && raw.auth_mode !== null && raw.auth_mode !== "chatgpt") {
      return undefined;
    }
    const accessToken = raw.tokens.access_token;
    const accountID = raw.tokens.account_id;
    if (typeof accessToken !== "string" || !accessToken) return undefined;
    if (typeof accountID !== "string" || !accountID) return undefined;
    return { accessToken, accountID };
  } catch {
    return undefined;
  }
}

export async function fetchChatGPTWork(now: Date = new Date()): Promise<ChatGPTWorkSnapshot> {
  const creds = readCodexCredentials();
  if (!creds) {
    throw new SourceError(
      `Codex is not signed in with ChatGPT (${codexAuthPath()} missing or not a ChatGPT login).`,
      "setup",
    );
  }
  const headers = {
    Authorization: `Bearer ${creds.accessToken}`,
    "ChatGPT-Account-ID": creds.accountID,
  };
  const params = new URLSearchParams({
    start_date: dayString(startOfMonth(now)),
    end_date: dayString(now),
    group_by: "day",
  });
  const res = await requestJSON(
    `https://chatgpt.com/backend-api/wham/usage/daily-workspace-user-credit-usage?${params}`,
    { headers, timeoutMs: 20_000 },
  );
  if (res.status === 401 || res.status === 403) {
    throw new SourceError(
      "The Codex ChatGPT login expired. Reopen Codex and sign in again.",
      "auth",
      res.status,
    );
  }
  if (res.status !== 200) {
    throw new SourceError(`ChatGPT workspace usage returned HTTP ${res.status}.`, "http", res.status);
  }
  const initial = parseWorkUsage(res.body, now);
  if (!initial) throw new SourceError("ChatGPT returned an unreadable workspace usage response.");

  let serverEstimate: number | undefined;
  try {
    const est = await requestJSON("https://chatgpt.com/backend-api/wham/usage/credits/estimate", {
      method: "POST",
      headers,
      body: { credits: Math.round(initial.monthCredits * 1_000_000) / 1_000_000 },
      timeoutMs: 20_000,
    });
    if (est.status === 200 && isRecord(est.body)) {
      const micros = numberField(est.body, "estimated_usage_usd_micros");
      if (micros > 0) serverEstimate = micros / 1_000_000;
    }
  } catch {
    serverEstimate = undefined;
  }
  return { ...initial, serverEstimatedUSD: serverEstimate };
}
