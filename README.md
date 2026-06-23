# Windo

A floating, always-on-top web window for macOS — watch YouTube, live sports, or
any non-DRM web video on top of other apps, including over full-screen apps.

A menu-bar utility (no Dock icon). Liquid Glass control pill, ambient title bar
that tints to the video, global hotkey, favorites, opacity, and compact mode.

## Install

```bash
brew install --cask zackbart/tap/windo
```

Requires macOS 26 (Tahoe) — uses the native Liquid Glass APIs.

## Develop

```bash
brew install xcodegen
xcodegen generate && open Windo.xcodeproj   # then ⌘R
```

`project.yml` is the source of truth; `Windo.xcodeproj` is generated and gitignored.
All app code is one file: `Sources/main.swift` (AppKit + WKWebView, no dependencies).

## Shortcuts

| Action | Key |
|---|---|
| Show/hide from anywhere | ⌥⌘W |
| Focus URL | ⌘L |
| Reload | ⌘R |
| Add to favorites | ⌘D |
| Compact mode | ⌘. |

Drag the title bar to move; hold ⌥ and drag anywhere as a backup. The control
pill (bottom-left) expands on hover.

## Releasing

Tag-driven. Bump `MARKETING_VERSION` in `project.yml`, commit, then:

```bash
git tag v0.1.0
git push origin v0.1.0
```

CI (`.github/workflows/release.yml`) builds on `macos-26`, signs with Developer ID,
notarizes + staples, publishes a `Windo-<version>.dmg` to GitHub Releases, and
bumps the Homebrew cask in `zackbart/homebrew-tap`.

## License

MIT
