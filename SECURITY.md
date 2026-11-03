# Security

TokenPulse reads usage from tools that are already signed in on your machine. It should not become a second place where those secrets are copied around.

## Reporting

Open a GitHub issue, or contact the maintainer, for a vulnerability in this repository. Do not paste API keys, access tokens, `auth.json`, `state.vscdb`, Keychain items, or job logs. Describe the file, the behavior, and the impact.

## What the app stores

| Secret | Where | Who writes it |
|---|---|---|
| OpenAI Admin key (`sk-admin-…`) | Electron, macOS: `~/Library/Application Support/TokenPulse/openai-admin-api-key`, mode `600`, folder mode `700`, Time Machine exclusion. Electron, Windows: `%APPDATA%\TokenPulse\openai-admin-api-key`, inheritance removed and only the current user granted access with `icacls` (best-effort; if `icacls` fails the file keeps the default user-profile ACL). Swift ad-hoc builds: same macOS file. Swift signed builds: login Keychain `com.kris.tokenpulse.openai` / `admin-api-key`. | TokenPulse, only after you save a key |
| Preferences and the estimated OpenAI balance | Electron: `prefs.json` in the TokenPulse data folder, owner-only. Swift: UserDefaults `com.kris.tokenpulse`. | TokenPulse |
| Spend ledger | `spend-ledger.json` in the TokenPulse data folder, owner-only | TokenPulse |
| ChatGPT, Claude, Cursor, and Grok credentials | Left in Codex, Claude Code, and Cursor. TokenPulse reads them on refresh, keeps them in memory, and does not write them to its own files. | Those apps |

Owner-only files block other users of the machine. Any program you run as yourself can still read files in your home directory.

## Cursor token decryption

- **macOS (Electron build)** reads the **Cursor Safe Storage** password through `/usr/bin/security`. The macOS prompt is on behalf of `security`, not TokenPulse. Answer **Allow**, not **Always Allow**: "Always Allow" adds `/usr/bin/security` to that Keychain item's access list, after which any script running as you can read it without a prompt. TokenPulse keeps the derived key in memory for the life of the process, so you are asked once per launch.
- **macOS (Swift build)** reads the same item through the Security framework, so "Always Allow" there applies to the TokenPulse binary only (until the next ad-hoc reinstall changes its signature).
- **Windows** unwraps Cursor's `os_crypt` key with DPAPI (CurrentUser scope) by running `powershell.exe` with the wrapped key passed in an environment variable, not on the command line. The unwrapped key stays in memory.
- `state.vscdb` is opened read-only. TokenPulse never writes Cursor's database.

## What a first enable does

- **OpenAI:** if no Admin key is saved, Enable opens the key form. The key is checked against `https://api.openai.com` and is not printed. A key OpenAI rejects is deleted again.
- **Cursor and Grok Bot:** these use the Cursor login already on the machine. If it is encrypted, macOS asks for your login password (see above); Windows uses DPAPI silently. If Cursor is not signed in, the card says so.
- **ChatGPT and Claude:** Enable starts a read of the local CLI session or transcripts. There is no separate key to save.

## Network

Calls go only to the provider that owns the source: `api.openai.com`, `chatgpt.com`, and `api2.cursor.sh` (plus an optional proxy URL in the Swift build). OpenAI pagination values that contain a URL, `..`, a newline, or a leading `/` are dropped, and the request host is checked to stay `api.openai.com`. The panel only opens `https://` links externally.

## Out of scope

The app is not sandboxed. That is required so it can read Codex, Claude, and Cursor files in your home directory. A local program running as you has the same access whether or not TokenPulse is installed. The Electron installer and app bundle are not code-signed with a publisher identity.
