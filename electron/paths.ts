import fs from "node:fs";
import path from "node:path";
import { app } from "electron";
import { restrictDir } from "./fsSecure";

/**
 * userData is `~/Library/Application Support/TokenPulse` on macOS (the same
 * folder the Swift app uses) and `%APPDATA%\TokenPulse` on Windows.
 */
export function dataDir(): string {
  const dir = app.getPath("userData");
  fs.mkdirSync(dir, { recursive: true });
  restrictDir(dir);
  return dir;
}

export function prefsPath(): string {
  return path.join(dataDir(), "prefs.json");
}

export function ledgerPath(): string {
  return path.join(dataDir(), "spend-ledger.json");
}

export function resourcePath(...parts: string[]): string {
  if (app.isPackaged) return path.join(process.resourcesPath, ...parts);
  return path.join(app.getAppPath(), ...parts);
}

export function pricingCandidates(): string[] {
  const out: string[] = [];
  if (process.env.TOKENPULSE_PRICING) out.push(process.env.TOKENPULSE_PRICING);
  out.push(path.join(dataDir(), "pricing.json"));
  out.push(resourcePath("pricing.json"));
  return out;
}
