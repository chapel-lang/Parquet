# Releasing

This repo uses GitHub Actions to publish Parquet to the mason registry and then
open a follow-up PR that bumps the next unreleased version.

## One-time Setup

Configure these on `chapel-lang/Parquet` under Settings → Secrets and variables
→ Actions.

### Secrets

The PATs stored in these secrets must be created by the user identified by
`REGISTRY_FORK_OWNER`, because the workflow pushes to that user's fork of
`mason-registry`. The PATs are then saved as repository secrets on
`chapel-lang/Parquet` so the Actions workflows can use them.

| Name | Token type | Scope | Purpose |
|---|---|---|---|
| `MASON_REGISTRY_PAT` | Fine-grained PAT | `<REGISTRY_FORK_OWNER>/mason-registry` — Contents: read/write | Push release branch to the mason-registry fork |
| `MASON_REGISTRY_PRS` | Classic PAT | `public_repo` | Open PR on `chapel-lang/mason-registry` |

### Variables

| Name | Value | Purpose |
|---|---|---|
| `REGISTRY_FORK_OWNER` | GitHub username owning the mason-registry fork | Identifies the fork to push to |

### Repository default token permissions

`chapel-lang/Parquet` → Settings → Actions → General → Workflow permissions must
be set to **"Read and write permissions"**. The workflows rely on `GITHUB_TOKEN`
to create tags and push branches, so the default token needs write access.

### Creating the PATs

**`MASON_REGISTRY_PAT`** (fine-grained):
1. github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens
2. Resource owner: your account; Repository access: only `<you>/mason-registry`
3. Permissions: Contents → Read and write

**`MASON_REGISTRY_PRS`** (classic):
1. github.com → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Scope: `public_repo` only

---

## Release Steps

1. Confirm `MASON_REGISTRY_PAT` and `MASON_REGISTRY_PRS` have not expired.
   If either has, recreate it following the steps above and update the secret.

2. Confirm the release version in `Mason.toml` on `main`.

   ```sh
   grep version Mason.toml
   ```

2. On `chapel-lang/Parquet`, run the `Publish to mason registry` workflow from `main`.

3. Wait for the workflow to:
   - create tag `v<version>`
   - push a branch to `<REGISTRY_FORK_OWNER>/mason-registry`
   - open a PR on `chapel-lang/mason-registry`

4. Get the `mason-registry` PR reviewed and merged by a registry maintainer.

5. Review and merge the `Bump version for next release` PR opened by `bump-minor-version.yml`.

## Result

After a successful release:
- the released version is tagged in this repo
- the same version is added to `chapel-lang/mason-registry`
- the next unreleased minor version is proposed in a follow-up PR
