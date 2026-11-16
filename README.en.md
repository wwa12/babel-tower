# Babel Tower · 巴别塔

[简体中文](README.md) | English

A Mac translation panel you summon with a hotkey. Copy some text or take a screenshot, press ⌥T, and the translation appears; press Return and it goes to your clipboard and the panel closes.

It translates between exactly four languages: **Simplified Chinese, Traditional Chinese, Japanese and English**. The translating is done by a multimodal LLM that you configure yourself, through any OpenAI-compatible API. It needs no system permissions, has no accounts and runs no server of its own: your text and images go only to the model service you choose.

> **Status: early.** All features are implemented, but first-token latency and translation quality have not yet been measured systematically against real models, and the preset default model names are still placeholders. Feedback is welcome; please don't rely on it as a stable tool yet.

## Features

- **Three keystrokes end to end**: copy (⌘C) → summon (⌥T) → take the translation (↩). Anything copied in the last 60 seconds is pulled in and translated automatically when the panel opens.
- **Text, images, or both in one input area**: paste or drop up to 4 images. UI screenshots, chat logs, tables and posters are translated in reading order. When you send text and images together, each serves as context for the other and terminology stays consistent.
- **Automatic direction**: content in your primary language goes to your usual foreign language; everything else goes to your primary language. ⌘1–4 force Simplified / Traditional / Japanese / English, ⌘0 returns to automatic.
- **Streaming output, translation only**: no explanations or chatter. ⌘C copies everything, or just your selection if there is one.
- **Pin mode**: a pinned panel stays open when you click elsewhere, handy for translating several passages in a row.
- **Customizable system prompt.**

## Non-goals

Babel Tower is deliberately narrow. It does not do: translating a selection in place, built-in screenshot capture, overlaying the translation on the original image, whole-page or document translation, comparing several engines, dictionary and pronunciation, languages beyond the four, or accounts and cloud sync.

## Privacy and permissions

- No Accessibility, Screen Recording or Input Monitoring permission is requested; a fresh install shows no permission prompts.
- Your API key is stored only in the macOS Keychain on your Mac. It is never written to a file or synced.
- Content is sent only to the model service you configure. No usage data is collected.

## Requirements

- macOS 14 or later, Apple silicon or Intel.
- An API key for a multimodal model service that accepts images: OpenAI, Alibaba Cloud Model Studio (DashScope), Volcano Engine Ark, or any OpenAI-compatible endpoint.
- Xcode to build from source (currently verified with Xcode 26).

## Building from source

```bash
git clone https://github.com/wwa12/babel-mac.git
```

```bash
cd babel-mac/app && open 巴别塔.xcodeproj
```

Pick the "巴别塔" scheme in Xcode and press ⌘R. Or build from the command line inside `app/`:

```bash
xcodebuild build -project 巴别塔.xcodeproj -scheme 巴别塔 -configuration Release -destination 'platform=macOS'
```

Babel Tower is a menu bar app with no Dock icon. On first launch an onboarding window asks you to pick a model service, paste your API key and press "测试连接" (Test connection). The preset default model names are placeholders; change them to a model your account actually has.

**About the Keychain prompt**: the project uses ad-hoc signing by default. After each rebuild, macOS asks once whether the app may read the Keychain item the first time it loads your API key; choose "Always Allow". To avoid the prompt entirely, sign with your own Apple ID development certificate in Xcode.

The UI is currently Simplified Chinese only; English, Traditional Chinese and Japanese UI are planned before public distribution.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌥T | Show / hide the panel (global; configurable in Settings) |
| ↩ | Translate; once the translation is done, copy and close |
| ⇧↩ | New line |
| ⌘V | Paste text or images |
| ⌘1 / ⌘2 / ⌘3 / ⌘4 | Target Simplified Chinese / Traditional Chinese / Japanese / English |
| ⌘0 | Back to automatic direction |
| ⌘C | Copy the translation (or just the selection) |
| ⌘R | Translate again |
| ⌘N | Clear and start over |
| ⌘, | Open Settings |
| Esc | Close the panel |

## Contributing

Issues, feature discussions and pull requests are welcome. Please read the [contributing guide](CONTRIBUTING.en.md) first. Report security issues privately as described in [SECURITY.md](SECURITY.md), not in public issues.

## Technical overview

Swift + SwiftUI; the panel is a non-activating AppKit `NSPanel`. Networking uses `URLSession` with a hand-written SSE parser and talks only to OpenAI-compatible APIs. The single third-party dependency is [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) for the global hotkey. Code comments are in Chinese.

```
app/
  BabelTower/      App sources: Panel, Translation (engine and stream parsing), Clipboard, Imaging, Settings, Onboarding
  Tests/           Unit and real-interface tests
  巴别塔.xcodeproj
```

## License

[MIT](LICENSE)
