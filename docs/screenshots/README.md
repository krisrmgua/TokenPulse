# Screenshot gallery

Screenshots of the current Electron interface on macOS, using fictional projects, accounts, jobs, and values. No personal data or live credentials are used.

These are captures of `dist/index.html` built from the repository’s actual `src/ui` code. The layout, typography, colors, controls, and dialogs come from the app. A separate Electron entry point supplies synthetic state through a mock preload bridge; it never starts the production main process. Network requests are blocked, and application data goes to a temporary directory. Actions such as run, delete, merge, refresh, and save are inert.

No installed app, sign-in, API key, real repository scan, market-data request, or scheduled command is needed. Example stock prices, allowance percentages, balances, and positions are illustrative. There are no AI-generated interface images.

Captured from version **0.5.49**, source revision `058831b`.


## Menu-bar icons and views

[Open the complete menu-bar gallery](../menu-bar.md), including the actual icon artwork and supported display states.


## Recreate

From the repository root, after installing dependencies:

```bash
npm install
npm run build:ui
npm run build:electron
npx electron scripts/screenshots.cjs
```

Run this on macOS with a graphical session for the same fonts and platform controls. The capture window is hidden and uses a 2× device scale. Other platforms can render different fonts and native controls. Dates and relative times are sample data and may differ when recaptured.

`scripts/screenshots/fixture.cjs` defines every sample and the click sequence. `preload.cjs` provides the isolated mock bridge. `manifest.json` lists each image, its purpose, and its pixel size. Do not replace the fixture bridge with the production preload when capturing public documentation.

## Current limitations shown accurately

Efficiency is not wired to session scoring in this Electron build. Scoreboard is an empty shell, and Alerts has no populated advisory history in this capture. The notification preferences screen is captured; these docs do not simulate an OS-delivered notification banner.

## Menu-bar sheet

`menu.cjs` calls the production menu-bar renderer with synthetic values and arranges the rendered PNGs on a labeled background. This sheet demonstrates the actual styles without exposing the rest of a desktop.

## Views

### Menu Bar

Actual menu-bar renderer with synthetic values, arranged on a presentation backdrop.

![Actual menu-bar renderer with synthetic values, arranged on a presentation backdrop.](menu-bar.png)

### Overview

Overview with independent 5-hour and weekly allowance meters and sample work spend.

![Overview with independent 5-hour and weekly allowance meters and sample work spend.](overview.png)

### Chatgpt

Provider details and per-source menu-bar options: ChatGPT.

![Provider details and per-source menu-bar options: ChatGPT.](chatgpt.png)

### Cursor

Provider details and per-source menu-bar options: Cursor.

![Provider details and per-source menu-bar options: Cursor.](cursor.png)

### Grokbot

Provider details and per-source menu-bar options: Grok Bot.

![Provider details and per-source menu-bar options: Grok Bot.](grokbot.png)

### Openai

Provider details and per-source menu-bar options: OpenAI API.

![Provider details and per-source menu-bar options: OpenAI API.](openai.png)

### Openai Balance

OpenAI balance baseline and credential guidance, scrolled below the key form.

![OpenAI balance baseline and credential guidance, scrolled below the key form.](openai-balance.png)

### Claude

Provider details and per-source menu-bar options: Claude.

![Provider details and per-source menu-bar options: Claude.](claude.png)

### Spend

Combined work-spend chart with recorded and projected totals.

![Combined work-spend chart with recorded and projected totals.](spend.png)

### Efficiency

Current Efficiency screen; the engine is not wired in this Electron build.

![Current Efficiency screen; the engine is not wired in this Electron build.](efficiency.png)

### Scoreboard

Current Scoreboard shell with its empty session state and badge list.

![Current Scoreboard shell with its empty session state and badge list.](scoreboard.png)

### Alerts

Current Alerts screen with no advisories in this sample session.

![Current Alerts screen with no advisories in this sample session.](alerts.png)

### Options

Preferences for appearance, refresh interval, menu-bar scale, and sources.

![Preferences for appearance, refresh interval, menu-bar scale, and sources.](options.png)

### Options Bottom

Lower Preferences sections, source shortcuts, and reset/data-folder actions.

![Lower Preferences sections, source shortcuts, and reset/data-folder actions.](options-bottom.png)

### Notifications

Notification toggles, individual 15/10/5 percent levels, sound, and system settings.

![Notification toggles, individual 15/10/5 percent levels, sound, and system settings.](notifications.png)

### Menu Bar Style

Per-provider style preference set to the stacked-track layout.

![Per-provider style preference set to the stacked-track layout.](menu-bar-style.png)
