import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { Pricing } from "./pricing";
import { SpendLedger } from "./ledger";
import {
  projectedMonthEnd,
  shortMoney,
  barMoney,
  barPercent,
  displayDate,
  startOfNextMonth,
} from "./format";
import { parseAggregations, parsePlanUsage, parseTotalSpendUSD, cursorPersonalPercentLeft } from "./sources/cursor";
import { parseSandUsage } from "./sources/grokbot";
import { parseRateLimits, parseWorkUsage, workEstimatedUSD, workTodayIsPending } from "./sources/chatgpt";
import { parseCostPage, requestURL, totalUSD, lineItems, estimateBalance } from "./sources/openai";
import { parseTranscriptLine, summarize } from "./sources/claude";
import {
  claudeResetDate,
  isCompleteResetDescription,
  isCompleteUsageFrame,
  parseClaudeUsage,
  personalWindowLabel,
} from "./sources/claudeUsage";
import { BAR_DESIGNS } from "./barDesign";
import { blocksFromSources } from "./statusBar";
import { defaultPrefs, parseSwiftOpenAIBalance } from "./prefs";
import { classifyCredential, decodeCredential, SAFE_STORAGE_PREFIX } from "./sources/cursorAuth";
import { isValidAdminKeyFormat, OpenAIKeyStore } from "./openaiAdmin";
import { renderMark } from "./iconRaster";
import { renderStatusBarPng } from "./statusBarRender";
import { menuBarScaleFromRaw } from "./types";
import { tintCombinedSpendUSD } from "./spendTint";

test("pricing resolves overrides, families, fallback", () => {
  const p = new Pricing([]);
  assert.equal(p.rate("claude-sonnet-5-20260101").input, 2);
  assert.equal(p.rate("openai.gpt-5.4").output, 16.5);
  assert.equal(p.rate("claude-opus-4-7").input, 5);
  assert.equal(p.rate("bedrock/gpt-5.6-sol").input, 5.5);
  assert.equal(p.rate("console-preview").input, 5, "sol must match a whole component only");
  assert.ok(Math.abs(p.cost(1_000_000, 0, 0, 0, "claude-haiku-4") - 1) < 1e-9);
});

test("pricing.json at repo root loads", () => {
  const p = new Pricing([path.join(__dirname, "..", "pricing.json")]);
  assert.notEqual(p.source, "built-in");
  assert.equal(p.rate("claude-sonnet-4-5").output, 15);
});

test("projection and formatting", () => {
  const now = new Date(2026, 10, 10);
  assert.ok(Math.abs(projectedMonthEnd(100, now) - 300) < 1e-9);
  assert.equal(shortMoney(4.123), "$4.12");
  assert.equal(shortMoney(184.6), "$185");
  assert.equal(shortMoney(1234), "$1.2k");
  assert.equal(barMoney(4.123), "$4.12");
  assert.equal(barMoney(87.59), "$88");
  assert.equal(barMoney(99.9), "$100");
  assert.equal(barMoney(1234), "$1.2k");
  const ref = new Date(2026, 10, 3, 12, 0, 0); // Nov 3, 2026
  assert.match(displayDate(new Date(2026, 10, 3, 21, 43, 0), ref), /^Today at /);
  assert.match(displayDate(new Date(2026, 10, 4, 1, 57, 0), ref), /^Tomorrow at /);
  assert.match(displayDate(new Date(2026, 10, 7, 14, 58, 0), ref), /^Nov 7, 2026 at /);
  assert.equal(startOfNextMonth(ref).getTime(), new Date(2026, 11, 1).getTime());
  assert.equal(barPercent(42), "42%");
  assert.match(barPercent(0, new Date(2026, 10, 9)), /^0% Nov 9$/);
});

test("ledger records and charts month-to-date", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tp-ledger-"));
  const file = path.join(dir, "spend-ledger.json");
  const ledger = new SpendLedger(file);
  ledger.record(5, 10, "2026-11-01");
  ledger.record(7, 17, "2026-11-02");
  const reread = new SpendLedger(file);
  assert.equal(reread.entries().length, 2);
  const chart = reread.monthChart(30, 300, new Date(2026, 10, 3, 12));
  assert.equal(chart.length, 30);
  assert.equal(chart[0].actualUSD, 10);
  assert.equal(chart[1].actualUSD, 17);
  assert.equal(chart[2].actualUSD, 30);
  assert.equal(chart[2].isToday, true);
  assert.equal(chart[29].projectedUSD, 300);
  assert.equal(chart[3].actualUSD, null);
});

test("cursor dashboard parsing", () => {
  const agg = parseAggregations({
    aggregations: [
      { modelIntent: "a", totalCents: "150", inputTokens: 10 },
      { modelIntent: "b", totalCents: 900 },
    ],
    totalCostCents: 1100,
  });
  assert.equal(agg?.[0].model, "b");
  assert.equal(agg?.[1].spendUSD, 1.5);
  assert.equal(parseTotalSpendUSD({ totalCostCents: "1100" }), 11);
  const plan = parsePlanUsage({
    planUsage: { limit: 2000, includedSpend: 500, totalPercentUsed: 25.4 },
    billingCycleEnd: "1762000000000",
  });
  assert.equal(plan?.percentLeft, 75);
  assert.equal(plan?.limitUSD, 20);
  assert.equal(plan?.billingCycleEnd, 1762000000000);
  assert.equal(parsePlanUsage({ planUsage: { limit: 0 } }), undefined);
  const snap = { todaySpendUSD: 0, totalSpendUSD: 5, byModel: [], userId: 1, fetchedAt: 0 };
  assert.equal(cursorPersonalPercentLeft(snap, 20), 75);
});

test("grok bot sand usage", () => {
  const s = parseSandUsage({ usagePercent: 39, nextResetTimestampUtc: "2026-11-09T00:00:00Z" });
  assert.equal(s?.percentLeft, 61);
  assert.ok(s?.resetAt);
  assert.equal(parseSandUsage({ usagePercent: 10, usesPooledEnterpriseAllowance: true }), undefined);
});

test("codex rate limits pick weekly by duration", () => {
  const snap = parseRateLimits({
    id: 2,
    result: {
      rateLimits: {
        primary: { usedPercent: 36, resetsAt: 1762000000, windowDurationMins: 300 },
        secondary: { usedPercent: 60, resetsAt: 1762500000, windowDurationMins: 10080 },
      },
    },
  });
  assert.equal(snap?.weekly.percentLeft, 40);
  assert.equal(snap?.session?.percentLeft, 64);
  assert.equal(parseRateLimits({ id: 1, result: {} }), undefined);
});

test("chatgpt work credits", () => {
  const now = new Date(2026, 10, 3, 15);
  const s = parseWorkUsage(
    {
      data: [
        { date: "2026-11-02", values: { codex: 100, chat: 20 } },
        { date: "2026-11-03", values: { codex: 0 } },
      ],
      data_freshness_ts: "2026-11-02T00:00:00Z",
    },
    now,
  );
  assert.ok(s);
  assert.equal(s.monthCredits, 120);
  assert.equal(s.byProduct.codex, 100);
  assert.ok(Math.abs(workEstimatedUSD(s) - 4.8) < 1e-9);
  assert.equal(workTodayIsPending(s), true);
});

test("openai costs parsing and pagination guard", () => {
  const page = parseCostPage({
    data: [
      {
        start_time: 0,
        end_time: 1,
        results: [
          { amount: { value: 1.25, currency: "usd" }, line_item: "gpt-5" },
          { amount: { value: 2, currency: "eur" }, line_item: "gpt-5" },
          { amount: { value: 0.75 } },
        ],
      },
    ],
    has_more: false,
  });
  assert.ok(page);
  assert.equal(totalUSD(page.results), 2);
  assert.deepEqual(lineItems(page.results).map((l) => l.lineItem), ["gpt-5", "Other"]);
  const start = new Date(2026, 10, 1);
  const end = new Date(2026, 10, 3);
  assert.match(requestURL(start, end, 33) ?? "", /^https:\/\/api\.openai\.com\/v1\/organization\/costs\?/);
  assert.equal(requestURL(start, end, 33, "https://evil.example/x"), undefined);
  assert.equal(requestURL(start, end, 33, "../x"), undefined);
  assert.equal(requestURL(start, end, 33, "a\nb"), undefined);
  assert.equal(
    estimateBalance({ enteredUSD: 100, dayStart: start.toISOString(), spendAlreadyReportedUSD: 3 }, 10),
    93,
  );
});

test("fresh defaults are off and personal", () => {
  const prefs = defaultPrefs();
  for (const source of Object.values(prefs.sources)) {
    assert.equal(source.enabled, false);
    assert.equal(source.showInTray, false);
  }
  assert.equal(prefs.sources.claude.account, "personal");
  assert.equal(prefs.sources.cursor.account, "personal");
  assert.equal(prefs.sources.chatgpt.account, "personal");
  assert.equal(prefs.sources.grokbot.account, "personal");
  assert.equal(prefs.sources.openai.account, "work");
  assert.equal(prefs.sources.openai.showBalanceInBar, true);
  assert.equal(prefs.menuBarScale, 100);
});

test("swift openai balance baseline copies into electron prefs", () => {
  const raw = [
    'openAIEstimatedBalanceBaselineUSD = "9.27";',
    'openAIEstimatedBalanceDayStart = "2026-08-26 06:00:00 +0000";',
    "openAIEstimatedBalanceDaySpendUSD = 0;",
  ].join("\n");
  const baseline = parseSwiftOpenAIBalance(raw);
  assert.equal(baseline?.enteredUSD, 9.27);
  assert.equal(baseline?.spendAlreadyReportedUSD, 0);
  assert.equal(baseline?.dayStart, "2026-08-26T06:00:00.000Z");
  assert.equal(parseSwiftOpenAIBalance("openAIEstimatedBalanceBaselineUSD = 1;"), undefined);
});

test("openai menu bar can show or hide balance, daily, and month", () => {
  const prefs = defaultPrefs();
  prefs.sources.openai.enabled = true;
  prefs.sources.openai.showInTray = true;
  const snap = {
    id: "openai" as const,
    name: "OpenAI API",
    enabled: true,
    showInTray: true,
    account: "work" as const,
    accounts: ["work" as const],
    status: "ok" as const,
    todayUSD: 0,
    monthUSD: 0,
    meters: [],
    lines: [{ label: "Estimated prepaid balance", value: "$8.50" }],
    credential: "",
  };
  assert.deepEqual(
    blocksFromSources([snap], prefs)[0].metrics.map((m) => `${m.label} ${m.value}`),
    ["B $8.50", "D $0.00", "M $0.00"],
  );
  prefs.sources.openai.showDailyInBar = false;
  prefs.sources.openai.showBalanceInBar = false;
  assert.deepEqual(
    blocksFromSources([snap], prefs)[0].metrics.map((m) => m.label),
    ["M"],
  );
  prefs.sources.openai.showBalanceInBar = true;
  prefs.sources.openai.showMonthlyInBar = false;
  const unset = blocksFromSources([{ ...snap, lines: [] }], prefs);
  assert.deepEqual(
    unset[0].metrics.map((m) => `${m.label} ${m.value}`),
    ["B —"],
  );
});

test("claude /usage parse keeps a finished weekly row", () => {
  const raw = [
    "Current session",
    "91% used",
    "Resets 3:30pm (America/Denver)",
    "Current week (all models)",
    "39% used",
    "Resets Sep 16 at 11am (America/Denver)",
  ].join("\n");
  const snap = parseClaudeUsage(raw, 0, "claude");
  assert.ok(snap);
  assert.equal(snap.session?.percentLeft, 9);
  assert.equal(snap.weekly?.percentLeft, 61);
  assert.equal(isCompleteUsageFrame(snap, raw), true);
  assert.equal(personalWindowLabel(snap.weekly!), "61%");
  assert.equal(isCompleteResetDescription("Sep"), false);
  assert.equal(isCompleteResetDescription("Sep 16 at 11am (America/Denver)"), true);
  const partial = "Current session\n25% used\nResets 4:00pm (America/Denver)\nCurrent week";
  const sessionOnly = parseClaudeUsage(partial);
  assert.ok(sessionOnly?.session);
  assert.equal(isCompleteUsageFrame(sessionOnly, partial), false);
});

test("menu bar styles number in order", () => {
  assert.deepEqual(
    BAR_DESIGNS.map((d) => d.number),
    [1, 2, 3, 4, 5, 6, 7],
  );
});

test("claude reset copy becomes an absolute instant", () => {
  const fetchedAt = new Date("2026-11-01T20:00:00Z");
  assert.equal(
    claudeResetDate("3:30pm (America/Los_Angeles)", fetchedAt)?.toISOString(),
    "2026-11-01T23:30:00.000Z",
  );
  assert.equal(
    claudeResetDate("Nov 6, 9am (America/Denver)", fetchedAt)?.toISOString(),
    "2026-11-06T16:00:00.000Z",
  );
  assert.equal(
    claudeResetDate("Nov 7 at 10am (America/Denver)", fetchedAt)?.toISOString(),
    "2026-11-07T17:00:00.000Z",
  );
  assert.equal(claudeResetDate("not reported", fetchedAt), undefined);
  const pastClock = claudeResetDate("1:00am (America/Denver)", fetchedAt);
  assert.equal(pastClock?.toISOString(), "2026-11-02T08:00:00.000Z");
});

test("claude transcript lines and rollup", () => {
  const now = new Date(2026, 10, 3, 12);
  const line = {
    type: "assistant",
    sessionId: "s1",
    requestId: "r1",
    timestamp: new Date(2026, 10, 3, 9).toISOString(),
    message: {
      id: "m1",
      model: "claude-opus-4-7",
      usage: { input_tokens: 1_000_000, output_tokens: 0 },
    },
  };
  const rec = parseTranscriptLine(line);
  assert.ok(rec);
  assert.equal(parseTranscriptLine({ message: { usage: {} } }), undefined);
  const r = summarize([rec, rec], new Pricing([]), now);
  assert.equal(r.monthUSD, 5, "duplicate message ids are counted once");
  assert.equal(r.todayUSD, 5);
  assert.equal(r.opusUSD, 5);
  assert.equal(r.sessions, 1);
});

test("cursor credential classification and plaintext passthrough", async () => {
  assert.equal(classifyCredential(null), "missing");
  assert.equal(classifyCredential("eyJhbGciOi"), "ready");
  assert.equal(classifyCredential(`${SAFE_STORAGE_PREFIX}abc`), "encrypted");
  assert.equal(await decodeCredential("eyJplain"), "eyJplain");
});

test("macOS safe-storage cipher round trip", () => {
  const key = crypto.pbkdf2Sync("pw", "saltysalt", 1003, 16, "sha1");
  const cipher = crypto.createCipheriv("aes-128-cbc", key, Buffer.alloc(16, 0x20));
  const blob = Buffer.concat([Buffer.from("v10"), cipher.update("token-123"), cipher.final()]);
  const decipher = crypto.createDecipheriv("aes-128-cbc", key, Buffer.alloc(16, 0x20));
  const plain = Buffer.concat([decipher.update(blob.subarray(3)), decipher.final()]).toString();
  assert.equal(plain, "token-123");
});

test("openai admin key file is owner-only", () => {
  assert.equal(isValidAdminKeyFormat("sk-admin-abc"), true);
  assert.equal(isValidAdminKeyFormat("sk-proj-abc"), false);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tp-key-"));
  const store = new OpenAIKeyStore(dir);
  assert.equal(store.save("sk-proj-nope").ok, false);
  assert.equal(store.save("  sk-admin-test  ").ok, true);
  assert.equal(new OpenAIKeyStore(dir).read(), "sk-admin-test");
  if (process.platform !== "win32") {
    assert.equal(fs.statSync(store.file).mode & 0o777, 0o600);
  }
  store.delete();
  assert.equal(new OpenAIKeyStore(dir).isConfigured(), false);
});

test("menu bar size steps from normal to micro, including compact stack", () => {
  assert.equal(menuBarScaleFromRaw(undefined, false), 100);
  assert.equal(menuBarScaleFromRaw(undefined, true), 70);
  assert.equal(menuBarScaleFromRaw(65, true), 65);
  assert.equal(menuBarScaleFromRaw(40, false), 100);
  const metric = {
    label: "5H",
    value: "80%",
    percent: 80,
    color: [88, 210, 236] as [number, number, number],
  };
  const base = { darkBarBackground: true, themedProviderLogos: false, menuBarScale: 100 as const };
  const block = {
    id: "claude" as const,
    metrics: [metric],
    stale: false,
    allowanceEmpty: false,
    design: "divider" as const,
  };
  const full = renderStatusBarPng([block], base);
  const slight = renderStatusBarPng([block], { ...base, menuBarScale: 95 });
  const micro = renderStatusBarPng([block], { ...base, menuBarScale: 65 });
  assert.ok(slight.height < full.height);
  assert.ok(slight.width < full.width);
  assert.ok(micro.height < full.height * 0.75);
  assert.ok(micro.width < full.width * 0.8);
  assert.ok(micro.height < slight.height);
  const stack = { ...block, design: "stack" as const };
  const stackFull = renderStatusBarPng([stack], base);
  const stackMicro = renderStatusBarPng([stack], { ...base, menuBarScale: 65 });
  assert.ok(stackMicro.height < stackFull.height * 0.75);
  assert.ok(stackMicro.width < stackFull.width * 0.8);
});

test("divider stays text and baseline keeps the underline meter", () => {
  const metric = {
    label: "5H",
    value: "80%",
    percent: 80,
    color: [88, 210, 236] as [number, number, number],
  };
  const prefs = { darkBarBackground: true, themedProviderLogos: false };
  const block = {
    id: "claude" as const,
    metrics: [metric, { ...metric, label: "W", value: "40%", percent: 40 }],
    stale: false,
    allowanceEmpty: false,
  };
  const divider = renderStatusBarPng([{ ...block, design: "divider" }], prefs).png;
  const baseline = renderStatusBarPng([{ ...block, design: "baseline" }], prefs).png;
  assert.notDeepEqual(divider, baseline);
});

test("segmented lanes cut the meter into dashes", () => {
  const metric = {
    label: "5H",
    value: "80%",
    percent: 80,
    color: [88, 210, 236] as [number, number, number],
  };
  const prefs = { darkBarBackground: true, themedProviderLogos: false };
  const block = {
    id: "claude" as const,
    metrics: [metric, { ...metric, label: "W", value: "40%", percent: 40 }],
    stale: false,
    allowanceEmpty: false,
  };
  const lanes = renderStatusBarPng([{ ...block, design: "lanes" }], prefs).png;
  const segments = renderStatusBarPng([{ ...block, design: "segments" }], prefs).png;
  assert.ok(lanes.length > 8 && segments.length > 8);
  assert.notDeepEqual(lanes, segments);
});

test("icon rasterizer emits a PNG", () => {
  const png = renderMark({ size: 32, variant: "tray" });
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
});

test("combined spend tint mirrors Swift day vs month caps", () => {
  const prefs = { spendColorsEnabled: true, pastelBarColors: false };
  const work = [
    { id: "cursor", enabled: true, account: "work" },
    { id: "claude", enabled: true, account: "work" },
  ];
  // Nov has 30 days; cap 3000 → dailyCap 100. $94.48 is ≥75% → orange.
  const now = new Date(2026, 10, 3);
  assert.deepEqual(tintCombinedSpendUSD(94.48, "day", work, prefs, now), [255, 128, 0]);
  assert.deepEqual(tintCombinedSpendUSD(107.3, "month", work, prefs, now), [48, 209, 88]);
  assert.deepEqual(tintCombinedSpendUSD(1072.97, "month", work, prefs, now), [48, 209, 88]);
  assert.deepEqual(
    tintCombinedSpendUSD(94.48, "day", work, { ...prefs, spendColorsEnabled: false }, now),
    [237, 245, 255],
  );
});
