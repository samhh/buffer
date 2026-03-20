# Buffer — Agent Guide

A macOS floating notes app built with Swift 6.2 and SwiftUI/AppKit. No external dependencies.

## Build & Test

```bash
swift build          # build
swift test           # run all tests
swift run Buffer     # run the app
```

Requires macOS 26.0+ SDK. The project uses Swift Package Manager — `Package.swift` at the repo root defines two targets: `Buffer` (executable) and `BufferTests`. The default branch is `trunk`.

## Architecture

- **Sources/Buffer/** — 12 Swift files. `BufferApp.swift` is the entry point (AppDelegate lifecycle). `NotesWindowController.swift` is the main UI. State is managed with Combine (`@Published`).
- **Tests/BufferTests/** — Unit tests using XCTest. Snapshot tests output PNGs to `__Snapshots__/`.
- **scripts/** — `make-app.sh` creates a signed .app bundle.

Notes are stored as plaintext in `~/Library/Application Support/Buffer`. Pinning uses extended attributes (xattr).

## Indentation & Subitems

Lines are organized into a hierarchy using 4-space indentation. Depth = `floor(leading_spaces / 4)`. There is no hard nesting limit.

```
Project A           ← depth 0
    Task 1          ← depth 1 (child of Project A)
        Subtask     ← depth 2 (child of Task 1)
    Task 2          ← depth 1
Project B           ← depth 0
```

**Smart list editing** (`SmartListEditing.swift`) handles keyboard interactions:
- **Enter** — inherits the current line's indent level. On an empty indented line, clears the indent instead.
- **Tab** — indents selected lines by 4 spaces. On an empty line, indents to one level deeper than the previous line.
- **Shift+Tab** — unindents selected lines by up to 4 spaces.
- **Backspace** — when the caret is within leading whitespace, deletes all leading spaces at once.
- **Opt+Up/Down** — moves entire lines up/down, preserving indentation.
- **Cmd+X** (no selection) — deletes the current line **and all deeper subitems** below it. Stops at the first non-empty line with equal or lesser depth. Empty lines between subitems are included; trailing empty lines are not.

**Root group styling** (`RootGroupStyling.swift`) uses depth to visually group depth-0 parents with their children, cycling through a color palette.

## Conventions

- No external dependencies — keep it that way unless discussed.
- Prefer native macOS UI idioms and Liquid Glass styling. Use system-provided materials and vibrancy rather than custom chrome.
- The app supports light and dark themes (plus a system-follow mode). Keep both looking good.
- Test files mirror source file names (e.g. `LinkShrink.swift` → `LinkShrinkTests.swift`). Liberally add unit tests and snapshot tests — especially for rendering and layout logic. Snapshot PNGs go in `Tests/BufferTests/__Snapshots__/`.
- Run `swift test` before committing to verify nothing is broken.
