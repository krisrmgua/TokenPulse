import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Prefs } from "./types";
import type { StatusBlock } from "./statusBarTypes";

/** Resolve the Swift TokenPulse CLI that embeds StatusBarArtwork. */
export function findSwiftBarBinary(): string | null {
  if (process.env.TOKENPULSE_SWIFT_BIN && fs.existsSync(process.env.TOKENPULSE_SWIFT_BIN)) {
    return process.env.TOKENPULSE_SWIFT_BIN;
  }
  const home = os.homedir();
  const bundled: string[] = [];
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { app } = require("electron") as typeof import("electron");
    if (app?.isPackaged) {
      bundled.push(path.join(process.resourcesPath, "TokenPulseBar"));
    }
  } catch {
    /* not in Electron */
  }
  // Never use ~/Applications/TokenPulse.app — that is the Electron shell.
  const candidates = [
    ...bundled,
    path.join(process.cwd(), "menubar", ".build", "release", "TokenPulse"),
    path.join(home, "Applications", "TokenPulse-Swift.app", "Contents", "MacOS", "TokenPulse"),
    path.join(process.cwd(), "menubar", "TokenPulse-Swift.app", "Contents", "MacOS", "TokenPulse"),
    path.join(process.cwd(), "menubar", "TokenPulse.app", "Contents", "MacOS", "TokenPulse"),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

/**
 * Paint tray capsules with AppKit (identical SF Pro / counters to Swift).
 * Returns null when the Swift CLI is missing or fails — caller uses canvas.
 */
export function renderStatusBarPngViaSwift(
  blocks: StatusBlock[],
  prefs: Pick<Prefs, "darkBarBackground" | "themedProviderLogos">,
): { png: Buffer; scaleFactor: number } | null {
  if (process.platform !== "darwin") return null;
  const bin = findSwiftBarBinary();
  if (!bin) return null;

  const payload = {
    dark: prefs.darkBarBackground,
    themed: prefs.themedProviderLogos,
    blocks: blocks.map((b) => ({
      id: b.id,
      design: b.design,
      stale: b.stale,
      metrics: b.metrics.map((m) => ({
        label: m.label,
        value: m.value,
        percent: m.percent,
        color: m.color,
      })),
    })),
  };

  const out = path.join(os.tmpdir(), `tokenpulse-bar-${process.pid}-${Date.now()}.png`);
  try {
    const result = spawnSync(bin, ["--bar-render", out], {
      input: JSON.stringify(payload),
      maxBuffer: 8 * 1024 * 1024,
      timeout: 8000,
    });
    if (result.status !== 0 || !fs.existsSync(out)) {
      const err = Buffer.isBuffer(result.stderr)
        ? result.stderr.toString("utf8").trim()
        : String(result.stderr ?? "").trim();
      if (err) console.warn("[tokenpulse] swift bar-render:", err);
      return null;
    }
    const png = fs.readFileSync(out);
    return { png, scaleFactor: 2 };
  } catch (e) {
    console.warn("[tokenpulse] swift bar-render failed", e);
    return null;
  } finally {
    try {
      fs.unlinkSync(out);
    } catch {
      /* ignore */
    }
  }
}
