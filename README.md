# Terraform Registry Sync

Manifest-driven GitHub Actions pipeline that validates, packages, and publishes Terraform modules from an internal monorepo to public registry repositories.

## Why This Exists

Publishing Terraform modules to separate registry repos is a common pattern. Doing it safely requires validation before publish, staging/production separation, least-privilege auth, audit trails, and guardrails against destructive sync. This system handles all of that with three files.

## Architecture

```
discover  -->  validate_and_package  -->  publish_staging
                                     -->  publish_production (requires approval)
```

| Component | File | Purpose |
|-----------|------|---------|
| Workflow | `.github/workflows/publish-terraform-modules.yml` | Orchestrates the three-job pipeline |
| Manifest | `.github/terraform-modules.json` | Declares modules, repos, copy/strip rules |
| Script | `scripts/terraform/publish-module.sh` | Builds payloads, validates, generates manifests, syncs to targets |
| Setup check | `scripts/terraform/validate-setup.sh` | Verifies GitHub-side configuration (repos, environments, secrets) |

## How It Triggers

| Event | What happens |
|-------|--------------|
| **Pull request** touching `deploy/terraform/**` | Validate only — no publish |
| **Push to `main`** | Discover changed modules, publish to **staging** repos |
| **Tag push** like `terraform-gcp-v1.2.3` | Publish matched module to **production** repo, create release |
| **Manual dispatch** | Choose module, channel, source ref, version, dry run |

## Setup

### 1. Create a GitHub App

Register a GitHub App with these repository permissions:

- **Contents**: Read and write

Install it on the target repositories (both staging and production).

### 2. Configure Environments

Create two GitHub environments in the source repo:

| Environment | Secrets | Protection Rules |
|-------------|---------|------------------|
| `terraform-registry-staging` | `TERRAFORM_SYNC_APP_PRIVATE_KEY` | None required |
| `terraform-registry-production` | `TERRAFORM_SYNC_APP_PRIVATE_KEY` | Required reviewers, tag pattern `terraform-*-v*` |

Set the repository variable `TERRAFORM_SYNC_APP_ID` (same App ID for both, or use separate Apps for stronger isolation).

### 3. Prepare Target Repositories

Each target repo must contain a marker file in its root:

```bash
echo "This repository is managed by terraform-registry-sync." > .registry-sync-root
git add .registry-sync-root && git commit -m "Add sync marker" && git push
```

The publish script refuses to sync without this file — it prevents accidental writes to the wrong repo.

### 4. Add the Manifest

Edit `.github/terraform-modules.json` to declare your modules:

```json
{
  "modules": [
    {
      "name": "gcp",
      "source_path": "deploy/terraform/gcp",
      "staging_repo": "terraform-gcp-modules-staging",
      "production_repo": "terraform-gcp-modules",
      "tag_prefix": "terraform-gcp-v",
      "flatten_dirs": ["infra"],
      "copy_dirs": ["bootstrap", "tests", "policies", "modules", "examples"],
      "copy_files": ["README.md", ".tflint.hcl", "LICENSE", "CHANGELOG.md"],
      "strip_patterns": [
        "*.tfstate", "*.tfstate.*", "*.tfvars", "*.tfvars.json",
        ".terraform/", ".terraform.lock.hcl"
      ]
    }
  ]
}
```

| Field | Description |
|-------|-------------|
| `name` | Unique module identifier, used in artifact names and concurrency groups |
| `source_path` | Path to the module inside the monorepo |
| `staging_repo` / `production_repo` | Target repository names (without owner) |
| `tag_prefix` | Prefix for version tags, e.g. `terraform-gcp-v` matches tag `terraform-gcp-v1.2.3` |
| `flatten_dirs` | Directories whose `*.tf` and `*.tf.json` files are copied into the payload root |
| `copy_dirs` | Subdirectories copied as-is if they exist |
| `copy_files` | Individual files copied if they exist |
| `strip_patterns` | Glob patterns removed from the payload after copy |

## Script Commands

`scripts/terraform/publish-module.sh` supports these commands:

| Command | Purpose | Key env vars |
|---------|---------|-------------|
| `build-payload` | Flatten, copy, and strip files into a payload directory | `SOURCE_PATH`, `PAYLOAD_DIR`, `FLATTEN_DIRS`, `COPY_DIRS`, `COPY_FILES`, `STRIP_PATTERNS` |
| `validate` | Run `terraform fmt`, `init`, `validate`, `tflint` on a payload | `PAYLOAD_DIR` |
| `generate-manifest` | Create `MANIFEST.txt` with SHA256 hashes and audit metadata | `PAYLOAD_DIR`, `MODULE_NAME`, `SOURCE_REPO`, `SOURCE_SHA` |
| `summary` | Print file count, total size, validation status, and path | `PAYLOAD_DIR`, `MODULE_NAME`, `VALIDATION_STATUS` |
| `build-release` | End-to-end: reads manifest, builds, validates, generates manifest, prints summary | `MODULE_NAME`, `MANIFEST_FILE`, `RELEASE_BASE` |
| `publish` | Sync a validated payload to a target repo via rsync, optionally tag and release | `PAYLOAD_DIR`, `TARGET_REPO`, `GIT_TOKEN`, `CHANNEL`, ... |

### Local Release Build

To assemble a release-ready package locally (requires `terraform` and `tflint`):

```bash
MODULE_NAME="gcp" scripts/terraform/publish-module.sh build-release
```

This reads `.github/terraform-modules.json`, builds into `release/gcp/`, validates, generates `MANIFEST.txt`, and prints a summary. The release directory is cleaned up on failure.

Override the output location or manifest path:

```bash
MODULE_NAME="gcp" \
  MANIFEST_FILE=".github/terraform-modules.json" \
  RELEASE_BASE="/tmp/release" \
  SOURCE_REPO="org/infra-monorepo" \
  SOURCE_SHA="$(git rev-parse HEAD)" \
  scripts/terraform/publish-module.sh build-release
```

### MANIFEST.txt

Every release package includes a `MANIFEST.txt` at its root:

```
# Module: gcp
# Source: org/infra-monorepo @ a1b2c3d4
# Timestamp: 2026-03-30T14:22:00Z
#
sha256:abc123...  main.tf
sha256:def456...  variables.tf
sha256:789ghi...  bootstrap/main.tf
```

This provides a verifiable inventory of exactly what was published, tied to a source commit.

## Usage

### Staging Publish (automatic)

Merge a PR that changes files under a module's `source_path`. The pipeline detects changed modules and publishes them to their staging repos.

### Production Publish (tag-triggered)

```bash
git tag terraform-gcp-v1.2.3
git push origin terraform-gcp-v1.2.3
```

The pipeline:
1. Matches the tag to a module via `tag_prefix`
2. Validates and packages the module
3. Waits for environment approval (required reviewers)
4. Pushes to the production repo
5. Creates an annotated tag and GitHub release on the target

### Manual Override

Use **Actions > Publish Terraform Modules > Run workflow**:

- **module**: Module name from the manifest
- **channel**: `staging` or `production`
- **source_ref**: Branch, tag, or SHA to publish from (default: current)
- **version**: Required for production (e.g., `1.2.3`)
- **dry_run**: Preview without pushing

### Rollback

Do not force-move tags. Instead, publish a corrective version:

```bash
# Option A: re-publish a known-good ref with a new version
# via workflow_dispatch: module=gcp, channel=production, source_ref=<good-sha>, version=1.2.4

# Option B: tag a revert commit
git revert HEAD
git push origin main
git tag terraform-gcp-v1.2.4
git push origin terraform-gcp-v1.2.4
```

## Validation

Every publish is gated by these checks (run on the exact payload that will be published):

| Check | Blocks publish? | Can skip? |
|-------|----------------|-----------|
| `terraform fmt -check -recursive` | Yes | No |
| `terraform init -backend=false` | Yes (hard fail) | No |
| `terraform validate` | Yes | No |
| `tflint` | Yes | `SKIP_TFLINT=true` |
| `terraform test` | Yes | Off by default (`SKIP_TF_TEST=true`) |

## Security Model

- **Authentication**: GitHub App installation tokens (short-lived, repo-scoped)
- **No PATs**: No personal access tokens used for cross-repo writes
- **Environment isolation**: Staging and production use separate secrets
- **Least privilege**: Tokens scoped to the specific target repo with `contents: write` only
- **Destructive sync guard**: Marker file required in target repo, `.git/` excluded from rsync
- **Pinned actions**: All third-party actions referenced by SHA, not mutable tags

## Audit Trail

Every publish commit on the target repo includes:

```
Sync module 'gcp' from source (production)

Source-Repo: org/infra-monorepo
Source-SHA: abc1234def5678
Module: gcp
Channel: production
Workflow-Run: https://github.com/org/infra-monorepo/actions/runs/12345
```

Production releases include the same metadata in the release body.

## Concurrency

| Channel | Concurrency group | Cancel in-progress? |
|---------|------------------|-------------------|
| Staging | `terraform-publish-staging-<module>` | Yes — superseded runs collapse |
| Production | `terraform-publish-production-<module>` | No — in-flight releases are never cancelled |

## Adding a New Module

1. Add an entry to `.github/terraform-modules.json`
2. Create the staging and production target repos
3. Add `.registry-sync-root` to each target repo
4. Install the GitHub App on the new target repos
5. Push a change to the module's source path — staging publish happens automatically
6. Tag for production when ready

No workflow YAML changes required.

## File Structure

```
.github/
  workflows/
    publish-terraform-modules.yml    # Pipeline orchestration
  terraform-modules.json             # Module manifest
scripts/
  terraform/
    publish-module.sh                # Build, validate, manifest, publish logic
    validate-setup.sh                # Pre-flight check for GitHub-side configuration
tests/
  publish-module.bats                # bats tests for the publish script
  fixtures/
    fake-module/                     # Test fixture module
deploy/
  terraform/
    gcp/                             # GCP module source
    aws/                             # AWS module source
release/                             # Local build-release output (gitignored)
```

## Requirements

- GitHub-hosted runners (ubuntu-24.04)
- GitHub App with Contents read/write on target repos
- GitHub Environments configured with appropriate secrets and protection rules
- Target repos initialized with `.registry-sync-root` marker file
