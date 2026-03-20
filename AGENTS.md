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

## Conventions

- No external dependencies — keep it that way unless discussed.
- Prefer native macOS UI idioms and Liquid Glass styling. Use system-provided materials and vibrancy rather than custom chrome.
- The app supports light and dark themes (plus a system-follow mode). Keep both looking good.
- Test files mirror source file names (e.g. `LinkShrink.swift` → `LinkShrinkTests.swift`). Liberally add unit tests and snapshot tests — especially for rendering and layout logic. Snapshot PNGs go in `Tests/BufferTests/__Snapshots__/`.
- Run `swift test` before committing to verify nothing is broken.
