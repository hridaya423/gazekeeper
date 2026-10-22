# GazeKeeper

A break reminder for the Mac that waits for the right moment.

Website: [gazekeeper.hridya.tech](https://gazekeeper.hridya.tech)

Every 20 minutes, GazeKeeper asks for 20 seconds of looking into the
distance. If you are on a call, sharing your screen or in a fullscreen app,
it holds the break. When the break is due, it waits for a pause in your
typing before it appears.

This repository holds the macOS app (`gazekeeper/`) and its website (the
repository root).

## What it does

- **Breaks on a schedule you set.** The defaults are a 20-minute interval
  and a 20-second break. Long breaks are optional.
- **Holds breaks for the moments that matter.** A camera or microphone in
  use, screen sharing, a fullscreen app, or a rule for a specific app.
  Each one is a switch in Settings.
- **Lands at a pause.** A heads-up arrives 60 seconds before the break.
  The break then waits for 2 seconds without input, and never more than
  30 seconds.
- **Works with the rest of macOS.** Focus filters, Shortcuts and Siri
  through App Intents, global keyboard shortcuts, and calendar-aware
  timing (off by default).
- **Keeps your data on your Mac.** It has no account and no analytics.
  Settings and break history stay in a local folder, and you can export
  them. The only network request is the update check.

The [docs](src/content/docs/) describe every setting and its default.

## Requirements

- macOS 14 or later.
- The release DMG is built for Apple silicon.

## Build the app

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd gazekeeper
xcodegen generate
open GazeKeeper.xcodeproj
```

`gazekeeper/project.yml` is the source of truth for the project. Do not edit
the generated `.xcodeproj`.

| Task | Command |
| --- | --- |
| Full gate (Debug and Release builds, tests, strict swift-format) | `gazekeeper/scripts/gate.sh` |
| Debug build with a local control server | `gazekeeper/scripts/run-debug.sh` |
| Release DMG | `gazekeeper/scripts/make-dmg.sh` |

`make-dmg.sh` takes its version from the latest git tag (`v1.2.3`). To sign
and notarize, set `SIGNING_IDENTITY` and `NOTARY_PROFILE`.

Updates use [Sparkle](https://sparkle-project.org). The feed URL is
`SUFeedURL` in `gazekeeper/Support/GazeKeeper-Info.plist`.
`gazekeeper/scripts/make-appcast.sh` regenerates the feed after a release.

## Build the website

The site uses Astro and pnpm.

```sh
pnpm install
pnpm dev        # http://localhost:3100
```

Before you commit, run the gates:

```sh
pnpm check && pnpm test && pnpm lint && pnpm build && node scripts/check-links.mjs
```

Every claim on the site must be true of the app.

## License

GazeKeeper is licensed under the [Apache License 2.0](LICENSE).

Third-party components keep their own licenses:

- [Optician Sans](https://optician-sans.com), SIL Open Font License 1.1.
  The license ships next to the font, in
  `gazekeeper/Resources/OpticianSans-OFL.txt` and
  `public/fonts/OpticianSans-OFL.txt`.
- [Geist and Geist Mono](https://vercel.com/font), SIL Open Font License
  1.1, installed through Fontsource.
- [Sparkle](https://github.com/sparkle-project/Sparkle), MIT License.
