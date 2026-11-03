# TokenPulse

TokenPulse is a macOS menu-bar app that shows how much of your AI allowance is left, and what recent API spend looks like, without opening each provider's dashboard.

It is local-first. ChatGPT, Claude, Cursor, Grok Bot, and OpenAI are separate sources. You turn a source on when you want it. A missing sign-in or a failed refresh leaves the last good numbers in place, then fades them once they are stale. The menu bar shows one block per enabled source. Clicking the menu bar opens a dark Mission Control panel for the details and preferences.

Requires **macOS 13** or later and the Swift command-line tools.

## Install

```bash
git clone https://github.com/krisrmgua/TokenPulse.git
cd TokenPulse/menubar
./install.sh
```

That builds `TokenPulse.app`, copies it to `~/Applications/TokenPulse.app`, and starts it at login. Run `./install.sh` again to update. The installer keeps your previous login-start choice when one already exists.

Control the installed app with the `tokenpulse` command the installer links into `~/bin`:

```bash
tokenpulse status     # process and login start
tokenpulse enable     # start at login
tokenpulse disable    # leave it running, skip the next login
tokenpulse start
tokenpulse stop
```

If `tokenpulse` is not found, add `~/bin` to your `PATH`:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zprofile
```

A manual build, without installing, is `cd menubar && ./make-app.sh && open TokenPulse.app`. Login start still uses the copy in `~/Applications`.

The bundle id is `com.kris.tokenpulse`. Preferences, the menu-bar position, and the login item all use that id. Reinstalling an ad-hoc build changes the code signature, so macOS may ask for your Mac password the next time Cursor or Grok Bot reads the login Keychain. Choose **Always Allow**. That permission lasts until the next reinstall.

## How the panel works

The menu-bar item opens on the overview. **Options → Reopen where I left off** is off by default, so the next open returns to the overview. Turn it on to stay on the screen you last used.

Each provider has **Enable** and **Show in Menu**. Enable turns the data source on. Show in Menu puts its block on the menu bar. ChatGPT and OpenAI start off. Cursor and Claude start on.

**Options → Menu bar style** picks the capsule layout. The default is **1 · Divider capsule**. **Themed provider logos** is on. **Dark menu-bar background** draws a navy capsule behind each block. When any allowance meter on that block hits 0%, including a 5-hour window, that capsule turns a dark red.

**Spend colors** is off until you turn it on. Each source then has its own green / yellow / orange / red steps.

**Reset to defaults** clears layout and visibility choices. It keeps saved API keys.

## Credentials

TokenPulse does not have one account of its own. Each source uses a login you already have, or one key you paste. Turning a source on is what asks for it.

| Source | What you need | What happens the first time you enable it |
|---|---|---|
| OpenAI API | An organization **Admin** key, `sk-admin-…` | The save sheet opens. **Save and test** stores it on this Mac and checks it. Cancel leaves Enable off. |
| Cursor | Cursor signed in on this Mac | TokenPulse uses that login. It does not ask you to paste a token. macOS may ask for your Mac password to read **Cursor Safe Storage**. |
| Grok Bot | The same Cursor login | Same prompt as Cursor. Grok Bot and Cursor share one sign-in. |
| ChatGPT personal | [Codex CLI](https://chatgpt.com/codex) signed in to ChatGPT | Enable starts a read of that session. No key is stored in TokenPulse. |
| ChatGPT work | The same Codex session, on a workspace that exposes credit usage | Switch **Account → Work credits**. The token stays in `~/.codex/auth.json`. |
| Claude personal | [Claude Code](https://claude.ai/install.sh) signed in with `/login` | Enable runs the CLI's `/usage` view. Desktop Claude by itself is not enough. |
| Claude work | Local Claude Code transcripts, plus an optional proxy you configure | Enable scans `~/.claude/projects`. No Anthropic API key is stored. |

### OpenAI Admin key

Create the key in [OpenAI Platform](https://platform.openai.com/) under **Organization → Admin keys**. A normal `sk-proj-` inference key will be rejected.

On a local ad-hoc install the key is stored at:

`~/Library/Application Support/TokenPulse/openai-admin-api-key`

The file is mode `600`, the folder is mode `700`, and Time Machine is asked to skip it. A build signed with a stable identity stores the same key in the login Keychain instead (`com.kris.tokenpulse.openai` / `admin-api-key`, this device only). The key is not written to git, UserDefaults, or the log.

**Options → OpenAI API → Set current prepaid balance…** records the balance you see in OpenAI Billing. TokenPulse subtracts newly reported organization costs from that number. Reset it after you add credits. OpenAI's cost API lags, so the Billing page stays the source of truth.

Verify without printing the key:

```bash
~/Applications/TokenPulse.app/Contents/MacOS/TokenPulse --openai-check
```

### Cursor and Grok Bot

Sign in to Cursor. TokenPulse reads `cursorAuth/accessToken` from:

`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`

When Cursor encrypted that token, reading it needs the **Cursor Safe Storage** password from your login Keychain. That is the Mac password sheet. It is not an OpenAI prompt, and disabling OpenAI does not stop it. Turning Cursor and Grok Bot off does.

Work mode shows today's and this month's Dashboard spend for your user id, not a team-wide total. Personal mode shows the included Pro allowance as percent remaining. The default personal allowance is $20. Change it under **Options → Cursor**.

Grok Bot shows the weekly Sand allowance from the same Cursor account, as percent left.

```bash
~/Applications/TokenPulse.app/Contents/MacOS/TokenPulse --cursor-check
~/Applications/TokenPulse.app/Contents/MacOS/TokenPulse --grok-bot-check
```

### ChatGPT

Install Codex and sign in once:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex
```

Finish ChatGPT sign-in, then `/status` should show the weekly allowance. TokenPulse reads that same allowance. Personal mode shows percent left and the local reset time. The search path is `TOKENPULSE_CODEX_PATH`, `~/.local/bin/codex`, `~/bin/codex`, Homebrew, then the Codex binary inside the ChatGPT app.

Work mode reads workspace credit usage for the signed-in Codex account and shows an API-equivalent dollar estimate. That figure is an estimate, not an invoice. If the workspace does not publish a dollar rate, TokenPulse uses the public rate card ($0.04 per credit).

```bash
~/Applications/TokenPulse.app/Contents/MacOS/TokenPulse --chatgpt-check
~/Applications/TokenPulse.app/Contents/MacOS/TokenPulse --chatgpt-work-check
```

### Claude

Work mode prices local transcripts under `~/.claude/projects` with `pricing.json`. Personal mode needs the Claude Code CLI:

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude
```

Complete `/login` with the Pro or Max account, then `/usage`. TokenPulse drives that same `/usage` view. It does not read Claude's OAuth token. The search path is `TOKENPULSE_CLAUDE_PATH`, `~/.local/bin/claude`, `~/bin/claude`, Homebrew, then the Claude Code binary bundled with the desktop app.

```bash
~/Applications/TokenPulse.app/Contents/MacOS/TokenPulse --claude-check
```

### Optional spend proxy

If you have an HTTPS endpoint that returns your own model spend, TokenPulse can replace the local Today / Month totals with that response. There is no built-in host. Set both of these outside the repo:

- `TOKENPULSE_PROXY_SPEND_URL`, or one `https://` URL in `~/Library/Application Support/TokenPulse/proxy-spend-url`
- `TOKENPULSE_PROXY_KEYS_FILE`, or a file path in `~/Library/Application Support/TokenPulse/proxy-keys-path`

The key file is JSON: `{ "staging": { "api_key": "…", "expires": "RFC3339" } }`. If you set neither path, TokenPulse looks at `~/.config/tokenpulse/proxy-keys.json`. No URL, or an expired key, means the proxy stays off.

```bash
~/Applications/TokenPulse.app/Contents/MacOS/TokenPulse --proxy-check
```

## Preferences worth knowing

| Item | Default |
|---|---|
| Display | Per source |
| Menu bar style | 1 · Divider capsule |
| Themed logos | On |
| Dark menu-bar background | On |
| Spend colors | Off |
| Increase menu bar size | Off |
| Reopen where I left off | Off |
| Usage refresh | 1 minute for the fast poll. Remote sources also wait at least a few minutes between network calls. |
| Cursor / Claude | On, work spend |
| ChatGPT / OpenAI / Grok Bot | Off |

A failed remote fetch keeps the last good value. After about two and a half poll intervals the figures fade until a refresh succeeds.

Notifications, when you turn them on, use the title **TokenPulse**. Allowance alerts and an Opus-share alert are separate switches under Options.

## Develop

```bash
cd menubar
swift run TokenPulse --selftest
swift run TokenPulse --help
swift test    # needs full Xcode; Command Line Tools can run --selftest only
```

`--print` writes a local JSON rollup and does not call the network. Preview flags such as `--menu-preview` need an output path.

Use the installed binary, not `swift run`, when you want to read or change preferences. `swift run` uses a different defaults domain than `com.kris.tokenpulse`.

```bash
# Quit the app first.
~/Applications/TokenPulse.app/Contents/MacOS/TokenPulse --reset-options
```

## Layout

| Path | What |
|---|---|
| `menubar/` | Swift Package Manager app |
| `pricing.json` | Public model rates for the local transcript scan |
| `bin/tokenpulse` | start, stop, and login-start control |
| `menubar/Artwork/` | Menu-bar icon |

## License

[MIT](LICENSE). Copyright 2026 Kristopher Simmons.
