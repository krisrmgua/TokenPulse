# Contributing

Issues and pull requests are welcome.

1. Fork the repository and create a branch from `main`.
2. Keep the change focused. Use a conventional commit such as `feat:`, `fix:`, or `docs:`.
3. From `menubar/`, run:

```bash
swift run TokenPulse --selftest
```

4. Do not commit API keys, tokens, `auth.json`, Keychain exports, or local Application Support files.
5. Open a pull request that says what changed and how you tested it.

The app targets macOS 13 and is built with Swift Package Manager. Command Line Tools are enough for `--selftest`. XCTest runs when a full Xcode install is available:

```bash
cd menubar
swift test
```

User-facing behavior belongs in the README when install steps, credentials, or preferences change.
