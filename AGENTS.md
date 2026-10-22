## Build, test, release

The native app lives in `gazekeeper/` (Swift 6, SwiftUI + AppKit, macOS 14+).
`project.yml` is the source of truth — regenerate the project with
`xcodegen generate`, never hand-edit the `.xcodeproj`.

- Full gate (Debug + Release builds, CoreTests + AppTests, strict
  swift-format): `gazekeeper/scripts/gate.sh` — run before committing.
- Core tests only: `xcodebuild test -project gazekeeper/GazeKeeper.xcodeproj
  -scheme GazeKeeper -destination 'platform=macOS,arch=arm64'
  -only-testing:GazeKeeperCoreTests`
- Snapshot tests (AppTests) compare rendered PNGs under
  `gazekeeper/Tests/AppTests/__Snapshots__/`. Flip `record: true` to
  re-record after an intentional visual change, inspect the new refs, then
  flip it back off before committing.
- DMG: `gazekeeper/scripts/make-dmg.sh` — version comes from git tags via
  `scripts/version.sh`. Set `SIGNING_IDENTITY` + `NOTARY_PROFILE` to sign,
  notarize, and staple.
- Updates: Sparkle 2. The appcast feed URL is `SUFeedURL` in
  `Support/GazeKeeper-Info.plist` — it must point at the real deployed
  domain before shipping. Regenerate the feed after a release with
  `scripts/make-appcast.sh` (needs Sparkle's `generate_appcast` binary and
  the EdDSA private key in the login keychain).
- macOS floor stays 14.0. APIs newer than the floor go behind
  `if #available(macOS 15, *)` / `@available`, never a floor bump just
  for convenience.
- String catalog: `gazekeeper/Resources/Localizable.xcstrings` — re-sync
  after editing user-facing strings with `gazekeeper/scripts/sync-strings.sh`
  (needs a prior Debug build).

## Website (repo root, Astro)

The marketing site lives at the repo root (Astro 5 + pnpm). Every claim
on it must be true of the real app — no invented features, versions,
testimonials, or stats. "LookAway" may only appear as a competitor on
the compare page; a test enforces this.

- Install: `pnpm install` (esbuild/sharp build scripts are pre-approved
  in `pnpm-workspace.yaml`)
- Gates: `pnpm check`, `pnpm test`, `pnpm lint`, `pnpm build`, then
  `node scripts/check-links.mjs` against `dist/`
- Site constants live in `src/utils/site.ts`; docs content in
  `src/content/docs/` (must match the real app's feature set)

## Available skills — use when relevant

FYI: these skills are useful for architecture & UI work & code cleanliness. Use them when the task calls for it:
- design-taste-frontend, emil-design-eng, frontend-design — UI work
- codebase-design — architecture decisions
- thermo-nuclear-code-quality-review, ponytail / ponytail-audit — code cleanliness
