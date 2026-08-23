# Repository Instructions

These guidelines apply to contributions to the Dimmerly repository, including
automated contributions.

## Development Workflow

- Keep edits scoped to the requested change.
- Prefer the project conventions and commands documented in `BUILDING.md`,
  `CONTRIBUTING.md`, and `Justfile`.
- Do not revert unrelated local changes.
- Run the narrowest useful validation before submitting a change.
- Keep credentials, access tokens, and private data out of the repository.
- Keep internal development notes in the gitignored `docs/` directory. Do not
  force-add them without explicit maintainer approval.

## Release Safety

Before changing a release-related file or process, read:

- [`documentation/RELEASE.md`](documentation/RELEASE.md)
- [`documentation/REPOSITORY_SETTINGS.md`](documentation/REPOSITORY_SETTINGS.md)

Release-related work includes project version or signing settings,
`CHANGELOG.md`, release workflows, export options, release tags, GitHub
Releases, DMG assets, notarization, and signing.

- Public releases use stable SemVer (`MAJOR.MINOR.PATCH`).
- Public release tags are annotated and use the form `vMAJOR.MINOR.PATCH`.
- `MARKETING_VERSION` must match the tag version without the leading `v`.
- `CURRENT_PROJECT_VERSION` must be a monotonically increasing positive
  integer.
- A matching release heading must be present in `CHANGELOG.md` before
  packaging.
- Release candidates are produced by the manual workflow and remain artifacts.
- Tag-triggered workflows may create draft GitHub Releases only.
- Do not publish a release, push release tags, upload public DMG assets, or
  move or delete tags without maintainer approval.
- Do not reuse or retag a published version. Use a new patch version for any
  rebuild or hotfix.
- Do not bypass signing, notarization, checksum, Gatekeeper, or final QA
  requirements.
- When the release process changes, update both the workflow and
  `documentation/RELEASE.md`.

## Public Website

- Website source lives in `documentation/` and is public-facing.
- Keep the privacy policy aligned with website data collection.
- Preserve the website deployment's secret-safe handling of analytics
  configuration; never commit or print secret values.
- Do not put internal-only notes in `documentation/`.
