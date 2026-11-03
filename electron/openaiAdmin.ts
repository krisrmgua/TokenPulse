import fs from "node:fs";
import path from "node:path";
import { excludeFromBackup, restrictDir, restrictFile } from "./fsSecure";

/** Same filename the Swift ad-hoc build uses, so an existing key carries over on macOS. */
const KEY_FILE = "openai-admin-api-key";
const ADMIN_PREFIX = "sk-admin-";

export function isValidAdminKeyFormat(raw: string): boolean {
  const key = raw.trim();
  return key.startsWith(ADMIN_PREFIX) && key.length > ADMIN_PREFIX.length;
}

export class OpenAIKeyStore {
  private cached: string | null | undefined;

  constructor(private readonly dir: string) {}

  get file(): string {
    return path.join(this.dir, KEY_FILE);
  }

  isConfigured(): boolean {
    if (this.cached) return true;
    return fs.existsSync(this.file);
  }

  read(): string | null {
    if (this.cached !== undefined) return this.cached;
    try {
      restrictFile(this.file);
      const key = fs.readFileSync(this.file, "utf8").trim();
      this.cached = key.length > 0 ? key : null;
    } catch {
      this.cached = null;
    }
    return this.cached;
  }

  save(raw: string): { ok: true } | { ok: false; error: string } {
    const key = raw.trim();
    if (!isValidAdminKeyFormat(key)) {
      return {
        ok: false,
        error: "That is not an Admin key. It must start with sk-admin-.",
      };
    }
    try {
      fs.mkdirSync(this.dir, { recursive: true });
      restrictDir(this.dir);
      const tmp = `${this.file}.tmp`;
      fs.writeFileSync(tmp, key, { encoding: "utf8", mode: 0o600 });
      restrictFile(tmp, { sync: true });
      fs.renameSync(tmp, this.file);
      restrictFile(this.file, { sync: true });
      excludeFromBackup(this.file);
    } catch (err) {
      try {
        fs.rmSync(this.file, { force: true });
      } catch {
        // ignore
      }
      return {
        ok: false,
        error: `Could not write the key file (${(err as Error).message}).`,
      };
    }
    this.cached = key;
    return { ok: true };
  }

  delete(): void {
    this.cached = null;
    try {
      fs.rmSync(this.file, { force: true });
    } catch {
      // ignore
    }
  }
}
