# Repository Settings

These settings cannot be fully enforced from files in this repository, but they should be configured before public direct-download releases start.

## Branch Protection

Protect `main` with:

- Require pull request before merging.
- Require status checks to pass before merging:
  - `workflow-lint`
  - `format`
  - `lint`
  - `test`
  - `build-appstore`
- Require branches to be up to date before merging.
- Require conversation resolution before merging.
- Restrict who can push to matching branches.
- Do not allow force pushes.
- Do not allow deletions.

For repositories with multiple maintainers, also enable:

- Require at least one approving review.
- Require review from Code Owners.
- Dismiss stale approvals when new commits are pushed.

For a solo-maintainer repository, do not require approving reviews or Code
Owner reviews. GitHub does not allow pull request authors to approve their own
pull requests, so those rules make protected-branch merges impossible without a
second maintainer.

## Tag Protection

Protect release tags matching:

```text
v*.*.*
```

Only release owners should be allowed to create release tags. Nobody should be allowed to update or delete release tags after they are pushed.

## Actions

Recommended Actions settings:

- Allow GitHub Actions and trusted third-party actions used by this repository.
- Require approval for workflows from first-time external contributors.
- Keep the default workflow token permission read-only.
- Grant write permissions only to workflows/jobs that need them, such as the release job that creates a draft GitHub Release.
- Store signing and App Store Connect credentials as repository or environment secrets.
- Protect release secrets with a GitHub Environment if the repository plan supports required reviewers.

## Pages

GitHub Pages must use **GitHub Actions** as its publishing source. The
`.github/workflows/pages.yml` workflow builds the public static site from:

- `documentation/index.html`
- `documentation/privacy-policy.html`
- `documentation/support.html`
- `images/image1.png`, published as `assets/dimmerly-menu.png`
- `images/github-social-preview.jpg`, published as
  `assets/dimmerly-social-preview.jpg`
- `Dimmerly/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png`, published
  as `assets/dimmerly-icon.png`

The rest of `documentation/` remains visible in the repository but is not
published to GitHub Pages.

These public URLs must resolve:

- `https://olujicz.github.io/Dimmerly/`
- `https://olujicz.github.io/Dimmerly/privacy-policy.html`
- `https://olujicz.github.io/Dimmerly/support.html`

Set the repository **Website** field to:

```text
https://olujicz.github.io/Dimmerly/
```

## Security

- Enable Dependabot alerts.
- Enable Dependabot security updates.
- Enable Dependabot version updates for GitHub Actions.
- Enable secret scanning if available.
- Enable private vulnerability reporting if available.

## Releases

- Public release assets are created only by `.github/workflows/release.yml`.
- GitHub Releases created by automation must remain drafts until final QA from `documentation/RELEASE.md` passes.
- Do not upload replacement assets to a published release. Publish a new patch version instead.
