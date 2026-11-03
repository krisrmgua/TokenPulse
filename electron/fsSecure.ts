import fs from "node:fs";
import { execFile, execFileSync } from "node:child_process";

function windowsAccount(): string | undefined {
  const user = process.env.USERNAME;
  if (!user) return undefined;
  const domain = process.env.USERDOMAIN;
  return domain ? `${domain}\\${user}` : user;
}

/**
 * Owner-only file. POSIX: mode 600. Windows: drop inherited ACEs and grant
 * only the current user full control (best-effort; icacls failure is ignored).
 */
export function restrictFile(file: string, opts: { sync?: boolean } = {}): void {
  if (process.platform === "win32") {
    const account = windowsAccount();
    if (!account) return;
    const args = [file, "/inheritance:r", "/grant:r", `${account}:F`];
    if (opts.sync) {
      try {
        execFileSync("icacls", args, { windowsHide: true, stdio: "ignore" });
      } catch {
        // Best-effort: NTFS user-profile ACLs already exclude other users.
      }
    } else {
      execFile("icacls", args, { windowsHide: true }, () => {});
    }
    return;
  }
  try {
    fs.chmodSync(file, 0o600);
  } catch {
    // File may have been removed concurrently.
  }
}

export function restrictDir(dir: string): void {
  if (process.platform === "win32") return;
  try {
    fs.chmodSync(dir, 0o700);
  } catch {
    // Directory may not exist yet.
  }
}

/** Ask Time Machine to skip a secret file (macOS only, best-effort). */
export function excludeFromBackup(file: string): void {
  if (process.platform !== "darwin") return;
  execFile("/usr/bin/tmutil", ["addexclusion", file], () => {});
}
