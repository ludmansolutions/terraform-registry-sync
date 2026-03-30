#!/usr/bin/env bash
#
# publish-module.sh — Build, validate, and publish a Terraform module
#                     to a target registry repository.
#
# Usage:
#   publish-module.sh <command> [options]
#
# Commands:
#   build-payload   Build a curated payload from source into a staging directory
#   validate        Run Terraform validation suite against a payload directory
#   publish         Sync a validated payload to a target repository
#
# This script is called by the publish-terraform-modules workflow.
# It is not intended to be run standalone without the workflow context.

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_FILE=".registry-sync-root"
# Safety threshold: abort if rsync would delete more than this percentage of
# target repo files. Protects against manifest misconfiguration pointing at
# wrong source paths or flattening rule changes that wipe most content.
SYNC_DELETE_THRESHOLD_PCT="${SYNC_DELETE_THRESHOLD_PCT:-50}"
SYNC_DELETE_THRESHOLD_ABS="${SYNC_DELETE_THRESHOLD_ABS:-100}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { echo "[publish-module] $*"; }
err()  { echo "[publish-module] ERROR: $*" >&2; }
die()  { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Command: build-payload
# ---------------------------------------------------------------------------
# Builds a curated payload directory from the monorepo source path.
#
# Required env vars:
#   SOURCE_PATH       — path to the module inside the monorepo checkout
#   PAYLOAD_DIR       — output directory for the curated payload
#   FLATTEN_DIRS      — JSON array of dirs whose *.tf files get flattened to root
#   COPY_DIRS         — JSON array of subdirectories to copy if they exist
#   COPY_FILES        — JSON array of top-level files to copy if they exist
#   STRIP_PATTERNS    — JSON array of glob patterns to strip after copy
# ---------------------------------------------------------------------------
cmd_build_payload() {
  : "${SOURCE_PATH:?SOURCE_PATH is required}"
  : "${PAYLOAD_DIR:?PAYLOAD_DIR is required}"
  : "${FLATTEN_DIRS:?FLATTEN_DIRS is required}"
  : "${COPY_DIRS:?COPY_DIRS is required}"
  : "${COPY_FILES:?COPY_FILES is required}"
  : "${STRIP_PATTERNS:?STRIP_PATTERNS is required}"

  [[ -d "$SOURCE_PATH" ]] || die "Source path does not exist: $SOURCE_PATH"

  log "Building payload from $SOURCE_PATH into $PAYLOAD_DIR"
  mkdir -p "$PAYLOAD_DIR"

  # 1. Flatten specified directories — copy *.tf files into payload root
  local dir
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    local src="$SOURCE_PATH/$dir"
    if [[ -d "$src" ]]; then
      log "  Flattening $dir/*.tf → payload root"
      find "$src" -maxdepth 1 -name '*.tf' -exec cp {} "$PAYLOAD_DIR/" \;
      # Also copy *.tf.json if present
      find "$src" -maxdepth 1 -name '*.tf.json' -exec cp {} "$PAYLOAD_DIR/" \;
    else
      log "  Flatten dir $dir not found, skipping"
    fi
  done < <(echo "$FLATTEN_DIRS" | jq -r '.[]')

  # 2. Copy allowed subdirectories
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    local src="$SOURCE_PATH/$dir"
    if [[ -d "$src" ]]; then
      log "  Copying directory $dir/"
      cp -a "$src" "$PAYLOAD_DIR/$dir"
    fi
  done < <(echo "$COPY_DIRS" | jq -r '.[]')

  # 3. Copy allowed top-level files
  local file
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local src="$SOURCE_PATH/$file"
    if [[ -f "$src" ]]; then
      log "  Copying file $file"
      cp -a "$src" "$PAYLOAD_DIR/$file"
    fi
  done < <(echo "$COPY_FILES" | jq -r '.[]')

  # 4. Strip forbidden patterns
  local pattern
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    log "  Stripping pattern: $pattern"
    # Use find with -name for glob patterns, handle directory patterns
    if [[ "$pattern" == */ ]]; then
      # Directory pattern — strip trailing slash for find
      find "$PAYLOAD_DIR" -type d -name "${pattern%/}" -exec rm -rf {} + 2>/dev/null || true
    else
      find "$PAYLOAD_DIR" -type f -name "$pattern" -delete 2>/dev/null || true
    fi
  done < <(echo "$STRIP_PATTERNS" | jq -r '.[]')

  # 5. Verify payload is not empty and meets minimum expectation
  local file_count
  file_count=$(find "$PAYLOAD_DIR" -type f | wc -l)
  if [[ "$file_count" -eq 0 ]]; then
    die "Payload is empty after build — check source_path and flatten_dirs configuration"
  fi

  local min_expected="${MIN_EXPECTED_FILES:-0}"
  if [[ "$min_expected" -gt 0 ]] && [[ "$file_count" -lt "$min_expected" ]]; then
    die "Payload has $file_count files, below the manifest minimum of $min_expected. This likely indicates a misconfigured source_path or flatten_dirs."
  fi

  log "Payload built: $file_count files"
  find "$PAYLOAD_DIR" -type f | sort | head -50
  if [[ "$file_count" -gt 50 ]]; then
    log "  ... and $((file_count - 50)) more"
  fi
}

# ---------------------------------------------------------------------------
# Command: validate
# ---------------------------------------------------------------------------
# Runs Terraform validation suite against a built payload.
#
# Required env vars:
#   PAYLOAD_DIR       — directory containing the built payload
#   TERRAFORM_VERSION — Terraform version (for logging)
# Optional env vars:
#   SKIP_TFLINT       — set to "true" to skip tflint
#   SKIP_TF_TEST      — set to "true" to skip terraform test (default: true)
# ---------------------------------------------------------------------------
cmd_validate() {
  : "${PAYLOAD_DIR:?PAYLOAD_DIR is required}"

  local has_errors=0

  log "Validating payload in $PAYLOAD_DIR"
  cd "$PAYLOAD_DIR"

  # 1. terraform fmt -check
  log "--- terraform fmt -check -recursive ---"
  if ! terraform fmt -check -recursive -diff; then
    err "terraform fmt check failed — files are not formatted"
    has_errors=1
  fi

  # 2. terraform init -backend=false
  log "--- terraform init -backend=false ---"
  if ! terraform init -backend=false -input=false; then
    err "terraform init failed — cannot proceed with validation"
    return 1
  fi

  # 3. terraform validate
  log "--- terraform validate ---"
  if ! terraform validate; then
    err "terraform validate failed"
    has_errors=1
  fi

  # 4. tflint (optional)
  if [[ "${SKIP_TFLINT:-false}" != "true" ]]; then
    if command -v tflint &>/dev/null; then
      log "--- tflint ---"
      if [[ -f .tflint.hcl ]]; then
        tflint --init
      fi
      if ! tflint; then
        err "tflint found issues"
        has_errors=1
      fi
    else
      log "tflint not found, skipping"
    fi
  else
    log "tflint skipped (SKIP_TFLINT=true)"
  fi

  # 5. terraform test (optional, off by default)
  if [[ "${SKIP_TF_TEST:-true}" != "true" ]]; then
    if [[ -d tests ]] || compgen -G "*.tftest.hcl" >/dev/null 2>&1; then
      log "--- terraform test ---"
      if ! terraform test; then
        err "terraform test failed"
        has_errors=1
      fi
    else
      log "No test files found, skipping terraform test"
    fi
  fi

  if [[ "$has_errors" -ne 0 ]]; then
    err "Validation failed — publish blocked"
    return 1
  fi

  log "All validation checks passed"
}

# ---------------------------------------------------------------------------
# Command: publish
# ---------------------------------------------------------------------------
# Syncs a validated payload to a target repository using rsync.
#
# Required env vars:
#   PAYLOAD_DIR       — directory containing the validated payload
#   TARGET_REPO       — target repository (owner/name)
#   GIT_TOKEN         — GitHub App token for authentication (never placed in URLs)
#   CHANNEL           — "staging" or "production"
#   MODULE_NAME       — module name for audit metadata
#   SOURCE_SHA        — source commit SHA for audit trail
#   SOURCE_REPO       — source repository (owner/name)
#   GITHUB_RUN_URL    — workflow run URL for audit trail
# Optional env vars:
#   VERSION           — version string for production releases (e.g., "1.2.3")
#   TAG_PREFIX        — tag prefix for this module (e.g., "terraform-gcp-v")
#   DRY_RUN           — set to "true" to skip push/release
#   TARGET_BRANCH     — branch to publish to (default: main)
#   GITHUB_SERVER     — github server hostname (default: github.com)
# ---------------------------------------------------------------------------
cmd_publish() {
  : "${PAYLOAD_DIR:?PAYLOAD_DIR is required}"
  : "${TARGET_REPO:?TARGET_REPO is required}"
  : "${GIT_TOKEN:?GIT_TOKEN is required}"
  : "${CHANNEL:?CHANNEL is required}"
  : "${MODULE_NAME:?MODULE_NAME is required}"
  : "${SOURCE_SHA:?SOURCE_SHA is required}"
  : "${SOURCE_REPO:?SOURCE_REPO is required}"
  : "${GITHUB_RUN_URL:?GITHUB_RUN_URL is required}"

  local target_branch="${TARGET_BRANCH:-main}"
  local dry_run="${DRY_RUN:-false}"
  local github_server="${GITHUB_SERVER:-github.com}"
  local clone_dir
  clone_dir="$(mktemp -d)"

  # Set up GIT_ASKPASS so the token never appears in URLs, error messages,
  # or git remote -v output. The askpass script prints the token to stdout
  # when git requests credentials.
  local askpass_script
  askpass_script="$(mktemp)"
  cat > "$askpass_script" <<'ASKPASS'
#!/usr/bin/env bash
echo "${GIT_TOKEN}"
ASKPASS
  chmod +x "$askpass_script"
  export GIT_ASKPASS="$askpass_script"
  export GIT_TERMINAL_PROMPT=0

  local target_repo_url="https://x-access-token@${github_server}/${TARGET_REPO}.git"

  log "Publishing module '$MODULE_NAME' to $TARGET_REPO ($CHANNEL)"

  # 1. Clone target repo (shallow)
  log "Cloning $TARGET_REPO (branch: $target_branch)"
  git clone --single-branch --branch "$target_branch" --depth 1 \
    "$target_repo_url" "$clone_dir" 2>&1 || {
    die "Failed to clone target repository: $TARGET_REPO. Verify the GitHub App has access to this repo and the branch '$target_branch' exists."
  }

  # 2. Verify marker file exists
  if [[ ! -f "$clone_dir/$MARKER_FILE" ]]; then
    die "Marker file '$MARKER_FILE' not found in target repo — refusing destructive sync. Create '$MARKER_FILE' in the target repo root to enable sync."
  fi

  # 3. Configure git in the clone
  cd "$clone_dir"
  git config --global --add safe.directory "$clone_dir"
  git config user.name "terraform-registry-sync[bot]"
  git config user.email "terraform-registry-sync[bot]@users.noreply.github.com"

  # 4. rsync payload into clone with deletion safety check
  log "Running rsync dry-run to check deletion impact..."
  local dryrun_output
  dryrun_output=$(rsync -avhn --delete \
    --exclude='.git/' \
    --exclude="$MARKER_FILE" \
    "$PAYLOAD_DIR/" "$clone_dir/" 2>&1)

  # Count deletions from dry-run output (lines starting with "deleting ")
  local delete_count
  delete_count=$(echo "$dryrun_output" | grep -c '^deleting ' || true)
  # Count existing files in target (excluding .git and marker)
  local target_file_count
  target_file_count=$(find "$clone_dir" -not -path '*/.git/*' -not -name "$MARKER_FILE" -type f | wc -l)

  log "Dry-run result: $delete_count deletions out of $target_file_count target files"
  echo "$dryrun_output" | tail -30

  # Abort if deletions exceed safety thresholds (unless force override)
  if [[ "$target_file_count" -gt 0 ]] && [[ "$delete_count" -gt 0 ]]; then
    local delete_pct=$(( (delete_count * 100) / target_file_count ))
    if [[ "$delete_count" -gt "$SYNC_DELETE_THRESHOLD_ABS" ]] && \
       [[ "$delete_pct" -gt "$SYNC_DELETE_THRESHOLD_PCT" ]]; then
      if [[ "${FORCE_SYNC:-false}" == "true" ]]; then
        log "WARNING: $delete_count files ($delete_pct%) would be deleted — proceeding due to FORCE_SYNC=true"
      else
        die "Sync safety abort: $delete_count files ($delete_pct%) would be deleted, exceeding thresholds (abs=$SYNC_DELETE_THRESHOLD_ABS, pct=$SYNC_DELETE_THRESHOLD_PCT%). This likely indicates a manifest misconfiguration. Set SYNC_DELETE_THRESHOLD_PCT or SYNC_DELETE_THRESHOLD_ABS to override, or use FORCE_SYNC=true to bypass."
      fi
    fi
  fi

  log "Executing sync:"
  rsync -avh --delete \
    --exclude='.git/' \
    --exclude="$MARKER_FILE" \
    "$PAYLOAD_DIR/" "$clone_dir/" 2>&1

  # 5. Check for changes
  if git diff-index --quiet HEAD -- 2>/dev/null; then
    # Also check for untracked files
    if [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
      log "No changes detected — skipping commit"
      return 0
    fi
  fi

  # 6. Stage and commit with audit metadata
  git add -A

  local commit_msg
  commit_msg="$(cat <<EOF
Sync module '$MODULE_NAME' from source ($CHANNEL)

Source-Repo: $SOURCE_REPO
Source-SHA: $SOURCE_SHA
Module: $MODULE_NAME
Channel: $CHANNEL
Workflow-Run: $GITHUB_RUN_URL
EOF
)"

  git commit -m "$commit_msg"

  # 7. Push
  if [[ "$dry_run" == "true" ]]; then
    log "DRY RUN — skipping push"
    log "Would push to $TARGET_REPO branch $target_branch"
  else
    log "Pushing to $target_branch"
    git push origin "$target_branch"
  fi

  # 8. Tag and release for production
  if [[ "$CHANNEL" == "production" ]] && [[ -n "${VERSION:-}" ]]; then
    local tag="${TAG_PREFIX:-v}${VERSION}"
    local target_commit_sha
    target_commit_sha=$(git rev-parse HEAD)
    log "Creating tag: $tag on commit $target_commit_sha"

    if [[ "$dry_run" == "true" ]]; then
      log "DRY RUN — skipping tag and release"
      log "Would create tag: $tag on $target_commit_sha"
      log "Would create release: $tag"
    else
      git tag -a "$tag" -m "Release $tag

Source-Repo: $SOURCE_REPO
Source-SHA: $SOURCE_SHA
Module: $MODULE_NAME
Workflow-Run: $GITHUB_RUN_URL"

      git push origin "$tag"

      # Verify tag exists on remote before creating release
      local remote_tag
      remote_tag=$(git ls-remote --tags origin "$tag" 2>/dev/null || true)
      if [[ -z "$remote_tag" ]]; then
        die "Tag $tag was not found on remote after push — aborting release"
      fi

      # Compute payload digest for supply-chain verifiability
      local payload_digest=""
      if command -v sha256sum &>/dev/null; then
        payload_digest=$(find "$PAYLOAD_DIR" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
      fi

      log "Creating GitHub release: $tag"
      local release_body
      release_body="$(cat <<EOF
## $MODULE_NAME $tag

**Source:** [$SOURCE_REPO@${SOURCE_SHA:0:8}](https://github.com/$SOURCE_REPO/commit/$SOURCE_SHA)
**Target commit:** \`$target_commit_sha\`
**Workflow run:** $GITHUB_RUN_URL
**Module:** $MODULE_NAME
**Channel:** $CHANNEL
**Payload digest (sha256):** \`${payload_digest:-not computed}\`
EOF
)"

      GH_REPO="$TARGET_REPO" gh release create "$tag" \
        --verify-tag \
        --target "$target_commit_sha" \
        --title "$MODULE_NAME $tag" \
        --notes "$release_body" || {
        err "Release creation failed — tag $tag was pushed but release was not created"
        err "Manual fix: gh release create $tag --repo $TARGET_REPO --verify-tag --target $target_commit_sha"
        return 1
      }

      log "Release $tag created successfully"
    fi
  fi

  log "Publish complete for $MODULE_NAME ($CHANNEL)"
}

# ---------------------------------------------------------------------------
# Command: generate-manifest
# ---------------------------------------------------------------------------
# Generates a MANIFEST.txt with SHA256 hashes and audit metadata.
#
# Required env vars:
#   PAYLOAD_DIR       — directory containing the built payload
#   MODULE_NAME       — module name for audit metadata
# Optional env vars:
#   SOURCE_REPO       — source repository (owner/name)
#   SOURCE_SHA        — source commit SHA
# ---------------------------------------------------------------------------
cmd_generate_manifest() {
  : "${PAYLOAD_DIR:?PAYLOAD_DIR is required}"
  : "${MODULE_NAME:?MODULE_NAME is required}"

  local manifest_file="$PAYLOAD_DIR/MANIFEST.txt"
  local source_repo="${SOURCE_REPO:-unknown}"
  local source_sha="${SOURCE_SHA:-unknown}"
  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  log "Generating MANIFEST.txt in $PAYLOAD_DIR"

  {
    echo "# Module: $MODULE_NAME"
    echo "# Source: $source_repo @ $source_sha"
    echo "# Timestamp: $timestamp"
    echo "#"

    # Hash every file except MANIFEST.txt itself, paths relative to PAYLOAD_DIR
    (cd "$PAYLOAD_DIR" && find . -type f -not -name 'MANIFEST.txt' -print0 \
      | sort -z \
      | xargs -0 sha256sum \
      | sed 's|  \./|  |')
  } > "$manifest_file"

  local entry_count
  entry_count=$(grep -c -v '^#' "$manifest_file" | tr -d '[:space:]')
  log "MANIFEST.txt written: $entry_count file entries"
}

# ---------------------------------------------------------------------------
# Command: summary
# ---------------------------------------------------------------------------
# Prints a release-readiness summary for a built and validated payload.
#
# Required env vars:
#   PAYLOAD_DIR         — directory containing the payload
#   MODULE_NAME         — module name
#   VALIDATION_STATUS   — "passed" or "failed" (default: "unknown")
# ---------------------------------------------------------------------------
cmd_summary() {
  : "${PAYLOAD_DIR:?PAYLOAD_DIR is required}"
  : "${MODULE_NAME:?MODULE_NAME is required}"

  local validation_status="${VALIDATION_STATUS:-unknown}"
  local file_count total_size

  file_count=$(find "$PAYLOAD_DIR" -type f | wc -l | tr -d '[:space:]')
  total_size=$(du -sh "$PAYLOAD_DIR" | cut -f1)
  local abs_path
  abs_path="$(cd "$PAYLOAD_DIR" && pwd)"

  echo ""
  echo "=============================="
  echo " Release Package Summary"
  echo "=============================="
  echo " Module:      $MODULE_NAME"
  echo " Files:       $file_count"
  echo " Total size:  $total_size"
  echo " Validation:  $validation_status"
  echo " Path:        $abs_path"
  echo "=============================="
  echo ""
}

# ---------------------------------------------------------------------------
# Command: build-release
# ---------------------------------------------------------------------------
# End-to-end release package assembly: build → validate → manifest → summary.
# Cleans up the release directory on failure.
#
# Required env vars:
#   MODULE_NAME       — module name (used to read manifest and name release dir)
#   MANIFEST_FILE     — path to terraform-modules.json (default: .github/terraform-modules.json)
# Optional env vars:
#   RELEASE_BASE      — base directory for release output (default: release)
#   SOURCE_REPO       — source repository for audit metadata
#   SOURCE_SHA        — source commit SHA for audit metadata
#   SKIP_TFLINT       — set to "true" to skip tflint
#   SKIP_TF_TEST      — set to "true" to skip terraform test
# ---------------------------------------------------------------------------
cmd_build_release() {
  : "${MODULE_NAME:?MODULE_NAME is required}"

  local manifest_file="${MANIFEST_FILE:-.github/terraform-modules.json}"
  local release_base="${RELEASE_BASE:-release}"

  [[ -f "$manifest_file" ]] || die "Manifest not found: $manifest_file"

  # Read module config from manifest
  local module_json
  module_json=$(jq -c --arg name "$MODULE_NAME" \
    '.modules[] | select(.name == $name)' "$manifest_file")

  [[ -n "$module_json" ]] || die "Module '$MODULE_NAME' not found in $manifest_file"

  # Extract fields
  local source_path
  source_path=$(echo "$module_json" | jq -r '.source_path')
  export SOURCE_PATH="$source_path"
  # Use absolute path so cd inside cmd_validate doesn't break cleanup
  export PAYLOAD_DIR
  PAYLOAD_DIR="$(pwd)/$release_base/$MODULE_NAME"
  export FLATTEN_DIRS=$(echo "$module_json" | jq -c '.flatten_dirs')
  export COPY_DIRS=$(echo "$module_json" | jq -c '.copy_dirs')
  export COPY_FILES=$(echo "$module_json" | jq -c '.copy_files')
  export STRIP_PATTERNS=$(echo "$module_json" | jq -c '.strip_patterns')
  export MIN_EXPECTED_FILES=$(echo "$module_json" | jq -r '.min_expected_files // 0')

  # Idempotent: wipe existing release dir
  if [[ -d "$PAYLOAD_DIR" ]]; then
    log "Cleaning existing release directory: $PAYLOAD_DIR"
    rm -rf "$PAYLOAD_DIR"
  fi

  # Run steps with cleanup on any failure
  local cleanup_needed="true"

  # Step 1-6: Build payload (flatten, copy, strip)
  log "=== Step 1-6: Building payload ==="
  if ! cmd_build_payload; then
    err "Build failed — cleaning up partial release directory"
    rm -rf "$PAYLOAD_DIR"
    exit 1
  fi

  # Step 7: Validate
  log "=== Step 7: Validating payload ==="
  if ! cmd_validate; then
    err "Validation failed — cleaning up partial release directory"
    rm -rf "$PAYLOAD_DIR"
    exit 1
  fi

  # Step 8: Generate MANIFEST.txt
  log "=== Step 8: Generating MANIFEST.txt ==="
  if ! cmd_generate_manifest; then
    err "Manifest generation failed — cleaning up partial release directory"
    rm -rf "$PAYLOAD_DIR"
    exit 1
  fi

  # Step 9: Summary
  export VALIDATION_STATUS="passed"
  cmd_summary

  log "Release package ready: $PAYLOAD_DIR"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    build-payload)      cmd_build_payload "$@" ;;
    validate)           cmd_validate "$@" ;;
    publish)            cmd_publish "$@" ;;
    generate-manifest)  cmd_generate_manifest "$@" ;;
    summary)            cmd_summary "$@" ;;
    build-release)      cmd_build_release "$@" ;;
    *)
      die "Unknown command: '$cmd'. Use: build-payload | validate | publish | generate-manifest | summary | build-release"
      ;;
  esac
}

main "$@"
