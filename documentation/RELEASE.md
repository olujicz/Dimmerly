# Release Plan

This runbook covers public direct-download releases of Dimmerly as a signed and notarized Developer ID DMG. App Store releases use the `Dimmerly App Store` scheme and are a separate release track.

AI agents must also follow the release rules in `AGENTS.md`. If this runbook and `AGENTS.md` drift, update both in the same change.

Repository settings that cannot be fully enforced from files are documented in `documentation/REPOSITORY_SETTINGS.md`.

## Release Goals

- Ship a signed, notarized DMG built from the `Dimmerly` scheme and `Release` configuration.
- Keep the GitHub Release as a draft until a human verifies installation and basic behavior.
- Preserve a clear rollback path by keeping the previous release available.
- Do not publish release assets from untagged commits.

## Versioning Policy

Dimmerly uses stable Semantic Versioning for public releases:

```text
MAJOR.MINOR.PATCH
```

Tags must use the same version prefixed with `v`:

```text
v1.0.0
v1.1.0
v1.1.1
```

Use version increments this way:

| Change type | Version bump | Example |
| --- | --- | --- |
| Breaking behavior, major compatibility change, or removed user-facing capability | MAJOR | `1.4.2` -> `2.0.0` |
| New user-facing feature or meaningful enhancement | MINOR | `1.4.2` -> `1.5.0` |
| Bug fix, localization fix, small polish, or release infrastructure fix | PATCH | `1.4.2` -> `1.4.3` |

For version 1.2.0, the maintainer approved an exception to the major-version rule for the switch to stable per-display Shortcuts identities. Existing Shortcuts with a display selected need that display reselected once after upgrading. Keep this compatibility note in the curated release notes.

Apple bundle versions are mapped as:

| Xcode setting | Required value |
| --- | --- |
| `MARKETING_VERSION` | Exact SemVer release version, for example `1.0.0` |
| `CURRENT_PROJECT_VERSION` | Monotonically increasing positive integer build number |

Pre-release suffixes such as `1.1.0-rc.1` are not used for public macOS app versions because `MARKETING_VERSION` should remain a numeric bundle short version. Release candidates are produced with `workflow_dispatch` from a release-prep commit and are distributed only as GitHub Actions artifacts.

## Branch And Tag Policy

- `main` is the only source of public releases.
- Release tags must point to commits reachable from `origin/main`.
- Release tags are annotated and immutable once pushed.
- Do not force-push, move, or reuse a published release tag.
- Use a new patch version for any rebuild or hotfix after a release is published.

The release workflow enforces:

- tag format `vMAJOR.MINOR.PATCH`
- matching `MARKETING_VERSION`
- positive integer `CURRENT_PROJECT_VERSION`
- matching `CHANGELOG.md` release heading
- tag commit ancestry from `origin/main`
- draft GitHub Release creation, not automatic publication

## Required GitHub Secrets

Configure these repository or environment secrets before running `.github/workflows/release.yml`:

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded `.p12` containing the Developer ID Application certificate and private key. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12`. |
| `APPSTORE_CONNECT_API_KEY_ID` | App Store Connect API key ID. |
| `APPSTORE_CONNECT_ISSUER_ID` | App Store Connect issuer ID. |
| `APPSTORE_CONNECT_API_KEY_BASE64` | Base64-encoded `AuthKey_<KEY_ID>.p8` contents. |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle's EdDSA private key, exported with `Vendor/Sparkle/bin/generate_keys --account dimmerly -x <file>`. Signs each update and the appcast. |

The App Store Connect API key must have access to certificates, identifiers, and profiles so Xcode can resolve signing assets during `-allowProvisioningUpdates`.

The Apple Developer Team ID is checked into the Xcode project, `ExportOptions-DeveloperID.plist`, and release workflow as `MN5C3DH647`. Update all three places together if the signing team changes.

The Sparkle key's public half is `SUPublicEDKey` in `packaging/sparkle/SparkleInfo.plist`, and every direct-download build carries it. Keep the exported private key in the maintainer's password manager as well as in the secret.

Losing the key doesn't strand installed copies, but they don't recover right away. A release signed with a new key reaches them only if its DMG is signed with the same Developer ID certificate (ours is), and its feed is still rejected at first, because the app requires a feed signed with the old key. Sparkle shows the update only once 20 days have passed since that first failure without a feed it could verify (`SUSignedFeedFailureExpirationInterval`, left at its default), and then without release notes. Until then, ask users to download the new version by hand from GitHub Releases or the website. Never change the Sparkle key and the Developer ID certificate in the same release, and read Sparkle's key rotation notes before changing either. The workflow passes the key to Sparkle's tools on stdin only; never write it to a file in CI or print it.

Create base64 values with:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
base64 -i AuthKey_KEYID.p8 | pbcopy
```

## Pre-Release Checklist

- Decide the SemVer bump from the changelog and merged changes.
- Move completed entries from `## [Unreleased]` to a dated release heading:

```markdown
## [1.0.0] - YYYY-MM-DD
```

- Leave a fresh empty `## [Unreleased]` section above the new release heading if new work will continue after the release.
- Confirm `MARKETING_VERSION` in `Dimmerly.xcodeproj` exactly matches the intended release version, for example `1.0.0`.
- Confirm `CURRENT_PROJECT_VERSION` is a positive integer and greater than any previously distributed build number.
- Confirm the release commit is merged to `main` before tagging.
- Confirm repository branch protection and tag protection match `documentation/REPOSITORY_SETTINGS.md`.
- Run local quality checks:

```bash
just format-check
just lint
just test
just build-release
```

- Manually verify the direct distribution behavior from a local Release build:
  - menu bar app launches
  - brightness dimming works
  - display sleep works
  - wake behavior works
  - settings persist
  - widget and app group behavior still work
- Confirm open issues do not contain a release-blocking regression.

## Release Preparation PR

Every public release should start with a small release-prep PR. The PR should contain only release metadata and final documentation edits:

- `Dimmerly.xcodeproj`: update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
- `CHANGELOG.md`: create the release heading and keep release notes user-facing
- release documentation updates if the process changed

Do not mix feature work into the release-prep PR. Merge it only after CI passes and the release owner has checked the pre-release checklist.

## DMG Packaging

The Release workflow builds the DMG with `packaging/dmg/build-dmg.sh`, which runs [dmgbuild](https://github.com/dmgbuild/dmgbuild) from a temporary virtual environment. `packaging/dmg/requirements.txt` pins dmgbuild and its dependencies by version and SHA-256, and pip installs wheels only. dmgbuild writes the Finder window layout directly, so the job does not need Finder or a logged-in desktop.

| File | Purpose |
| --- | --- |
| `packaging/dmg/dmgbuild-settings.py` | Window size, icon size and positions, hidden toolbar and sidebar, ULMO (LZMA) format, and the volume icon taken from the app's `AppIcon.icns`. |
| `packaging/dmg/background.png`, `background@2x.png` | Installer window background. dmgbuild combines both into one HiDPI TIFF. |
| `packaging/dmg/make-background.swift` | Regenerates both background images: `swift packaging/dmg/make-background.swift packaging/dmg`. |
| `packaging/dmg/verify-dmg.sh` | Read-only inspection of the final stapled DMG. |

Keep the layout constants in `dmgbuild-settings.py` and `make-background.swift` in sync. Over a background picture, Finder draws icon labels black in both light and dark mode, so the label band must keep at least 4.5:1 contrast with black. It uses a light brand blue, `#5DA0EE` (about 7.7:1 with black), taken from the app icon's sky blue; the white hint below the labels sits on the icon's navy, `#1A2F4B`. `window_rect` is the outer window frame, so its height includes a 28 pt title bar on top of the 400 pt background. Do not set dmgbuild's `hide_extensions`: it adds `com.apple.FinderInfo` to the app bundle, which breaks `codesign --verify --strict`.

After stapling, the workflow runs `verify-dmg.sh`. It fails the release if any of these checks fail:

- the image format is ULMO
- the DMG is signed by the release team with a secure timestamp
- the volume contains only `Dimmerly.app`, the `Applications` shortcut, and the layout files
- the app version and build match the release
- `LSMinimumSystemVersion` matches the app target's `MACOSX_DEPLOYMENT_TARGET`
- the app was built with Xcode 27 and a macOS 27 SDK (`DTXcodeBuild`, `DTSDKName`, major version from `.github/scripts/xcode-pin.sh`)
- the app is universal (`arm64` and `x86_64`)
- the app passes strict signature verification, is signed by the release team, has the Hardened Runtime and a secure timestamp, and has a stapled ticket
- every app extension in `Contents/PlugIns` is signed by the release team with the Hardened Runtime and a secure timestamp, and at least one extension (the widget) is present
- `Contents/Frameworks/Sparkle.framework` is present, and the framework, `Autoupdate`, `Updater.app` and each XPC service are signed by the release team with the Hardened Runtime and a secure timestamp
- the updater keys in the app's `Info.plist` match `packaging/sparkle/SparkleInfo.plist`, and none of `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUAllowsAutomaticUpdates`, `SUEnableSystemProfiling`, `SUEnableInstallerLauncherService`, `SUEnableDownloaderService` or `SUScheduledCheckInterval` is set
- the final entitlements of the app and each extension (`codesign -d --entitlements - --xml`) contain no `com.apple.security.get-task-allow` and include the `<team ID>.rs.in.olujic.dimmerly` app group, and each extension is sandboxed

The workflow notarizes the app zip and then the DMG with `.github/scripts/notarize.sh`. It submits with `--output-format json`, keeps the submission ID, and always fetches `xcrun notarytool log` for it, also when the submission is Accepted. It prints the log status and any issues, and fails unless the status is Accepted and the log lists no issues at all; a warning fails the release too. Both logs are uploaded as the `Dimmerly-<version>-notary-logs` artifact, also when a later step fails. The logs contain no credentials. CI tests this gate with `.github/scripts/test-notarize.sh` and a stand-in `notarytool`.

After the checksum, the workflow makes `appcast.xml` with `packaging/sparkle/build-appcast.sh`: Sparkle's `generate_appcast` on the final DMG, with this version's `CHANGELOG.md` section embedded as Markdown release notes, and the feed signed. It then checks the feed signature with `sign_update --verify` and the rest with `packaging/sparkle/verify-appcast.sh` (one item, version, build, download URL, length, minimum macOS, notes, and the DMG's signature against `SUPublicEDKey`). CI tests that script with `.github/scripts/test-verify-appcast.sh`.

The App Store edition must not contain Sparkle (App Review guideline 2.4.5). The target's last build phase, `packaging/sparkle/build-phase.sh`, fails any App Store build whose settings would link or embed Sparkle or whose `Info.plist` has `SU*` keys, including archives made with Xcode's Product > Archive. `.github/scripts/verify-no-updater.sh` re-checks the finished bundle (every Mach-O file, `Sparkle.framework`, `SU*` keys); CI, the Release quality gate, `just build-appstore` and `just archive-appstore` run it.

To preview the layout locally, build a DMG from any exported or downloaded `Dimmerly.app`:

```bash
packaging/dmg/build-dmg.sh /path/to/Dimmerly.app "Dimmerly preview" build/Dimmerly-preview.dmg
open build/Dimmerly-preview.dmg
```

## Shared CI And Release Toolchain

The Release workflow uses GitHub's `xcode-27` Apple silicon runner and explicitly selects released Xcode 27.1 (`27A9275`), the image's default, for both the quality gate and signed DMG build. The archive uses manual signing with the imported Developer ID Application identity so clean runners do not create disposable Apple Development certificates. Keep these settings aligned with `.github/workflows/release.yml` when upgrading the release environment.

| Workflow | Runner | Xcode |
| --- | --- | --- |
| CI `test` and `build-appstore` | `xcode-27` | 27.1 (`27A9275`, released) |
| Release quality gate and DMG build | `xcode-27` | 27.1 (`27A9275`, released) |
| App Store archive | local Mac | any Xcode 27 build (major version only), checked by `verify-built-xcode.sh` |

The CI `workflow-lint`, `format` and `lint` jobs also run on `xcode-27`, but they only install and run linters, so they don't depend on the Xcode pin. They moved there from `macos-26` in November 2026, after that pool repeatedly left them queued until they timed out.

The runner image remains a GitHub public preview, but the selected Xcode is a released toolchain, not a beta. CI sets `DEVELOPER_DIR` and Release selects `/Applications/Xcode_27.1.app/Contents/Developer`. The Release quality gate runs both direct-distribution and App Store test suites and the App Store smoke build. Both workflows invoke `.github/scripts/verify-xcode.sh`, which rejects any Xcode version or build other than the pin in `.github/scripts/xcode-pin.sh`, an unrecognized or older Swift compiler, and a macOS SDK older than 27.0. The scope job tests this gate and the built-app gate (`test-verify-built-xcode.sh`) on every CI run. Both workflows install SwiftFormat 0.64.6 with `.github/scripts/install-swiftformat.sh`, which verifies the release checksum. Keep that script and `--minversion` in `.swiftformat` in step.

Apple lists [Xcode 27.1 build 27A9275 as released on October 15, 2026](https://developer.apple.com/news/releases/). It still builds against the macOS 27.0 SDK. GitHub documents the installed toolchains in its [Xcode 27 runner manifest](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md). Before changing the pin, verify the replacement is a released Xcode build and update the workflows, gate, tests, and this runbook together.

As of runner image `20261026.0314.1`, Xcode 27.2 is installed only as the release candidate (`27B48`, `Xcode_27.2_Release_Candidate.app`), not the released `27B52`, so the pin stays at 27.1. Move it once the manifest lists the released 27.2 build; CI then uses the same macOS 27.2 SDK as a local 27.2 archive.

Both editions must come from Xcode 27 with a macOS 27 SDK. The DMG is built in CI with the exact pin, while the App Store archive is built locally with the current Xcode 27 point release, for example 27.2 (`27B52`). Any Xcode 27 build is accepted, since the check compares the major version only and can't tell a beta from a release; a different major Xcode is not. Archive with a released Xcode. `verify-dmg.sh` and `.github/scripts/verify-built-xcode.sh` read `DTXcodeBuild` and `DTSDKName` from the app and reject any other major version. Archive the App Store edition with:

```bash
just archive-appstore <version> <build>
```

The recipe archives with the selected Xcode, runs `verify-built-xcode.sh` on the archive, and checks that the archived app's version and build match the ones you passed. Don't upload an archive that fails it. When the pin moves, update `xcode-pin.sh`, the `DEVELOPER_DIR` and `xcode-select` paths in the workflows, the gate tests, and this runbook together.

Swift 6.4 includes the code behind `#if compiler(>=6.4)`: macOS 27 intent execution targets and preset reindexing, plus display-control `appEntityIdentifier` wiring. Runtime availability checks still apply: macOS 27 behavior requires macOS 27, while display-control targeting requires macOS 15.4 or later. The app's deployment target remains macOS 15.0.

## Release Candidate Build

For **1.3.0 only**, the maintainer has explicitly waived the separate manual
release-candidate run. Prepare and merge the release changes, then use the
tag-triggered workflow to build the draft release. Signing, notarization,
checksum verification, Gatekeeper assessment, clean installation, and final
manual QA still apply before publication. Other releases keep the normal
candidate procedure below.

Use the manual workflow first to prove signing, notarization, and packaging before creating a public tag. Run it from the release-prep commit after it is on `main`:

1. Open GitHub Actions.
2. Run the `Release` workflow manually.
3. Enter the intended stable SemVer version, for example `1.0.0`.
4. Download the `Dimmerly-<version>-signed-dmg` artifact.
5. Verify the checksum:

```bash
shasum -a 256 Dimmerly-<version>.dmg
cat Dimmerly-<version>.dmg.sha256
```

6. Open the downloaded DMG and confirm the installer window shows the background, the arrow from Dimmerly to Applications, readable icon labels, and the Dimmerly volume icon. Then install from it on a clean macOS account or separate Mac.
7. Verify Gatekeeper accepts the app:

```bash
spctl --assess --type open --context context:primary-signature --verbose=4 Dimmerly-<version>.dmg
spctl --assess --type execute --verbose=4 /Applications/Dimmerly.app
codesign --verify --deep --strict --verbose=2 /Applications/Dimmerly.app
```

## Tag And Draft Release

After the release candidate passes (or under the explicit 1.3.0 exception above):

```bash
git status --short
git switch main
git pull --ff-only origin main
git tag -a v<version> -m "Dimmerly <version>"
git push origin v<version>
```

The tag starts the `Release` workflow. The workflow creates a draft GitHub Release with:

- `Dimmerly-<version>.dmg`
- `Dimmerly-<version>.dmg.sha256`
- `appcast.xml`, the in-app update feed for this version
- generated release notes

The appcast's release notes are this version's `CHANGELOG.md` section, and users read them in the update window, so finish the changelog before tagging. The draft must remain unpublished until final QA is complete. Publishing it is what offers the update in the app: the feed URL, `https://github.com/olujicz/Dimmerly/releases/latest/download/appcast.xml`, follows GitHub's latest release, which never includes drafts or pre-releases.

## Final QA

Download the DMG from the draft release and perform the clean install, checksum,
Gatekeeper, and signature checks listed above, even when a separate candidate
was waived. Also verify:

- the draft release notes match `CHANGELOG.md`
- the DMG filename and checksum contain the intended version
- the installer window layout is intact, with black, readable labels, in both light and dark mode
- the app reports the intended version in Finder and system metadata
- no quarantine, signing, or notarization warnings appear on first launch
- `bash packaging/sparkle/verify-appcast.sh appcast.xml Dimmerly-<version>.dmg <version> <build>` passes on the downloaded files, and the notes inside `appcast.xml` read well as update notes

## Publish

When final QA passes:

1. Edit the draft GitHub Release.
2. Replace generated notes with curated user-facing release notes from `CHANGELOG.md`.
3. Confirm the DMG and checksum assets are attached.
4. Publish the release.
5. Verify the public release page downloads the same checksum.
6. Check that the update feed now offers this version:
   `curl -fsSL https://github.com/olujicz/Dimmerly/releases/latest/download/appcast.xml | grep shortVersionString`
7. Update and verify the Homebrew tap using the next section, the same day.
8. Run the GitHub Pages workflow from `main` (Actions > GitHub Pages > Run
   workflow). The website's download buttons link straight to the latest
   release's DMG, and the home page's version line names that release and
   links its `CHANGELOG.md` entry; both are resolved when the site is built.
   Then check that the home page's Download button fetches
   `Dimmerly-<version>.dmg` and that the line under it shows the new version.
9. Announce the release only after the public download, checksum, Homebrew
   tap, and website download are verified.

## Homebrew Tap Update

After the GitHub Release is published, update the public Homebrew cask so
`brew install --cask dimmerly` installs the new version before the release is
broadly announced.

The cask declares `auto_updates true` because the app updates itself; keep it. A plain `brew upgrade` checks the installed app's own version, so it leaves an app that Sparkle already updated alone. `brew upgrade --greedy` doesn't: it reinstalls whatever the tap names, which is an older version if the tap is behind. Update the tap the same day the release is published.

The tap lives in:

```text
git@github.com:olujicz/homebrew-dimmerly.git
```

Use the checksum from the published GitHub Release asset:

```bash
VERSION=<version>
curl -L -o /tmp/Dimmerly-$VERSION.dmg \
  "https://github.com/olujicz/Dimmerly/releases/download/v$VERSION/Dimmerly-$VERSION.dmg"
shasum -a 256 /tmp/Dimmerly-$VERSION.dmg
```

Then update `Casks/dimmerly.rb` in the tap:

```ruby
version "<version>"
sha256 "<sha256>"
```

Validate the tap before pushing:

```bash
brew untap olujicz/dimmerly || true
brew tap olujicz/dimmerly /path/to/homebrew-dimmerly
brew audit --cask olujicz/dimmerly/dimmerly
brew fetch --cask olujicz/dimmerly/dimmerly
```

Commit and push the tap update:

```bash
git status --short
git add Casks/dimmerly.rb
git commit -m "Update Dimmerly to <version>"
git push origin main
```

After pushing, retap from GitHub and verify Homebrew resolves the public tap:

```bash
brew untap olujicz/dimmerly
brew tap olujicz/dimmerly
brew info --cask olujicz/dimmerly/dimmerly
```

## Rollback

If a release is published with a blocking issue:

1. Mark the release as pre-release or add a warning to the release notes. Marking it pre-release also takes it out of the in-app update feed, which then offers the previous release again. Sparkle never downgrades, so people who already installed the bad build stay on it until the fixed version is published; ship the patch quickly.
2. Remove the DMG asset only if the build is unsafe to distribute.
3. Re-link the previous stable release in the notes.
4. Run the GitHub Pages workflow from `main`, so the website's download
   buttons stop pointing at the withdrawn DMG. A pre-release is skipped when
   the link is resolved, and a release without its DMG falls back to the
   release page.
5. Create a patch version and follow this runbook from the pre-release checklist.

Do not retag a published version. Use a new patch version so users and GitHub release assets remain auditable.

Build a patch from a commit newer than the current latest release. GitHub picks the latest release by the date of its commit, so a release built from an older commit doesn't become the latest one and isn't offered as an update.

## Hotfix Process

For urgent regressions:

1. Branch from `main`.
2. Apply the minimal fix and add focused test coverage where possible.
3. Bump only the PATCH version, for example `1.0.0` -> `1.0.1`.
4. Increment `CURRENT_PROJECT_VERSION`.
5. Add a `CHANGELOG.md` entry under the patch version.
6. Follow the same release candidate, tag, draft release, final QA, and publish steps.

Outside the explicit 1.3.0 exception above, skipping the release candidate workflow is only acceptable when the existing release is unsafe to keep available and the fix has already passed local signing/notarization checks.
