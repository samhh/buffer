# Buffer

![Static Badge](https://img.shields.io/badge/100%25-vibecoded?label=vibecoded&color=purple)

Buffer is a floating notes window for unimportant, semi-ephemeral information.

It optimises for how I used to organically use unsaved editor buffers: capture short-term todos and notes, avoid heavy structure, and organise around indentation.

If a note becomes important or warrants more structure, extract it to something like Apple Notes or Linear.

## Usage

Run:

```console
$ swift run Buffer
```

Install:

```console
$ scripts/make-app.sh --install
```

Buffer will start backgrounded in the menu bar. Notes are stored in plaintext at `~/Library/Application Support/Buffer`.

### Hotkeys

- Toggle (configurable): `Opt+n`
- Create new note: `Cmd+n`
- Delete note: `Cmd+d`
- Note picker / global search: `Cmd+p`, `Cmd+Shift+f`
- Pin note in picker: `Cmd+Shift+p`
- Toggle writing mode (editor only): `Cmd+Enter`
- Settings: `Cmd+,`

## Development

Everything except for this README was vibecoded with Codex (5.3 medium). It's most heavily inspired by [Antinote](https://antinote.io) and [Raycast Notes](https://www.raycast.com/core-features/notes).
