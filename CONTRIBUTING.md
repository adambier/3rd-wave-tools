# Contributing

Thank you for helping. Contributions of every size are welcome: a correction to one sentence of
the format reference counts as much as code.

## What helps most

- **Corrections and additions to [`docs/FORMATS.md`](docs/FORMATS.md).** If something there is
  wrong, incomplete, or still listed as unknown, and you know better, please say so, whether you
  found out on a 3rd Wave, from Groove Synthesis's documents, or from files.
- **Bug reports** for the app, the library, or `tw3pg`, with the files that show the problem if
  you can share them.
- **Word of what you build.** If you write a tool that reads or writes the 3rd Wave's files, open
  an issue to say so; it may be worth linking from the README.

## Evidence for format findings

The format reference says what each statement rests on, and a contribution to it should too:

- **A test on a 3rd Wave:** the model (8M, 24K, or 24M), the OS version, the steps, what the
  3rd Wave did, and, where possible, the files before and after (for example, a file you imported
  and what the 3rd Wave exported again).
- **Groove Synthesis's documents:** which document, version, and section.
- **Files:** how many files and from where (factory banks, your own exports), and what held in all
  of them.

Reasoning that has not been checked is welcome too; say that it is an inference, and FORMATS.md
will say so in words.

Please don't attach files you don't have the right to share, such as Groove Synthesis's factory
banks or commercial sound sets. Describe them instead (e.g., "every program in the 2025 factory
bank 3"), or share only your own programs and exports.

## Building and testing

- **The app** (macOS 13 or later, Xcode command-line tools): `./make-app.sh`, then
  `open "pgdata Packer.app"`. The first build downloads Sparkle.
- **The tests:** `./run-tests.sh` on a Mac with a full Xcode installation (15 or later), or
  `swift test` on Linux or Windows (Swift 5.9 or later; tested with 6.0 on Linux and macOS and 6.2
  on Windows, where 6.0 cannot build against the current Windows SDK).
- **The test files** in [`fixtures/`](fixtures/): after a deliberate change to what the library
  writes, rebuild them with
  `PGDATA_TESTS=1 PGDATA_REGENERATE_FIXTURES=1 swift test --filter FixtureTests` and include the
  new files in the change.
- **The library's documentation:**
  `PGDATA_DOCS=1 swift package --disable-sandbox preview-documentation --target PgdataFormats`
  builds it and serves it locally. Every public declaration in `PgdataFormats` should have a doc
  comment. Pushes to `main` that change the library publish it to GitHub Pages.

## Code

- **`PgdataFormats`** is the library other projects use. It depends only on Foundation and has no
  UI, and it must build on Linux, macOS, and Windows (the tests run on all three for every push).
  Every reader writes an unmodified file back byte for byte; keep it that way, and add a test for
  anything new.
- **`PgdataPackerCore`** holds the app's own decisions (pack and unpack plans, file names, Clean
  Up Names), also without UI, so that other front ends can share them. **`PgdataPacker`** is the
  SwiftUI app. **`tw3pg`** is the developer tool.
- Changes to what the 3rd Wave is said to do belong in FORMATS.md as well as in the code.

## Writing

The README, FORMATS.md, the documentation, and the app's text follow a few conventions:

- "3rd Wave", never "Third Wave"; "Groove Synthesis" in full.
- "the 3rd Wave" or "your 3rd Wave", not "the synth".
- Standing behaviour in the present tense; single observations as "has been observed to …".
- Inferences said to be inferences.
- The serial (Oxford) comma.

## Pull requests

Fork the repository, make your change on a branch, and open a pull request that says what changed
and, for format findings, what it rests on. Run the tests first. Contributions are accepted under
the project's MIT licence.

This project is not affiliated with or endorsed by Groove Synthesis.
