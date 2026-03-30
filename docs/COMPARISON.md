# Comparison: cpina/push-to-another-repository vs terraform-registry-sync

Side-by-side comparison of the legacy GitHub Action (`cpina/github-action-push-to-another-repository`) and the current manifest-driven pipeline (`terraform-registry-sync`).

---

## Architecture

| Aspect | Legacy (cpina) | Current (terraform-registry-sync) |
|--------|---------------|-----------------------------------|
| **Runtime** | Docker container (Alpine + git) | GitHub-hosted runner (ubuntu-24.04) |
| **Entry point** | Single `entrypoint.sh` (176 lines) | `publish-module.sh` (550+ lines, 6 subcommands) |
| **Configuration** | Action inputs in `action.yml` | JSON manifest (`.github/terraform-modules.json`) |
| **Scope** | Generic directory push to any repo | Terraform module publish pipeline |
| **Components** | 3 files: `action.yml`, `Dockerfile`, `entrypoint.sh` | 3 core files: workflow YAML, manifest JSON, helper script |
| **Multi-module** | One invocation per module (manual matrix) | Manifest-driven auto-discovery with matrix strategy |

## Trigger Model

| Trigger | Legacy | Current |
|---------|--------|---------|
| **PR** | Not supported | Validate only (no publish) |
| **Push to main** | Manual configuration per workflow | Auto-discover changed modules, publish to staging |
| **Version tag** | Not supported | Tag like `terraform-gcp-v1.2.3` triggers production release |
| **Manual dispatch** | Not supported | Full control: module, channel, ref, version, dry run |
| **Scheduled** | Not supported | Not supported (neither needs it) |

## Security

| Aspect | Legacy | Current |
|--------|--------|---------|
| **Authentication** | SSH deploy key or PAT (`API_TOKEN_GITHUB`) | GitHub App installation token (short-lived, repo-scoped) |
| **Token scope** | Broad PAT with repo access to all repos | Scoped to single target repo per job |
| **Token lifetime** | Long-lived (PAT never expires unless rotated) | Short-lived (GitHub App token, ~1 hour) |
| **Token in URLs** | Token embedded in git remote URL | `GIT_ASKPASS` script — token never in URLs or logs |
| **Action pinning** | Users typically use `@v5` mutable tag | All actions pinned to full SHA with version comment |
| **Permissions** | Not specified (inherits default) | `contents: read` at workflow level, overrides per job |
| **Environment isolation** | None | Separate environments for staging and production |
| **Environment approvals** | None | Required reviewers for production |
| **Secret management** | Single shared secret | Per-environment secrets (staging vs production) |

## Validation

| Check | Legacy | Current |
|-------|--------|---------|
| **terraform fmt** | None | `terraform fmt -check -recursive` |
| **terraform init** | None | `terraform init -backend=false` |
| **terraform validate** | None | `terraform validate` |
| **tflint** | None | `tflint` (skippable) |
| **terraform test** | None | Optional (off by default) |
| **Validation target** | N/A | Validates the exact payload that gets published |
| **Pre-publish gate** | None — copies and pushes directly | All checks must pass before artifact upload |

## Sync Model

| Aspect | Legacy | Current |
|--------|--------|---------|
| **Copy method** | `cp -a` source into target after wiping target dir | `rsync --delete` with exclusions |
| **Destructive behavior** | Deletes everything in target dir, copies fresh | Controlled rsync with safety thresholds |
| **Safety guard** | None — blindly deletes target contents | Marker file (`.registry-sync-root`) required in target repo |
| **Deletion threshold** | None | Aborts if >50% of target files would be deleted |
| **What gets published** | Raw source directory | Curated payload artifact (flattened, stripped, validated) |
| **Forbidden file stripping** | None — copies everything | Strips `*.tfstate`, `*.tfvars`, `.terraform/`, etc. |
| **Payload packaging** | Direct workspace-to-target | Build artifact uploaded, then downloaded by publish job |
| **File flattening** | None — preserves source structure | `infra/*.tf` flattened into root |

## Release Model

| Aspect | Legacy | Current |
|--------|--------|---------|
| **Staging** | Not supported | Commit to staging repo (no release) |
| **Production** | Not supported | Tag + GitHub Release on target repo |
| **Release creation** | None | `gh release create --verify-tag --target <sha>` |
| **Tag safety** | N/A | Verifies tag exists on remote before creating release |
| **Version source** | N/A | Extracted from git tag (e.g., `terraform-gcp-v1.2.3` -> `1.2.3`) |
| **Rollback** | Re-run with old source | Publish corrective version (no tag mutation) |

## Audit Trail

| Aspect | Legacy | Current |
|--------|--------|---------|
| **Commit message** | Configurable template with `ORIGIN_COMMIT` variable | Structured metadata: source repo, SHA, module, channel, run URL |
| **Release notes** | N/A | Source link, target SHA, workflow run URL, payload digest |
| **MANIFEST.txt** | None | SHA256 hashes of every file + source metadata |
| **Traceability** | Commit message only | Source commit -> workflow run -> payload artifact -> target commit -> release |

## Concurrency

| Aspect | Legacy | Current |
|--------|--------|---------|
| **Concurrency control** | None | Per-module, per-channel concurrency groups |
| **Staging** | N/A | `cancel-in-progress: true` (superseded runs collapse) |
| **Production** | N/A | `cancel-in-progress: false` (in-flight releases never cancelled) |

## Operational Tooling

| Tool | Legacy | Current |
|------|--------|---------|
| **Setup validation** | None | `validate-setup.sh` checks repos, markers, environments, secrets |
| **Dry run** | None | `DRY_RUN=true` skips push/release |
| **Test suite** | None | 18 bats tests with fixture module |
| **Local build** | N/A | `build-release` command for local packaging |
| **Artifact attestation** | None | `actions/attest-build-provenance` on payload artifacts |

## Adding a New Module

| Step | Legacy | Current |
|------|--------|---------|
| **1** | Create new workflow file or add matrix entry | Add entry to `terraform-modules.json` |
| **2** | Configure secrets | Create target repos + add `.registry-sync-root` |
| **3** | Configure action inputs | Install GitHub App on target repos |
| **4** | Test manually | Push change — staging happens automatically |
| **Workflow changes needed** | Yes (new workflow or matrix modification) | No |

## Summary

| Dimension | Legacy | Current |
|-----------|--------|---------|
| **Simplicity** | Very simple, generic | More complex, domain-specific |
| **Security** | Basic (PAT, no pinning, no validation) | Hardened (App tokens, SHA pinning, least privilege, env isolation) |
| **Validation** | None | Full Terraform validation suite |
| **Safety** | Destructive with no guardrails | Marker files, deletion thresholds, dry run |
| **Auditability** | Commit message only | Full chain: source -> artifact -> target -> release |
| **Scalability** | Manual per-module setup | Manifest-driven, zero workflow changes per module |
| **Testability** | No tests | 18 automated tests |
| **Maintenance** | Feature-frozen | Actively maintained |

The legacy action is a useful generic building block for simple cross-repo pushes. The current system is a purpose-built Terraform module publish pipeline that addresses the security, validation, and operational gaps identified during the analysis of the legacy approach.
