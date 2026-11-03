# Security

TokenPulse reads usage from tools that are already signed in on your Mac. It should not become a second place where those secrets are copied around.

## Reporting

Open a GitHub issue, or contact the maintainer, for a vulnerability in this repository. Do not paste API keys, access tokens, `auth.json`, Keychain items, or job logs. Describe the file, the behavior, and the impact.

## What the app stores

| Secret | Where | Who writes it |
|---|---|---|
| OpenAI Admin key (`sk-admin-…`) | Ad-hoc local builds: `~/Library/Application Support/TokenPulse/openai-admin-api-key`, mode `600`, folder mode `700`, excluded from backup. Signed builds with a stable identity: login Keychain service `com.kris.tokenpulse.openai`, account `admin-api-key`, this device only. | TokenPulse, only after you choose **Set Admin API key…** |
| Usage history | `~/Library/Application Support/TokenPulse/history.json`, mode `600` | TokenPulse |
| Preferences and the estimated OpenAI balance | UserDefaults domain `com.kris.tokenpulse` | TokenPulse |
| ChatGPT, Claude, Cursor, and Grok credentials | Left in Codex, the Claude CLI, and Cursor. TokenPulse reads them and does not copy them into its own files. | Those apps |
| Optional proxy key | A path you set. Default lookup is `~/.config/tokenpulse/proxy-keys.json`. | You or your proxy CLI |

The OpenAI key is a file on ad-hoc builds because each rebuild changes the code signature, and macOS Keychain would ask for your Mac password every time. Mode `600` blocks other users of the Mac. Any program you run as yourself can still read files in your home directory.

## What a first enable does

- **OpenAI:** if no Admin key is saved, Enable opens the save sheet. Cancel leaves Enable off. The key is checked against `https://api.openai.com` and is not printed.
- **Cursor and Grok Bot:** these use the Cursor login already on the Mac. TokenPulse does not ask you to paste a token. If that login is encrypted, macOS asks for your Mac password so this app can read the **Cursor Safe Storage** Keychain item. **Always Allow** lasts until the next reinstall, because an ad-hoc signature changes. If Cursor is not signed in, Enable stays off.
- **ChatGPT and Claude:** Enable starts a read of the local CLI session. There is no separate key to save in TokenPulse.

## Network

Spend and allowance calls go to the provider that owns that source: `api.openai.com`, `chatgpt.com`, `api2.cursor.sh`, or an optional proxy URL you configured. OpenAI pagination values that contain a URL, `..`, or a newline are dropped, and the request host stays `api.openai.com`. The optional proxy URL must be `https`.

## Out of scope

This app is not sandboxed. That is required so it can read Codex, Claude, and Cursor files in your home directory. A local program running as you has the same access whether or not TokenPulse is installed.
