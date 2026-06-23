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

Apple bundle versions are mapped as:

| Xcode setting | Required value |
| --- | --- |
| `MARKETING_VERSION` | Exact SemVer release version, for example `1.0.0` |
| `CURRENT_PROJECT_VERSION` | Monotonically increasing positive integer build number |

Pre-release suffixes such as `1.1.0-rc.1` are not used for public macOS app versions because `MARKETING_VERSION` should remain a numeric bundle short version. Release candidates are produced with `workflow_dispatch` from a release-prep commit and are distributed only as GitHub Actions artifacts.

The first public release should normalize the project from the current `1.0` marketing version to `1.0.0` before running the release workflow.

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

The App Store Connect API key must have access to certificates, identifiers, and profiles so Xcode can resolve signing assets during `-allowProvisioningUpdates`.

The Apple Developer Team ID is checked into the Xcode project, `ExportOptions-DeveloperID.plist`, and release workflow as `MN5C3DH647`. Update all three places together if the signing team changes.

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

## Release Candidate Build

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

6. Install from the downloaded DMG on a clean macOS account or separate Mac.
7. Verify Gatekeeper accepts the app:

```bash
spctl --assess --type open --context context:primary-signature --verbose=4 Dimmerly-<version>.dmg
spctl --assess --type execute --verbose=4 /Applications/Dimmerly.app
codesign --verify --deep --strict --verbose=2 /Applications/Dimmerly.app
```

## Tag And Draft Release

After the release candidate passes:

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
- generated release notes

The draft must remain unpublished until final QA is complete.

## Final QA

Download the DMG from the draft release and repeat the clean install checks. Also verify:

- the draft release notes match `CHANGELOG.md`
- the DMG filename and checksum contain the intended version
- the app reports the intended version in Finder and system metadata
- no quarantine, signing, or notarization warnings appear on first launch

## Publish

When final QA passes:

1. Edit the draft GitHub Release.
2. Replace generated notes with curated user-facing release notes from `CHANGELOG.md`.
3. Confirm the DMG and checksum assets are attached.
4. Publish the release.
5. Verify the public release page downloads the same checksum.
6. Update and verify the Homebrew tap using the next section.
7. Announce the release only after the public download, checksum, and Homebrew
   tap are verified.

## Homebrew Tap Update

After the GitHub Release is published, update the public Homebrew cask so
`brew install --cask dimmerly` installs the new version before the release is
broadly announced.

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

1. Mark the release as pre-release or add a warning to the release notes.
2. Remove the DMG asset only if the build is unsafe to distribute.
3. Re-link the previous stable release in the notes.
4. Create a patch version and follow this runbook from the pre-release checklist.

Do not retag a published version. Use a new patch version so users and GitHub release assets remain auditable.

## Hotfix Process

For urgent regressions:

1. Branch from `main`.
2. Apply the minimal fix and add focused test coverage where possible.
3. Bump only the PATCH version, for example `1.0.0` -> `1.0.1`.
4. Increment `CURRENT_PROJECT_VERSION`.
5. Add a `CHANGELOG.md` entry under the patch version.
6. Follow the same release candidate, tag, draft release, final QA, and publish steps.

Skipping the release candidate workflow is only acceptable when the existing release is unsafe to keep available and the fix has already passed local signing/notarization checks.
