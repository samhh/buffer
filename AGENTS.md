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

Lines are organized into a hierarchy using markdown-style `- ` list markers and 4-space indentation. Depth = `floor(leading_spaces / 4)` when a marker is present. There is no hard nesting limit. Plain text (no marker) is depth 0; the `- ` marker appears from the first indent onwards but can also exist at depth 0 (no leading spaces).

```
Project A               ← depth 0, no marker (plain text)
- Task 1                ← depth 0 with marker
    - Subtask           ← depth 1 (child of Task 1)
        - Deep item     ← depth 2
Project B               ← depth 0, no marker
```

**Smart list editing** (`SmartListEditing.swift`) handles keyboard interactions:
- **Enter** — inherits the current line's indent level and `- ` marker. On an empty list item (e.g. `    - ` or bare `- `), clears the indent and marker.
- **Tab** — first press on a plain line adds `- ` marker (no spaces). Subsequent presses add 4-space indent levels. On an empty line, indents one level deeper than the previous line.
- **Shift+Tab** — removes one indent level (4 spaces). At depth 0 with a marker, removes the `- ` marker. Without a marker, no-op.
- **Backspace** — when the caret is within the indent zone (leading whitespace + `- ` marker), deletes the entire zone at once.
- **Opt+Up/Down** — moves entire lines up/down, preserving indentation.
- **Cmd+X** (no selection) — deletes the current line **and all deeper subitems** below it. Stops at the first non-empty line with equal or lesser depth. Empty lines between subitems are included; trailing empty lines are not.

**Root group styling** (`RootGroupStyling.swift`) uses depth to visually group depth-0 parents with their children, cycling through a color palette.

## Conventions

- No external dependencies — keep it that way unless discussed.
- Use the **Catppuccin** color palette everywhere: Latte for light mode, Mocha for dark mode. Source: https://catppuccin.com/palette/. See `TitlePatternIcon.swift` for the existing accent rings.
- Prefer native macOS UI idioms and Liquid Glass styling. Use system-provided materials and vibrancy rather than custom chrome.
- The app supports light and dark themes (plus a system-follow mode). Keep both looking good.
- Test files mirror source file names (e.g. `LinkShrink.swift` → `LinkShrinkTests.swift`). Liberally add unit tests and snapshot tests — especially for rendering and layout logic. Snapshot PNGs go in `Tests/BufferTests/__Snapshots__/`.
- Run `swift test` before committing to verify nothing is broken.
