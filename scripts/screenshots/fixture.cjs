// Synthetic documentation fixtures. No accounts, credentials, or live services.
const fs = require('node:fs');
const path = require('node:path');
const image = relative => 'data:image/png;base64,' + fs.readFileSync(path.join(__dirname, '../..', relative)).toString('base64');
module.exports = {
  "bridge": "tokenpulse",
  "width": 780,
  "minHeight": 460,
  "maxHeight": 800,
  "state": {
    "sources": [
      {
        "id": "chatgpt",
        "name": "ChatGPT",
        "enabled": true,
        "showInTray": true,
        "account": "personal",
        "accounts": [
          "personal",
          "work"
        ],
        "status": "ok",
        "fetchedAt": "2026-11-04T15:49:28.428689+00:00",
        "meters": [
          {
            "id": "session",
            "label": "5-hour",
            "percentLeft": 78,
            "resetAt": "2026-11-04T18:19:28.428689+00:00"
          },
          {
            "id": "weekly",
            "label": "Weekly",
            "percentLeft": 42,
            "resetAt": "2026-11-07T23:49:28.428689+00:00"
          }
        ],
        "lines": [
          {
            "label": "Sample account",
            "value": "Personal allowance"
          }
        ],
        "credential": "Demo data \u2014 no provider account connected.",
        "resetNote": null
      },
      {
        "id": "cursor",
        "name": "Cursor",
        "enabled": true,
        "showInTray": true,
        "account": "work",
        "accounts": [
          "personal",
          "work"
        ],
        "status": "ok",
        "fetchedAt": "2026-11-04T15:49:28.428689+00:00",
        "meters": [],
        "lines": [
          {
            "label": "Model",
            "value": "demo-model"
          },
          {
            "label": "Work spend",
            "value": "$12.20"
          }
        ],
        "credential": "Demo data \u2014 no provider account connected.",
        "resetNote": null,
        "todayUSD": 2.4,
        "monthUSD": 12.2,
        "projectedUSD": 91.5
      },
      {
        "id": "grokbot",
        "name": "Grok Bot",
        "enabled": true,
        "showInTray": true,
        "account": "personal",
        "accounts": [
          "personal"
        ],
        "status": "ok",
        "fetchedAt": "2026-11-04T15:49:28.428689+00:00",
        "meters": [
          {
            "id": "weekly",
            "label": "Weekly",
            "percentLeft": 56,
            "resetAt": "2026-11-09T15:49:28.428689+00:00"
          }
        ],
        "lines": [
          {
            "label": "Sample account",
            "value": "Personal allowance"
          }
        ],
        "credential": "Demo data \u2014 no provider account connected.",
        "resetNote": null
      },
      {
        "id": "openai",
        "name": "OpenAI API",
        "enabled": true,
        "showInTray": true,
        "account": "work",
        "accounts": [
          "work"
        ],
        "status": "ok",
        "fetchedAt": "2026-11-04T15:49:28.428689+00:00",
        "meters": [],
        "lines": [
          {
            "label": "Estimated balance",
            "value": "$24.15"
          },
          {
            "label": "Costs today",
            "value": "$0.32"
          },
          {
            "label": "Costs this month",
            "value": "$4.85"
          }
        ],
        "credential": "Demo data \u2014 no provider account connected.",
        "resetNote": "No scheduled reset",
        "todayUSD": 0.32,
        "monthUSD": 4.85,
        "projectedUSD": 36.38
      },
      {
        "id": "claude",
        "name": "Claude",
        "enabled": true,
        "showInTray": true,
        "account": "personal",
        "accounts": [
          "personal",
          "work"
        ],
        "status": "ok",
        "fetchedAt": "2026-11-04T15:49:28.428689+00:00",
        "meters": [
          {
            "id": "session",
            "label": "5-hour",
            "percentLeft": 64,
            "resetAt": "2026-11-04T18:19:28.428689+00:00"
          },
          {
            "id": "weekly",
            "label": "Weekly",
            "percentLeft": 85,
            "resetAt": "2026-11-07T23:49:28.428689+00:00"
          }
        ],
        "lines": [
          {
            "label": "Sample account",
            "value": "Personal allowance"
          }
        ],
        "credential": "Demo data \u2014 no provider account connected.",
        "resetNote": null
      }
    ],
    "combined": {
      "todayUSD": 2.4,
      "monthUSD": 12.2,
      "projectedUSD": 91.5
    },
    "chart": [
      {
        "day": 1,
        "date": "2026-11-01",
        "actualUSD": 3.05,
        "projectedUSD": null,
        "isToday": false
      },
      {
        "day": 2,
        "date": "2026-11-02",
        "actualUSD": 6.1,
        "projectedUSD": null,
        "isToday": false
      },
      {
        "day": 3,
        "date": "2026-11-03",
        "actualUSD": 9.149999999999999,
        "projectedUSD": null,
        "isToday": false
      },
      {
        "day": 4,
        "date": "2026-11-04",
        "actualUSD": 12.2,
        "projectedUSD": 12.2,
        "isToday": true
      },
      {
        "day": 5,
        "date": "2026-11-05",
        "actualUSD": null,
        "projectedUSD": 15.25,
        "isToday": false
      },
      {
        "day": 6,
        "date": "2026-11-06",
        "actualUSD": null,
        "projectedUSD": 18.299999999999997,
        "isToday": false
      },
      {
        "day": 7,
        "date": "2026-11-07",
        "actualUSD": null,
        "projectedUSD": 21.349999999999998,
        "isToday": false
      },
      {
        "day": 8,
        "date": "2026-11-08",
        "actualUSD": null,
        "projectedUSD": 24.4,
        "isToday": false
      },
      {
        "day": 9,
        "date": "2026-11-09",
        "actualUSD": null,
        "projectedUSD": 27.45,
        "isToday": false
      },
      {
        "day": 10,
        "date": "2026-11-10",
        "actualUSD": null,
        "projectedUSD": 30.499999999999996,
        "isToday": false
      },
      {
        "day": 11,
        "date": "2026-11-11",
        "actualUSD": null,
        "projectedUSD": 33.55,
        "isToday": false
      },
      {
        "day": 12,
        "date": "2026-11-12",
        "actualUSD": null,
        "projectedUSD": 36.599999999999994,
        "isToday": false
      },
      {
        "day": 13,
        "date": "2026-11-13",
        "actualUSD": null,
        "projectedUSD": 39.65,
        "isToday": false
      },
      {
        "day": 14,
        "date": "2026-11-14",
        "actualUSD": null,
        "projectedUSD": 42.7,
        "isToday": false
      },
      {
        "day": 15,
        "date": "2026-11-15",
        "actualUSD": null,
        "projectedUSD": 45.75,
        "isToday": false
      },
      {
        "day": 16,
        "date": "2026-11-16",
        "actualUSD": null,
        "projectedUSD": 48.8,
        "isToday": false
      },
      {
        "day": 17,
        "date": "2026-11-17",
        "actualUSD": null,
        "projectedUSD": 51.849999999999994,
        "isToday": false
      },
      {
        "day": 18,
        "date": "2026-11-18",
        "actualUSD": null,
        "projectedUSD": 54.89999999999999,
        "isToday": false
      },
      {
        "day": 19,
        "date": "2026-11-19",
        "actualUSD": null,
        "projectedUSD": 57.95,
        "isToday": false
      },
      {
        "day": 20,
        "date": "2026-11-20",
        "actualUSD": null,
        "projectedUSD": 61.0,
        "isToday": false
      },
      {
        "day": 21,
        "date": "2026-11-21",
        "actualUSD": null,
        "projectedUSD": 64.05,
        "isToday": false
      },
      {
        "day": 22,
        "date": "2026-11-22",
        "actualUSD": null,
        "projectedUSD": 67.1,
        "isToday": false
      },
      {
        "day": 23,
        "date": "2026-11-23",
        "actualUSD": null,
        "projectedUSD": 70.14999999999999,
        "isToday": false
      },
      {
        "day": 24,
        "date": "2026-11-24",
        "actualUSD": null,
        "projectedUSD": 73.2,
        "isToday": false
      },
      {
        "day": 25,
        "date": "2026-11-25",
        "actualUSD": null,
        "projectedUSD": 76.25,
        "isToday": false
      },
      {
        "day": 26,
        "date": "2026-11-26",
        "actualUSD": null,
        "projectedUSD": 79.3,
        "isToday": false
      },
      {
        "day": 27,
        "date": "2026-11-27",
        "actualUSD": null,
        "projectedUSD": 82.35,
        "isToday": false
      },
      {
        "day": 28,
        "date": "2026-11-28",
        "actualUSD": null,
        "projectedUSD": 85.39999999999999,
        "isToday": false
      },
      {
        "day": 29,
        "date": "2026-11-29",
        "actualUSD": null,
        "projectedUSD": 88.45,
        "isToday": false
      },
      {
        "day": 30,
        "date": "2026-11-30",
        "actualUSD": null,
        "projectedUSD": 91.5,
        "isToday": false
      }
    ],
    "prefs": {
      "version": 1,
      "sources": {
        "chatgpt": {
          "enabled": true,
          "showInTray": true,
          "account": "personal",
          "barDesign": "divider",
          "showDailyInBar": true,
          "showMonthlyInBar": true,
          "showBalanceInBar": true
        },
        "cursor": {
          "enabled": true,
          "showInTray": true,
          "account": "work",
          "barDesign": "divider",
          "showDailyInBar": true,
          "showMonthlyInBar": true,
          "showBalanceInBar": true
        },
        "grokbot": {
          "enabled": true,
          "showInTray": true,
          "account": "personal",
          "barDesign": "divider",
          "showDailyInBar": true,
          "showMonthlyInBar": true,
          "showBalanceInBar": true
        },
        "openai": {
          "enabled": true,
          "showInTray": true,
          "account": "work",
          "barDesign": "divider",
          "showDailyInBar": true,
          "showMonthlyInBar": true,
          "showBalanceInBar": true
        },
        "claude": {
          "enabled": true,
          "showInTray": true,
          "account": "personal",
          "barDesign": "divider",
          "showDailyInBar": true,
          "showMonthlyInBar": true,
          "showBalanceInBar": true
        }
      },
      "refreshMinutes": 1,
      "cursorPersonalAllowanceUSD": 20,
      "openAtLogin": true,
      "themedProviderLogos": true,
      "darkBarBackground": true,
      "menuBarScale": 100,
      "spendColorsEnabled": true,
      "pastelBarColors": true,
      "rememberPanelPlace": false,
      "notificationsEnabled": true,
      "allowanceAlertsEnabled": true,
      "opusAlertsEnabled": true,
      "notificationSounds": false,
      "alertThresholds": [
        15,
        10,
        5
      ],
      "disabledAlertThresholds": [],
      "openAIBalance": {
        "enteredUSD": 25,
        "dayStart": "2026-11-04T15:49:28.428689+00:00",
        "spendAlreadyReportedUSD": 0
      }
    },
    "refreshing": false,
    "updatedAt": "2026-11-04T15:49:28.428689+00:00",
    "platform": "darwin",
    "openAIKeyConfigured": false,
    "dataDir": "/Users/demo/Library/Application Support/TokenPulse",
    "version": "0.5.49",
    "icons": {
      "chatgpt": image('menubar/Artwork/providers/chatgpt-themed.png'),
      "cursor": image('menubar/Artwork/providers/cursor-themed.png'),
      "grokbot": image('menubar/Artwork/providers/grokbot-themed.png'),
      "openai": image('menubar/Artwork/providers/openai-themed.png'),
      "claude": image('menubar/Artwork/providers/claude-themed.png')
    }
  },
  "shots": [
    {
      "name": "overview",
      "caption": "Overview with independent 5-hour and weekly allowance meters and sample work spend.",
      "action": "",
      "expect": "Weekly"
    },
    {
      "name": "chatgpt",
      "caption": "Provider details and per-source menu-bar options: ChatGPT.",
      "action": "document.querySelector(\"[data-act=\\\"go\\\"][data-route=\\\"source:chatgpt\\\"]\").click();",
      "expect": "ChatGPT"
    },
    {
      "name": "cursor",
      "caption": "Provider details and per-source menu-bar options: Cursor.",
      "action": "document.querySelector(\"[data-act=\\\"go\\\"][data-route=\\\"source:cursor\\\"]\").click();",
      "expect": "Cursor"
    },
    {
      "name": "grokbot",
      "caption": "Provider details and per-source menu-bar options: Grok Bot.",
      "action": "document.querySelector(\"[data-act=\\\"go\\\"][data-route=\\\"source:grokbot\\\"]\").click();",
      "expect": "Grok Bot"
    },
    {
      "name": "openai",
      "caption": "Provider details and per-source menu-bar options: OpenAI API.",
      "action": "document.querySelector(\"[data-act=\\\"go\\\"][data-route=\\\"source:openai\\\"]\").click();",
      "expect": "OpenAI API"
    },
    {
      "name": "openai-balance",
      "caption": "OpenAI balance baseline and credential guidance, scrolled below the key form.",
      "action": "document.querySelector('#content').scrollTop=2000;",
      "expect": "Current prepaid balance"
    },
    {
      "name": "claude",
      "caption": "Provider details and per-source menu-bar options: Claude.",
      "action": "document.querySelector(\"[data-act=\\\"go\\\"][data-route=\\\"source:claude\\\"]\").click();",
      "expect": "Claude"
    },
    {
      "name": "spend",
      "caption": "Combined work-spend chart with recorded and projected totals.",
      "action": "document.querySelector(\"[data-act=\\\"go\\\"][data-route=\\\"spend\\\"]\").click();",
      "expect": ""
    },
    {
      "name": "efficiency",
      "caption": "Current Efficiency screen; the engine is not wired in this Electron build.",
      "action": "document.querySelector(\"[data-route=\\\"efficiency\\\"]\").click();",
      "expect": ""
    },
    {
      "name": "scoreboard",
      "caption": "Current Scoreboard shell with its empty session state and badge list.",
      "action": "document.querySelector(\"[data-route=\\\"scoreboard\\\"]\").click();",
      "expect": ""
    },
    {
      "name": "alerts",
      "caption": "Current Alerts screen with no advisories in this sample session.",
      "action": "document.querySelector(\"[data-route=\\\"alerts\\\"]\").click();",
      "expect": ""
    },
    {
      "name": "options",
      "caption": "Preferences for appearance, refresh interval, menu-bar scale, and sources.",
      "action": "document.querySelector(\"#btn-options\").click();",
      "expect": ""
    },
    {
      "name": "options-bottom",
      "caption": "Lower Preferences sections, source shortcuts, and reset/data-folder actions.",
      "action": "document.querySelector('#content').scrollTop=2000;",
      "expect": "Reset to defaults"
    },
    {
      "name": "notifications",
      "caption": "Notification toggles, individual 15/10/5 percent levels, sound, and system settings.",
      "action": "document.querySelector(\"[data-route=\\\"notifications\\\"]\").click();",
      "expect": "Customize thresholds"
    },
    {
      "name": "menu-bar-style",
      "caption": "Per-provider style preference set to the stacked-track layout.",
      "action": "document.querySelector(\"[data-route=\\\"source:chatgpt\\\"]\").click();const s=document.querySelector('[data-act=\"bar-design\"]');s.value='lanes';s.dispatchEvent(new Event('change',{bubbles:true}));",
      "expect": "Menu bar style"
    }
  ]
};
