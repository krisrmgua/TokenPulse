import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { SourceError } from "../http";

const TOKEN_KEY = "cursorAuth/accessToken";
export const SAFE_STORAGE_PREFIX = "cursor-safe-storage:v1:";
const KEYCHAIN_SERVICE = "Cursor Safe Storage";

export function cursorUserDir(): string {
  const home = os.homedir();
  if (process.platform === "win32") {
    const appData = process.env.APPDATA ?? path.join(home, "AppData", "Roaming");
    return path.join(appData, "Cursor");
  }
  if (process.platform === "darwin") {
    return path.join(home, "Library", "Application Support", "Cursor");
  }
  return path.join(process.env.XDG_CONFIG_HOME ?? path.join(home, ".config"), "Cursor");
}

export function cursorStateDbPath(): string {
  return path.join(cursorUserDir(), "User", "globalStorage", "state.vscdb");
}

export type CursorLogin = "missing" | "ready" | "encrypted";

export interface StoredCredential {
  value: string | null;
  reader: "node:sqlite" | "sqlite3-cli" | "none";
}

function execFileText(
  file: string,
  args: string[],
  opts: { env?: NodeJS.ProcessEnv; timeoutMs?: number } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      file,
      args,
      {
        encoding: "utf8",
        timeout: opts.timeoutMs ?? 15_000,
        maxBuffer: 4 * 1024 * 1024,
        windowsHide: true,
        env: opts.env ?? process.env,
      },
      (err, stdout) => {
        if (err) reject(err);
        else resolve(stdout);
      },
    );
  });
}

interface SqliteStatement {
  get(...params: unknown[]): Record<string, unknown> | undefined;
}
interface SqliteDatabase {
  prepare(sql: string): SqliteStatement;
  close(): void;
}
type SqliteModule = {
  DatabaseSync: new (file: string, opts?: { readOnly?: boolean }) => SqliteDatabase;
};

let sqliteModule: SqliteModule | null | undefined;

function loadNodeSqlite(): SqliteModule | null {
  if (sqliteModule !== undefined) return sqliteModule;
  try {
    sqliteModule = require("node:sqlite") as SqliteModule;
  } catch {
    sqliteModule = null;
  }
  return sqliteModule;
}

function valueToString(v: unknown): string | null {
  if (typeof v === "string") return v;
  if (v instanceof Uint8Array) return Buffer.from(v).toString("utf8");
  return null;
}

/** Read-only lookup of Cursor's stored access token. Never writes Cursor's DB. */
export async function readStoredCredential(): Promise<StoredCredential> {
  const db = cursorStateDbPath();
  if (!fs.existsSync(db)) return { value: null, reader: "none" };

  const mod = loadNodeSqlite();
  if (mod) {
    try {
      const conn = new mod.DatabaseSync(db, { readOnly: true });
      try {
        const row = conn
          .prepare("SELECT value FROM ItemTable WHERE key = ? LIMIT 1")
          .get(TOKEN_KEY);
        const value = row ? valueToString(row.value) : null;
        return { value: value && value.length > 0 ? value : null, reader: "node:sqlite" };
      } finally {
        conn.close();
      }
    } catch {
      // Fall through to the CLI (e.g. DB locked mid-checkpoint).
    }
  }

  const cli = process.platform === "darwin" ? "/usr/bin/sqlite3" : "sqlite3";
  try {
    const out = await execFileText(cli, [
      "-readonly",
      db,
      `SELECT value FROM ItemTable WHERE key = '${TOKEN_KEY}' LIMIT 1;`,
    ]);
    const value = out.trim();
    return { value: value.length > 0 ? value : null, reader: "sqlite3-cli" };
  } catch {
    if (!mod) {
      throw new SourceError(
        "Cannot open Cursor's state.vscdb: this Electron build has no node:sqlite and the sqlite3 CLI is not on PATH.",
        "setup",
      );
    }
    throw new SourceError("Could not read Cursor's state.vscdb.", "setup");
  }
}

export function classifyCredential(stored: string | null): CursorLogin {
  if (!stored) return "missing";
  return stored.startsWith(SAFE_STORAGE_PREFIX) ? "encrypted" : "ready";
}

// ---------------------------------------------------------------------------
// Decryption. Cursor stores `cursor-safe-storage:v1:` + base64(Electron
// safeStorage output). Electron safeStorage is Chromium os_crypt:
//   macOS:   "v10" + AES-128-CBC, key = PBKDF2-SHA1(Keychain pw, "saltysalt", 1003, 16), IV = 16 spaces
//   Windows: "v10" + 12-byte nonce + AES-256-GCM ciphertext + 16-byte tag,
//            key = DPAPI-unwrapped os_crypt.encrypted_key from Cursor's "Local State"
//   Linux:   "v10"/"v11" + AES-128-CBC with libsecret/kwallet or "peanuts" password
// ---------------------------------------------------------------------------

let macKey: Buffer | undefined;
let windowsKey: Buffer | undefined;

async function macDerivedKey(): Promise<Buffer> {
  if (macKey) return macKey;
  let password: string;
  try {
    password = (
      await execFileText(
        "/usr/bin/security",
        ["find-generic-password", "-w", "-s", KEYCHAIN_SERVICE],
        { timeoutMs: 120_000 },
      )
    ).replace(/\r?\n$/, "");
  } catch {
    throw new SourceError(
      "Could not read the Cursor Safe Storage password from the login Keychain (denied or missing).",
      "auth",
    );
  }
  macKey = crypto.pbkdf2Sync(Buffer.from(password, "utf8"), "saltysalt", 1003, 16, "sha1");
  return macKey;
}

function decryptCbc(blob: Buffer, key: Buffer): string {
  let cipherText = blob;
  if (cipherText.length > 3 && cipherText.subarray(0, 3).toString("latin1").match(/^v1[01]$/)) {
    cipherText = cipherText.subarray(3);
  }
  const decipher = crypto.createDecipheriv("aes-128-cbc", key, Buffer.alloc(16, 0x20));
  return Buffer.concat([decipher.update(cipherText), decipher.final()]).toString("utf8");
}

async function dpapiUnprotect(data: Buffer): Promise<Buffer> {
  const script =
    "Add-Type -AssemblyName System.Security; " +
    "$b=[Convert]::FromBase64String($env:TOKENPULSE_DPAPI_IN); " +
    "$o=[System.Security.Cryptography.ProtectedData]::Unprotect($b,$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser); " +
    "[Convert]::ToBase64String($o)";
  const out = await execFileText(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
    { env: { ...process.env, TOKENPULSE_DPAPI_IN: data.toString("base64") }, timeoutMs: 20_000 },
  );
  return Buffer.from(out.trim(), "base64");
}

async function windowsMasterKey(): Promise<Buffer> {
  if (windowsKey) return windowsKey;
  const localState = path.join(cursorUserDir(), "Local State");
  let encoded: string | undefined;
  try {
    const json = JSON.parse(fs.readFileSync(localState, "utf8")) as {
      os_crypt?: { encrypted_key?: string };
    };
    encoded = json.os_crypt?.encrypted_key;
  } catch {
    encoded = undefined;
  }
  if (!encoded) {
    throw new SourceError(`Cursor "Local State" has no os_crypt.encrypted_key (${localState}).`, "setup");
  }
  let wrapped = Buffer.from(encoded, "base64");
  if (wrapped.subarray(0, 5).toString("latin1") === "DPAPI") wrapped = wrapped.subarray(5);
  try {
    windowsKey = await dpapiUnprotect(wrapped);
  } catch {
    throw new SourceError("Windows DPAPI could not unwrap Cursor's safe-storage key.", "auth");
  }
  return windowsKey;
}

async function decryptWindows(blob: Buffer): Promise<string> {
  const prefix = blob.subarray(0, 3).toString("latin1");
  if (prefix === "v10" || prefix === "v11") {
    const key = await windowsMasterKey();
    const nonce = blob.subarray(3, 15);
    const tag = blob.subarray(blob.length - 16);
    const body = blob.subarray(15, blob.length - 16);
    const decipher = crypto.createDecipheriv("aes-256-gcm", key, nonce);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(body), decipher.final()]).toString("utf8");
  }
  // Pre-os_crypt Chromium wrote raw DPAPI blobs.
  return (await dpapiUnprotect(blob)).toString("utf8");
}

function decryptLinux(blob: Buffer): string {
  const key = crypto.pbkdf2Sync("peanuts", "saltysalt", 1, 16, "sha1");
  return decryptCbc(blob, key);
}

/** Plaintext bearer token, or throws SourceError explaining why not. */
export async function decodeCredential(stored: string): Promise<string> {
  if (!stored.startsWith(SAFE_STORAGE_PREFIX)) return stored;
  const payload = Buffer.from(stored.slice(SAFE_STORAGE_PREFIX.length), "base64");
  try {
    let token: string;
    if (process.platform === "darwin") token = decryptCbc(payload, await macDerivedKey());
    else if (process.platform === "win32") token = await decryptWindows(payload);
    else token = decryptLinux(payload);
    if (!token) throw new Error("empty");
    return token;
  } catch (err) {
    if (err instanceof SourceError) throw err;
    if (process.platform === "darwin") macKey = undefined;
    if (process.platform === "win32") windowsKey = undefined;
    throw new SourceError(
      "Cursor's token is encrypted and could not be decrypted on this platform.",
      "auth",
    );
  }
}

export interface CursorToken {
  token: string;
  login: CursorLogin;
  reader: StoredCredential["reader"];
}

/** Reads and (when needed) decrypts Cursor's access token. */
export async function cursorAccessToken(): Promise<CursorToken> {
  const stored = await readStoredCredential();
  const login = classifyCredential(stored.value);
  if (!stored.value || login === "missing") {
    throw new SourceError("Cursor is not signed in on this machine.", "setup");
  }
  const token = await decodeCredential(stored.value);
  return { token, login, reader: stored.reader };
}
