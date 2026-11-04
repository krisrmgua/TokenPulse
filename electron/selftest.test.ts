import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { Pricing } from "./pricing";
import { SpendLedger } from "./ledger";
import { projectedMonthEnd, shortMoney, barMoney, barPercent } from "./format";
import { parseAggregations, parsePlanUsage, parseTotalSpendUSD, cursorPersonalPercentLeft } from "./sources/cursor";
import { parseSandUsage } from "./sources/grokbot";
import { parseRateLimits, parseWorkUsage, workEstimatedUSD, workTodayIsPending } from "./sources/chatgpt";
import { parseCostPage, requestURL, totalUSD, lineItems, estimateBalance } from "./sources/openai";
import { parseTranscriptLine, summarize } from "./sources/claude";
import { classifyCredential, decodeCredential, SAFE_STORAGE_PREFIX } from "./sources/cursorAuth";
import { isValidAdminKeyFormat, OpenAIKeyStore } from "./openaiAdmin";
import { renderMark } from "./iconRaster";

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

test("icon rasterizer emits a PNG", () => {
  const png = renderMark({ size: 32, variant: "tray" });
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
});
