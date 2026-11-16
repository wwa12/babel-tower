# Contributing

[简体中文](CONTRIBUTING.md) | English

Thanks for helping build Babel Tower. Issues and pull requests are welcome in English or Chinese.

## Reporting bugs

Open an issue with the [bug template](https://github.com/wwa12/babel-mac/issues/new/choose) and include:

- your macOS version, and whether you're on Apple silicon or Intel;
- the model service and model name you use (**never paste your API key**);
- steps to reproduce, what you expected and what happened. Screenshots or a screen recording help a lot.

Security issues, such as anything that could leak an API key, should be reported privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## Proposing features

Please open an issue to discuss before sending a feature PR. Babel Tower is deliberately narrow; check the [non-goals](README.en.md#non-goals) in the README first.

Once a feature is accepted, the maintainer writes the acceptance criteria in the issue ("when …, the app should …"). Coding starts after that.

## Development setup

- macOS 14 or later and Xcode (currently verified with Xcode 26).
- The project is `app/巴别塔.xcodeproj`; dependencies are fetched by Swift Package Manager.
- Run the full test suite from `app/`:

```bash
xcodebuild test -project 巴别塔.xcodeproj -scheme 巴别塔 -destination 'platform=macOS'
```

The tests detect that they're running under XCTest: they don't register the global hotkey, read the Keychain or make real network requests. You won't get Keychain prompts and don't need an API key.

## Ground rules (a PR breaking any of these won't be merged)

1. **No API keys, signing certificates or provisioning profiles in the repo.** They must not appear in test data, logs or error messages either.
2. **No new system permissions or entitlements** (Accessibility, Screen Recording, Input Monitoring, etc.) without an issue discussion and the maintainer's agreement. Zero permissions is a product promise.
3. **Content goes only to the model service the user configured.** No analytics, telemetry or third-party services.
4. **Automated tests never hit real services.** Use local stubs such as `StubURLProtocol`.
5. **Test data must be fictional.** Never use real personal messages or internal documents.

## Writing code

- Match the existing style:
  - User-facing behaviour constants (limits, timeouts, sizes) live in `BehaviorConstants`, not as magic numbers in code.
  - UI strings live in `AppText`.
  - Differences between model services live in preset configuration (`ServicePreset`); code never branches on a service name.
  - Networking talks only to OpenAI-compatible APIs through `URLSession`. Don't add third-party dependencies without discussing it in an issue first.
  - Code comments are written in Chinese and explain why, not what.
- The project builds with Swift strict concurrency and warnings as errors, so code must compile with zero warnings.
- **Write a failing test first, then implement.**
  - Changes to the panel or Settings UI need a real-interface test: drive the real `PanelController` with the real content view, and assert what users actually see and use (window size, focus, visible text, the effect of key presses).
  - Testing view-model state alone isn't enough. See `app/Tests/AuditFixTests.swift` for examples.
- One change per PR. Branch from the latest `main` and name the branch `feature/*`, `fix/*` or `chore/*`.

## Pull requests

- Fill in the PR template: what changed, why, and how you tested it (test names plus manual steps on a real Mac). Include screenshots for UI changes.
- The maintainer reviews the code and does a hands-on acceptance run before merging. PRs are squash-merged, so each lands as one commit on `main`.
- **Definition of done**: all of the following hold.
  - All tests pass with zero warnings.
  - The review is approved.
  - The manual acceptance checklist has been walked through on a real Mac.
  - Anything touching the translation pipeline has been exercised at least once against a real model.

  If you couldn't do one of these, say so in the PR and explain why.

## Using AI coding assistants

You're welcome to; this project is itself built largely with AI assistance. Have your assistant read this guide first (especially the ground rules and testing requirements), and mention in the PR which assistant you used. Whoever opens the PR is responsible for the code: make sure you understand every change and that the tests really ran.

## License

By contributing, you agree that your contributions are released under the project's [MIT License](LICENSE).
