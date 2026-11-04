# TokenPulse

TokenPulse is a tray app for **macOS** and **Windows** that shows how much of your AI allowance is left, and what recent spend looks like, without opening each provider's dashboard.

It is local-first. Claude, Cursor, ChatGPT, OpenAI API, and Grok Bot are separate sources. You turn a source on when you want it. A missing sign-in or a failed refresh leaves the last good numbers in place, then fades them once they are stale. On a Mac, enabled sources can share one combined menu-bar pill, or use separate capsules when you turn off **Shared pill** for a provider. On Windows the same text is in the tray tooltip. Clicking the icon opens a dark Mission Control panel with the details and preferences.

The app is Electron. The original Swift menu-bar app is still in `menubar/` (see [Legacy Swift app](#legacy-swift-app)).


## Menu-bar previews

### Single combined pill

**Shared pill** joins participating providers inside one capsule. It is **off by default**. Turn it on on a provider’s detail page to join the combined pill. Providers left off keep their selected individual styles. While Shared pill is on, the individual **Menu bar style** selector is disabled.

<a href="docs/screenshots/menu-bar-shared-pill.png"><img src="docs/screenshots/menu-bar-shared-pill.png" alt="Single combined pill with ChatGPT, Cursor, and Grok Bot using fictional values" width="354" /></a>

The compact example uses standard provider marks and one reported allowance per source. The all-provider examples below also show separate session/weekly rings and OpenAI balance/spend figures. **Options → Letters inside rings** controls the optional ring labels.

<details>
<summary>Shared-pill combinations and the setting</summary>

<a href="docs/screenshots/menu-bar-shared-options.png"><img src="docs/screenshots/menu-bar-shared-options.png" alt="Shared pill with all five providers, individual opt-out, and ring letters" width="780" /></a>

<a href="docs/screenshots/shared-pill-settings.png"><img src="docs/screenshots/shared-pill-settings.png" alt="Provider settings with Shared pill enabled and individual style disabled" width="780" /></a>

</details>

### Separate provider capsules

All five providers together, using fictional values: **ChatGPT · Cursor · Grok Bot · OpenAI API · Claude**. Each provider can use its own supported layout.

<a href="docs/screenshots/menu-bar-combined.png"><img src="docs/screenshots/menu-bar-combined.png" alt="All five TokenPulse providers in one menu bar" width="780" /></a>

All **seven styles** are shown below. ChatGPT and Claude show separate 5-hour and weekly allowances; Cursor and Grok Bot show their single allowance. OpenAI API uses balance and spend figures, with Divider capsule or Compact stack.

<a href="docs/screenshots/menu-bar.png"><img src="docs/screenshots/menu-bar.png" alt="All seven TokenPulse menu-bar styles" width="540" /></a>

<details>
<summary>Every provider, style, spend layout, appearance, size, and status example</summary>

**Providers**

Every provider appears: ChatGPT, Cursor, Grok Bot, OpenAI API, and Claude. OpenAI shows money rather than quota gauges.

<a href="docs/screenshots/menu-bar-providers.png"><img src="docs/screenshots/menu-bar-providers.png" alt="Every provider appears: ChatGPT, Cursor, Grok Bot, OpenAI API, and Claude. OpenAI shows money rather than quota gauges." width="540" /></a>

**Style Divider**

Divider capsule with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude.

<a href="docs/screenshots/menu-bar-style-divider.png"><img src="docs/screenshots/menu-bar-style-divider.png" alt="Divider capsule with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude." width="540" /></a>

**Style Rings**

Twin gauges with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude.

<a href="docs/screenshots/menu-bar-style-rings.png"><img src="docs/screenshots/menu-bar-style-rings.png" alt="Twin gauges with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude." width="540" /></a>

**Style Baseline**

Baseline meters with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude.

<a href="docs/screenshots/menu-bar-style-baseline.png"><img src="docs/screenshots/menu-bar-style-baseline.png" alt="Baseline meters with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude." width="540" /></a>

**Style Stack**

Compact stack with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude.

<a href="docs/screenshots/menu-bar-style-stack.png"><img src="docs/screenshots/menu-bar-style-stack.png" alt="Compact stack with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude." width="540" /></a>

**Style Focus**

Focus capsule with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude.

<a href="docs/screenshots/menu-bar-style-focus.png"><img src="docs/screenshots/menu-bar-style-focus.png" alt="Focus capsule with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude." width="540" /></a>

**Style Lanes**

Stacked tracks with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude.

<a href="docs/screenshots/menu-bar-style-lanes.png"><img src="docs/screenshots/menu-bar-style-lanes.png" alt="Stacked tracks with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude." width="540" /></a>

**Style Segments**

Segmented lanes with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude.

<a href="docs/screenshots/menu-bar-style-segments.png"><img src="docs/screenshots/menu-bar-style-segments.png" alt="Segmented lanes with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude." width="540" /></a>

**Spend**

Both supported spend layouts for OpenAI balance and ChatGPT, Cursor, and Claude work spend. Dollar figures never use quota gauges.

<a href="docs/screenshots/menu-bar-spend.png"><img src="docs/screenshots/menu-bar-spend.png" alt="Both supported spend layouts for OpenAI balance and ChatGPT, Cursor, and Claude work spend. Dollar figures never use quota gauges." width="540" /></a>

**Appearance**

ChatGPT and OpenAI using the current monochrome marks, with capsule backgrounds on and off.

<a href="docs/screenshots/menu-bar-appearance.png"><img src="docs/screenshots/menu-bar-appearance.png" alt="ChatGPT and OpenAI using the current monochrome marks, with capsule backgrounds on and off." width="540" /></a>

**Sizes**

All eight supported menu-bar sizes, from Normal (100%) to Micro (65%), using the Compact stack style.

<a href="docs/screenshots/menu-bar-sizes.png"><img src="docs/screenshots/menu-bar-sizes.png" alt="All eight supported menu-bar sizes, from Normal (100%) to Micro (65%), using the Compact stack style." width="540" /></a>

**Status**

Healthy, low, exhausted, and stale allowance states using production status and tint logic.

<a href="docs/screenshots/menu-bar-status.png"><img src="docs/screenshots/menu-bar-status.png" alt="Healthy, low, exhausted, and stale allowance states using production status and tint logic." width="540" /></a>

</details>

The labeled sheets enlarge the app’s actual rendered artwork 2× for detail. The neutral backdrops are presentation surfaces, not captures of a personal desktop.

[Full menu-bar gallery and regeneration instructions](docs/menu-bar.md)

## Screenshots

Screenshots of the current Electron interface on macOS, using fictional projects, accounts, jobs, and values. No personal data or live credentials are used.

<a href="docs/screenshots/overview.png"><img src="docs/screenshots/overview.png" alt="TokenPulse main view with sample data" width="780" /></a>

The gallery includes detail views, settings, and available actions. Click an image for the full-resolution capture.

<details>
<summary>View dashboard screenshots</summary>

| Menu Bar | Overview |
| --- | --- |
| <a href="docs/screenshots/menu-bar.png"><img src="docs/screenshots/menu-bar.png" alt="Actual menu-bar renderer with synthetic values, arranged on a presentation backdrop." width="360" /></a><br>Actual menu-bar renderer with synthetic values, arranged on a presentation backdrop. | <a href="docs/screenshots/overview.png"><img src="docs/screenshots/overview.png" alt="Overview with independent 5-hour and weekly allowance meters and sample work spend." width="360" /></a><br>Overview with independent 5-hour and weekly allowance meters and sample work spend. |

| Chatgpt | Cursor |
| --- | --- |
| <a href="docs/screenshots/chatgpt.png"><img src="docs/screenshots/chatgpt.png" alt="Provider details and per-source menu-bar options: ChatGPT." width="360" /></a><br>Provider details and per-source menu-bar options: ChatGPT. | <a href="docs/screenshots/cursor.png"><img src="docs/screenshots/cursor.png" alt="Provider details and per-source menu-bar options: Cursor." width="360" /></a><br>Provider details and per-source menu-bar options: Cursor. |

| Grokbot | Openai |
| --- | --- |
| <a href="docs/screenshots/grokbot.png"><img src="docs/screenshots/grokbot.png" alt="Provider details and per-source menu-bar options: Grok Bot." width="360" /></a><br>Provider details and per-source menu-bar options: Grok Bot. | <a href="docs/screenshots/openai.png"><img src="docs/screenshots/openai.png" alt="Provider details and per-source menu-bar options: OpenAI API." width="360" /></a><br>Provider details and per-source menu-bar options: OpenAI API. |

| Openai Balance | Claude |
| --- | --- |
| <a href="docs/screenshots/openai-balance.png"><img src="docs/screenshots/openai-balance.png" alt="OpenAI balance baseline and credential guidance, scrolled below the key form." width="360" /></a><br>OpenAI balance baseline and credential guidance, scrolled below the key form. | <a href="docs/screenshots/claude.png"><img src="docs/screenshots/claude.png" alt="Provider details and per-source menu-bar options: Claude." width="360" /></a><br>Provider details and per-source menu-bar options: Claude. |

| Spend | Efficiency |
| --- | --- |
| <a href="docs/screenshots/spend.png"><img src="docs/screenshots/spend.png" alt="Combined work-spend chart with recorded and projected totals." width="360" /></a><br>Combined work-spend chart with recorded and projected totals. | <a href="docs/screenshots/efficiency.png"><img src="docs/screenshots/efficiency.png" alt="Efficiency with no scored local sessions in this synthetic example." width="360" /></a><br>Efficiency with no scored local sessions in this synthetic example. |

| Scoreboard | Alerts |
| --- | --- |
| <a href="docs/screenshots/scoreboard.png"><img src="docs/screenshots/scoreboard.png" alt="Scoreboard with no scored local sessions in this synthetic example." width="360" /></a><br>Scoreboard with no scored local sessions in this synthetic example. | <a href="docs/screenshots/alerts.png"><img src="docs/screenshots/alerts.png" alt="Current Alerts screen with no advisories in this sample session." width="360" /></a><br>Current Alerts screen with no advisories in this sample session. |

| Options | Options Bottom |
| --- | --- |
| <a href="docs/screenshots/options.png"><img src="docs/screenshots/options.png" alt="Preferences for appearance, refresh interval, menu-bar scale, and sources." width="360" /></a><br>Preferences for appearance, refresh interval, menu-bar scale, and sources. | <a href="docs/screenshots/options-bottom.png"><img src="docs/screenshots/options-bottom.png" alt="Lower Preferences sections, source shortcuts, and reset/data-folder actions." width="360" /></a><br>Lower Preferences sections, source shortcuts, and reset/data-folder actions. |

| Notifications | Menu Bar Style |
| --- | --- |
| <a href="docs/screenshots/notifications.png"><img src="docs/screenshots/notifications.png" alt="Notification toggles, individual 15/10/5 percent levels, sound, and system settings." width="360" /></a><br>Notification toggles, individual 15/10/5 percent levels, sound, and system settings. | <a href="docs/screenshots/menu-bar-style.png"><img src="docs/screenshots/menu-bar-style.png" alt="Per-provider style preference set to the stacked-track layout." width="360" /></a><br>Per-provider style preference set to the stacked-track layout. |

</details>

The Efficiency and Scoreboard examples show an empty local-session state. Alerts shows its current empty advisory view.

The menu-bar sheet uses the app’s actual drawing code with sample values, arranged on a neutral backdrop. It is not a capture of a personal desktop.

[How these screenshots are made](docs/screenshots/README.md)

---

## Requirements

### Both platforms

- [Node.js](https://nodejs.org/) **20 or newer** (includes `npm`), to build from source
- Git, to clone

### macOS

- macOS **13** (Ventura) or later
- Apple Silicon or Intel (the installer builds for the machine you run it on)

### Windows

- Windows **10** or **11**
- PowerShell 5+ (built in) to run the install script
- Ability to run a locally built, unsigned NSIS installer (SmartScreen may warn on first run)

---

## Install on macOS

```bash
git clone https://github.com/krisrmgua/TokenPulse.git
cd TokenPulse
./scripts/install.sh
```

What `install.sh` does:

1. `npm install`
2. `npm run pack:mac` (electron-builder, output under `release/`)
3. Quits any running TokenPulse (Swift or Electron) and copies the new build to `~/Applications/TokenPulse.app`
4. Ad-hoc signs it as `com.kris.tokenpulse` and clears the quarantine flag
5. Links the `tokenpulse` command into `~/bin`
6. Launches TokenPulse

The first build downloads Electron (about 100 MB) and can take a few minutes. Run `./scripts/install.sh` again to update. Preferences, the OpenAI key, and the spend ledger live in Application Support and survive a reinstall.

Control the installed app with `tokenpulse`:

```bash
tokenpulse status     # process and login start
tokenpulse enable     # start at login (LaunchAgent)
tokenpulse disable    # leave it running, skip the next login
tokenpulse start
tokenpulse stop
```

If `tokenpulse` is not found, add `~/bin` to your `PATH`:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zprofile
```

**Options → Open at login** in the panel does the same job through the macOS login items list. Use one or the other.

### Gatekeeper

This is an ad-hoc local build, not notarized. If macOS blocks it, right-click `TokenPulse.app` → **Open** → **Open**, or allow it under **System Settings → Privacy & Security**.

Reinstalling changes the ad-hoc signature, so macOS may ask for your Mac password the next time TokenPulse reads **Cursor Safe Storage** from the login Keychain. Choose **Always Allow**. That lasts until the next reinstall.

---

## Install on Windows

In PowerShell:

```powershell
git clone https://github.com/krisrmgua/TokenPulse.git
cd TokenPulse
.\scripts\install.ps1
```

If PowerShell blocks scripts:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\scripts\install.ps1
```

What `install.ps1` does:

1. `npm install`
2. `npm run pack:win` (builds an NSIS setup `.exe` under `release\`)
3. Closes a running TokenPulse, then launches the setup wizard and waits for it

TokenPulse shows up in the **system tray** near the clock. Windows often hides new tray icons: click the **^** overflow arrow and drag TokenPulse onto the taskbar. Hover the icon for the per-source summary. Windows cuts tray tooltips at 127 characters, so turn off **Show in tray** for sources you do not need there.

On first run of the setup `.exe`, SmartScreen may say "Windows protected your PC". Choose **More info** → **Run anyway** if you built it yourself.

Turn on **Options → Open at login** to start TokenPulse with Windows.

To update, `git pull` and run `.\scripts\install.ps1` again. To uninstall, use **Settings → Apps → TokenPulse**. Data under `%APPDATA%\TokenPulse` stays until you delete it.

---

## How the panel works

Click the tray or menu-bar icon to open the panel. Right-click it for **Open**, **Refresh now**, and **Quit**. The panel hides when it loses focus. `Esc` hides it, `Cmd/Ctrl+R` refreshes, `Cmd/Ctrl+,` opens Options.

| Area | What it shows |
|---|---|
| **Overview** | A card per source: status, today / month / projected dollars, allowance meters, and the **Enable** and **Show in menu bar / tray** switches |
| **Sidebar** | Each source with a status dot. Green is live, amber is loading or stale, red is an error. Click one for its detail page |
| **Source page** | Where the credential comes from on this machine, every detail line (per-model spend, cache hit rate, credits), and the account picker |
| **Spend** | Combined work spend with a month-to-date chart, plus a per-source table |
| **Options** | Refresh interval, open at login, every source's switches, Cursor allowance, OpenAI Admin key and prepaid balance, data folder, reset |

The **Today / Month / Proj. eom** chips in the tab bar appear once there is work spend. They open the Spend chart. TokenPulse records each day's combined work spend in `spend-ledger.json` as it refreshes. The solid line is recorded month-to-date totals. The dotted line runs from today to projected month-end. Earlier days only appear after TokenPulse has seen them.

Combined work spend is Claude (local transcripts) + Cursor in **Work spend** mode + ChatGPT in **Work credits** mode. OpenAI API spend shows on its own card and in the per-source table, but is not added to the work total.

A new install leaves every provider off. Claude, Cursor, ChatGPT, and Grok Bot start on **Personal**. OpenAI API has no personal mode; it stays org spend. **Reset to defaults** clears source and refresh choices and keeps the saved OpenAI key.

A failed remote fetch keeps the last good value. After about two and a half poll intervals the figures fade. Data older than 30 minutes is dropped.

---

## Credentials

TokenPulse has no account of its own. Each source uses a login you already have, or one key you paste.

| Source | What you need | Notes |
|---|---|---|
| Claude personal | Claude Code signed in on this machine | 5-hour and weekly allowance from `claude` `/usage`, percent left. No Anthropic key is stored |
| Claude work | Claude Code transcripts on this machine | Switch the account to **Work spend**. Scans `~/.claude/projects` and prices them with `pricing.json` |
| Cursor | Cursor signed in on this machine | Reads the Cursor login from its `state.vscdb`. Work mode shows your Dashboard spend; personal mode shows the included allowance as percent left |
| Grok Bot | The same Cursor login | Weekly Sand allowance, as percent left |
| ChatGPT personal | [Codex CLI](https://chatgpt.com/codex) signed in to ChatGPT | 5-hour and weekly allowance, percent left |
| ChatGPT work | The same Codex session, on a workspace that exposes credit usage | Switch the account to **Work credits**. Dollar figure is an estimate |
| OpenAI API | An organization **Admin** key, `sk-admin-…` | Turning it on asks for the key under Options |

### Cursor and Grok Bot

The Cursor login lives at:

| OS | Path |
|---|---|
| macOS | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| Windows | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` |

TokenPulse opens it read-only. When Cursor encrypted the token, macOS needs the **Cursor Safe Storage** password from the login Keychain (that is the Mac password sheet), and Windows unwraps it with DPAPI for your user. Turning Cursor and Grok Bot off stops those reads.

The default personal Cursor allowance is $20. Change it under **Options → Cursor**.

### ChatGPT

Install Codex and sign in once:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex
```

The search path is `TOKENPULSE_CODEX_PATH`, then the usual install locations (`~/.local/bin`, `~/bin`, Homebrew on Mac; `%LOCALAPPDATA%\Programs\codex` and npm's global folder on Windows). Work mode reads workspace credits for the signed-in account. If the workspace does not publish a dollar rate, TokenPulse uses the public rate card ($0.04 per credit).

### OpenAI Admin key

Create the key in [OpenAI Platform](https://platform.openai.com/) under **Organization → Admin keys**. A normal `sk-proj-` key is rejected. Paste it in **Options → OpenAI API** and click **Save and test**. TokenPulse checks it against the Costs API before turning the source on. A key that fails auth is not kept.

The key is a file in the TokenPulse data folder, `openai-admin-api-key`. On macOS the file is mode `600`, the folder is `700`, and Time Machine is asked to skip it. On Windows the folder is under your user profile. The key is not written to git, prefs, or logs. The filename matches the Swift ad-hoc build, so an existing key carries over.

**Current prepaid balance** records the balance you see in OpenAI Billing. TokenPulse subtracts newly reported costs from it. Set it again after you add credits. OpenAI's cost API lags, so the Billing page stays the source of truth.

---

## Data

| OS | Folder |
|---|---|
| macOS | `~/Library/Application Support/TokenPulse/` |
| Windows | `%APPDATA%\TokenPulse\` |

| File | What |
|---|---|
| `prefs.json` | Source switches, accounts, refresh interval, balance baseline |
| `spend-ledger.json` | Daily combined work spend, same shape the Swift app writes |
| `openai-admin-api-key` | OpenAI Admin key, when saved |
| `pricing.json` | Optional override for model rates. Falls back to the bundled copy |

**Options → Open folder** opens it. `TOKENPULSE_PRICING=/path/to/pricing.json` points at a different rate file.

Bundle / app id: `com.kris.tokenpulse`.

---

## Develop

```bash
npm install
npm run dev
```

`npm run dev` compiles the main process, starts the Vite UI on `http://127.0.0.1:5173`, and launches Electron with `TOKENPULSE_DEV=1`. In dev the panel does not hide on blur, so it is easier to inspect.

| Script | Purpose |
|---|---|
| `npm run build` | Production UI + Electron compile |
| `npm run typecheck` | Type-check the panel and Vite config |
| `npm start` | Build, then run Electron against `dist/` |
| `npm run pack:mac` | macOS `.app` + zip under `release/` |
| `npm run pack:win` | Windows NSIS installer under `release/` |
| `npm run pack` | Both (needs a toolchain that can build both) |

## Layout

| Path | What |
|---|---|
| `electron/` | Main process: tray, panel window, refresh engine, prefs, ledger |
| `electron/sources/` | One reader per provider (Claude, Cursor, ChatGPT, OpenAI, Grok Bot) |
| `src/ui/` | Panel HTML, CSS, and TypeScript |
| `scripts/` | `install.sh` (macOS), `install.ps1` (Windows) |
| `pricing.json` | Public model rates for the local transcript scan |
| `bin/tokenpulse` | macOS start, stop, and login-start control |
| `menubar/` | Legacy Swift menu-bar app |

## Legacy Swift app

`menubar/` is the original SwiftPM menu-bar app. It retains historical features such as the optional spend proxy and the `--*-check` command-line probes. The current Electron app uses monochrome provider marks. Build it with:

```bash
cd menubar
./install.sh
```

`./install.sh` replaces `~/Applications/TokenPulse.app` with the Swift build (same bundle id as Electron), so only one of those two can own that path.

To run Swift **alongside** Electron for visual compare:

```bash
cd menubar
./install-alongside-electron.sh
```

That installs `~/Applications/TokenPulse-Swift.app` (`com.kris.tokenpulse.swift`) without touching the Electron app or its LaunchAgent. Quit Swift when done: `pkill -f 'TokenPulse-Swift.app/Contents/MacOS/TokenPulse'`.

## Version

The shipping version is `package.json` → `version` (currently **0.5.51**). The panel shows it as `v0.5.51` in Options and in the footer. Bump that field before each release you push and package; Electron Builder embeds it so `app.getVersion()` matches.

## License

[MIT](LICENSE). Copyright 2026 Kristopher Simmons.
