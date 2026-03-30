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

---

## Benchmark Comparison

### Codebase Size

| Metric | Legacy (cpina) | Current (terraform-registry-sync) |
|--------|---------------|-----------------------------------|
| **Core script** | 176 lines (`entrypoint.sh`) | 603 lines (`publish-module.sh`) |
| **Workflow YAML** | N/A (user writes their own) | 419 lines (`publish-terraform-modules.yml`) |
| **Config/manifest** | 77 lines (`action.yml`) | 42 lines (`terraform-modules.json`) |
| **Setup tooling** | None | 181 lines (`validate-setup.sh`) |
| **Tests** | None | 274 lines (`publish-module.bats`, 18 tests) |
| **Total shipped lines** | ~253 | ~1,519 |

### Runtime Overhead

| Metric | Legacy | Current |
|--------|--------|---------|
| **Container build** | ~110-160 MB Alpine image (built per run) | None (native runner) |
| **Docker pull + build** | ~15-30s cold start | 0s |
| **Terraform setup** | N/A | ~10-15s (`setup-terraform` + `setup-tflint`) |
| **Runner startup** | Docker container init | GitHub runner (already running) |
| **Net cold-start overhead** | Higher (Docker build on every run) | Lower (native, tool setup cached) |

### Git Operations Per Single-Module Publish

| Operation | Legacy | Current |
|-----------|--------|---------|
| **Clone** | 1 shallow (`--depth 1`) | 1 shallow (`--depth 1`) |
| **Config** | 4 (`user.email`, `user.name`, `http.version`, `lfs`) | 3 (`safe.directory`, `user.name`, `user.email`) |
| **Diff/status** | 2 (`git status`, `git diff-index`) | 2 (`git diff-index`, `git ls-files`) |
| **Stage + commit** | 2 (`git add .`, `git commit`) | 2 (`git add -A`, `git commit`) |
| **Push** | 1 | 1 (staging) or 2 (production: commit + tag) |
| **Tag/release** | 0 | 3 (production: `git tag`, `git push tag`, `gh release create`) |
| **Total git ops** | 10 | 9 (staging) or 13 (production) |

### Network Round-Trips Per Publish

| Phase | Legacy | Current |
|-------|--------|---------|
| **SSH keyscan** | 1 | 0 (uses HTTPS + App token) |
| **Clone** | 1 | 1 |
| **Push commit** | 1 | 1 |
| **Push tag** | 0 | 1 (production only) |
| **Verify tag remote** | 0 | 1 (production only) |
| **Create release** | 0 | 1 (production only, `gh release create`) |
| **Artifact upload** | 0 | 1 (payload artifact) |
| **Artifact download** | 0 | 1 (publish job downloads payload) |
| **Token generation** | 0 | 1 (GitHub App token mint) |
| **Total (staging)** | 3 | 5 |
| **Total (production)** | 3 | 8 |

### Copy/Sync Performance

| Metric | Legacy | Current |
|--------|--------|---------|
| **Method** | `cp -ra` (full recursive copy) | `rsync --delete` (differential sync) |
| **Pre-check** | None | `rsync -n` dry-run + deletion count |
| **First publish** | Equivalent speed | Equivalent speed |
| **Subsequent publishes** | Full copy every time | rsync transfers only changed files |
| **Large module (100+ files, few changes)** | Copies all 100+ files | Transfers only changed files |
| **Forbidden file handling** | None (copies everything) | `find + delete` sweep after copy |

### Validation Overhead (Current Only)

| Step | Estimated Time | Skippable? |
|------|---------------|------------|
| `terraform fmt -check -recursive` | 1-3s | No |
| `terraform init -backend=false` | 5-15s (provider download) | No |
| `terraform validate` | 1-3s | No |
| `tflint --init` + `tflint` | 3-10s | Yes (`SKIP_TFLINT=true`) |
| `terraform test` | 10-60s (if tests exist) | Yes (off by default) |
| **Total validation overhead** | ~10-30s typical | Legacy has 0s (no validation) |

### End-to-End Estimated Timeline (Single Module)

| Phase | Legacy | Current (staging) | Current (production) |
|-------|--------|-------------------|---------------------|
| **Runner/container start** | 15-30s (Docker build) | 5-10s (runner allocation) | 5-10s |
| **Checkout** | 0s (runs inside action) | 3-5s | 3-5s |
| **Tool setup** | 0s (baked in Docker) | 10-15s (Terraform + TFLint) | 10-15s |
| **Discover modules** | N/A (hardcoded) | 2-5s | 2-5s |
| **Build payload** | 1-3s (`cp -ra`) | 2-5s (flatten + copy + strip) | 2-5s |
| **Validation** | 0s (none) | 10-30s | 10-30s |
| **Artifact upload/download** | 0s | 5-15s | 5-15s |
| **Attestation** | 0s | 3-5s | 3-5s |
| **App token generation** | 0s | 2-3s | 2-3s |
| **Clone target** | 3-5s | 3-5s | 3-5s |
| **Sync** | 1-3s | 2-5s | 2-5s |
| **Push** | 3-5s | 3-5s | 3-5s |
| **Tag + release** | 0s | 0s | 5-10s |
| **Environment approval** | 0s | 0s | Manual wait |
| **Total (no approval wait)** | ~25-50s | ~50-110s | ~55-120s |

### Multi-Module Scaling

| Modules | Legacy | Current |
|---------|--------|---------|
| **1 module** | 1 workflow run | 1 workflow run (3 jobs) |
| **2 modules** | 2 separate workflow runs (sequential or manual) | 1 workflow run, matrix parallel (2x validate, 2x publish) |
| **5 modules** | 5 separate runs | 1 workflow run, matrix parallel (5x validate, 5x publish) |
| **Adding a module** | New workflow file or matrix edit | 1 JSON entry in manifest |
| **Scaling pattern** | Linear: N modules = N workflow configs | Constant: N modules = 1 workflow, N matrix entries |

### Resource Usage

| Resource | Legacy | Current |
|----------|--------|---------|
| **Docker image storage** | ~110-160 MB per run (cached after first) | 0 (native runner) |
| **Artifact storage** | 0 | Payload artifact per module (7-day retention) |
| **Secrets** | 1 PAT (shared across all repos) | 2 secrets per environment (App ID + key) |
| **GitHub API calls** | 0 | 3-6 per publish (token mint, attestation, release) |
| **Runner minutes** | ~1 min per module | ~2 min per module (includes validation) |

### Tradeoff Summary

| | Legacy wins | Current wins |
|---|------------|-------------|
| **Speed (single module, no validation)** | Faster by ~30-60s (no validation, no artifact round-trip) | |
| **Speed (multi-module)** | | Matrix parallelism, single workflow run |
| **Subsequent syncs (large repos)** | | rsync differential transfer |
| **Cold start** | | No Docker build overhead |
| **Operational cost** | Fewer API calls, less storage | |
| **Safety cost** | | Validation catches errors before publish |
| **Scaling cost** | | Zero-config module additions |

> **Bottom line**: The current pipeline adds ~30-60 seconds per module compared to the legacy action, almost entirely from validation and artifact handling. This is the cost of catching broken Terraform before it reaches production. For multi-module publishes, matrix parallelism recovers most of that overhead.
