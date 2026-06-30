# Repository Instructions For AI Agents

These instructions apply to the entire Dimmerly repository.

## Release Process Is Mandatory

Before changing any release-related file or action, read `documentation/RELEASE.md`.
Before recommending release publication or tag operations, also check `documentation/REPOSITORY_SETTINGS.md`.

Release-related work includes changes to:

- `Dimmerly.xcodeproj` version or signing settings
- `CHANGELOG.md`
- `.github/workflows/release.yml`
- `ExportOptions-DeveloperID.plist`
- release tags, GitHub Releases, DMG assets, notarization, or signing

AI agents must follow these rules:

- Public releases use stable SemVer only: `MAJOR.MINOR.PATCH`.
- Public release tags must be annotated tags in the form `vMAJOR.MINOR.PATCH`.
- `MARKETING_VERSION` must exactly match the tag version without the leading `v`.
- `CURRENT_PROJECT_VERSION` must be a monotonically increasing positive integer.
- `CHANGELOG.md` must have a release heading for the version before packaging.
- Release candidates are produced by the manual GitHub Actions workflow and stay as artifacts.
- Tag-triggered workflows may create draft GitHub Releases only.
- Do not publish a GitHub Release, push release tags, upload public DMG assets, or move/delete tags unless the user explicitly asks for that action.
- Do not bypass signing, notarization, checksum, Gatekeeper, or final QA steps from `documentation/RELEASE.md`.
- Do not reuse or retag a published version. Use a new patch version for rebuilds or hotfixes.

When implementing release process changes, update both the workflow and `documentation/RELEASE.md` so the automation and human runbook stay aligned.

## Coding And Editing

- Keep edits scoped to the user request.
- Prefer existing project conventions and commands from `BUILDING.md` and `Justfile`.
- Do not revert unrelated local changes.
- Run the narrowest useful validation before reporting completion.

## Internal Notes

- Keep internal development notes in the gitignored `docs/` directory.
- Do not put internal-only notes in the public `documentation/` directory.
