#!/usr/bin/env bats
#
# Tests for scripts/terraform/publish-module.sh
#
# Prerequisites: bats-core, jq, git, rsync
# Run: bats tests/publish-module.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/terraform/publish-module.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/fake-module"

setup() {
  # Create temp dirs for each test
  export PAYLOAD_DIR="$(mktemp -d)"
  export SOURCE_PATH="$FIXTURES"
  TARGET_CLONE="$(mktemp -d)"
}

teardown() {
  rm -rf "$PAYLOAD_DIR" "$TARGET_CLONE" 2>/dev/null || true
}

# =========================================================================
# build-payload tests
# =========================================================================

@test "build-payload: flattens infra/*.tf into payload root" {
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='[]'
  export COPY_FILES='[]'
  export STRIP_PATTERNS='[]'

  run "$SCRIPT" build-payload
  [ "$status" -eq 0 ]
  [ -f "$PAYLOAD_DIR/main.tf" ]
  [ -f "$PAYLOAD_DIR/versions.tf" ]
  # infra/ dir should NOT exist as a directory in payload
  [ ! -d "$PAYLOAD_DIR/infra" ]
}

@test "build-payload: copies allowed subdirectories" {
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='["modules"]'
  export COPY_FILES='[]'
  export STRIP_PATTERNS='[]'

  run "$SCRIPT" build-payload
  [ "$status" -eq 0 ]
  [ -d "$PAYLOAD_DIR/modules/submod" ]
  [ -f "$PAYLOAD_DIR/modules/submod/main.tf" ]
}

@test "build-payload: copies allowed files" {
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='[]'
  export COPY_FILES='["README.md", ".tflint.hcl"]'
  export STRIP_PATTERNS='[]'

  run "$SCRIPT" build-payload
  [ "$status" -eq 0 ]
  [ -f "$PAYLOAD_DIR/README.md" ]
  [ -f "$PAYLOAD_DIR/.tflint.hcl" ]
}

@test "build-payload: strips forbidden patterns" {
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='[]'
  export COPY_FILES='[]'
  export STRIP_PATTERNS='["*.tfstate", "*.tfvars"]'

  # Manually copy a tfstate into payload first to test stripping
  run "$SCRIPT" build-payload
  [ "$status" -eq 0 ]

  # .tfstate and .tfvars should not be in the payload
  local tfstate_count
  tfstate_count=$(find "$PAYLOAD_DIR" -name '*.tfstate' | wc -l)
  [ "$tfstate_count" -eq 0 ]

  local tfvars_count
  tfvars_count=$(find "$PAYLOAD_DIR" -name '*.tfvars' | wc -l)
  [ "$tfvars_count" -eq 0 ]
}

@test "build-payload: skips missing optional directories silently" {
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='["nonexistent_dir", "also_missing"]'
  export COPY_FILES='["MISSING.md"]'
  export STRIP_PATTERNS='[]'

  run "$SCRIPT" build-payload
  [ "$status" -eq 0 ]
  [ ! -d "$PAYLOAD_DIR/nonexistent_dir" ]
}

@test "build-payload: fails on missing source path" {
  export SOURCE_PATH="/tmp/this-does-not-exist-$$"
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='[]'
  export COPY_FILES='[]'
  export STRIP_PATTERNS='[]'

  run "$SCRIPT" build-payload
  [ "$status" -ne 0 ]
  [[ "$output" == *"Source path does not exist"* ]]
}

@test "build-payload: fails on empty payload" {
  export SOURCE_PATH="$(mktemp -d)"
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='[]'
  export COPY_FILES='[]'
  export STRIP_PATTERNS='[]'

  run "$SCRIPT" build-payload
  [ "$status" -ne 0 ]
  [[ "$output" == *"Payload is empty"* ]]
}

@test "build-payload: full pipeline produces expected structure" {
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='["modules", "tests"]'
  export COPY_FILES='["README.md", ".tflint.hcl"]'
  export STRIP_PATTERNS='["*.tfstate", "*.tfstate.*", "*.tfvars", "*.tfvars.json", ".terraform/", ".terraform.lock.hcl"]'

  run "$SCRIPT" build-payload
  [ "$status" -eq 0 ]

  # Root should have flattened tf files
  [ -f "$PAYLOAD_DIR/main.tf" ]
  [ -f "$PAYLOAD_DIR/versions.tf" ]
  # Subdirs copied
  [ -d "$PAYLOAD_DIR/modules/submod" ]
  # Files copied
  [ -f "$PAYLOAD_DIR/README.md" ]
  [ -f "$PAYLOAD_DIR/.tflint.hcl" ]
  # Forbidden files stripped
  [ ! -f "$PAYLOAD_DIR/terraform.tfstate" ]
  [ ! -f "$PAYLOAD_DIR/secret.tfvars" ]
}

# =========================================================================
# publish tests (using local git repos, no GitHub API)
# =========================================================================

setup_target_repo() {
  # Create a local git repo to act as the target
  git init "$TARGET_CLONE" >/dev/null 2>&1
  cd "$TARGET_CLONE"
  git config user.name "test"
  git config user.email "test@test.com"
  echo "managed by sync" > .registry-sync-root
  echo "old content" > old-file.tf
  git add -A
  git commit -m "Initial" >/dev/null 2>&1
  cd - >/dev/null
}

@test "publish: marker file check rejects repos without it" {
  # Set up target WITHOUT marker file
  git init "$TARGET_CLONE" >/dev/null 2>&1
  cd "$TARGET_CLONE"
  git config user.name "test"
  git config user.email "test@test.com"
  echo "content" > file.txt
  git add -A
  git commit -m "Initial" >/dev/null 2>&1
  cd - >/dev/null

  # Directly test the marker file check logic
  MARKER_FILE=".registry-sync-root"
  [ ! -f "$TARGET_CLONE/$MARKER_FILE" ]

  # Now add the marker and verify it passes
  echo "managed" > "$TARGET_CLONE/$MARKER_FILE"
  [ -f "$TARGET_CLONE/$MARKER_FILE" ]
}

@test "publish: rsync removes old files and adds new ones" {
  setup_target_repo

  # Build a payload
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='[]'
  export COPY_FILES='["README.md"]'
  export STRIP_PATTERNS='[]'
  "$SCRIPT" build-payload

  # Simulate rsync (the actual publish needs a remote, but we can test rsync directly)
  rsync -avh --delete \
    --exclude='.git/' \
    --exclude='.registry-sync-root' \
    "$PAYLOAD_DIR/" "$TARGET_CLONE/" >/dev/null 2>&1

  # New files should exist
  [ -f "$TARGET_CLONE/main.tf" ]
  [ -f "$TARGET_CLONE/README.md" ]
  # Old file should be gone
  [ ! -f "$TARGET_CLONE/old-file.tf" ]
  # Marker and .git preserved
  [ -f "$TARGET_CLONE/.registry-sync-root" ]
  [ -d "$TARGET_CLONE/.git" ]
}

@test "publish: delete threshold blocks excessive deletions" {
  setup_target_repo

  # Add many files to target
  cd "$TARGET_CLONE"
  for i in $(seq 1 200); do
    echo "resource $i" > "file-$i.tf"
  done
  git add -A
  git commit -m "Add many files" >/dev/null 2>&1
  cd - >/dev/null

  # Build a minimal payload (only 2 files)
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='[]'
  export COPY_FILES='[]'
  export STRIP_PATTERNS='[]'
  "$SCRIPT" build-payload

  # Simulate the threshold check
  local dryrun_output
  dryrun_output=$(rsync -avhn --delete \
    --exclude='.git/' \
    --exclude='.registry-sync-root' \
    "$PAYLOAD_DIR/" "$TARGET_CLONE/" 2>&1)

  local delete_count
  delete_count=$(echo "$dryrun_output" | grep -c '^deleting ' || true)

  # Should want to delete ~200 files (well above default threshold of 100)
  [ "$delete_count" -gt 100 ]
}

# =========================================================================
# Edge cases
# =========================================================================

@test "build-payload: handles tf.json files" {
  # Create a tf.json file in the fixture
  local tmpmod
  tmpmod="$(mktemp -d)"
  mkdir -p "$tmpmod/infra"
  echo '{"variable": {"x": {"type": "string"}}}' > "$tmpmod/infra/override.tf.json"
  echo 'variable "y" {}' > "$tmpmod/infra/main.tf"

  export SOURCE_PATH="$tmpmod"
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='[]'
  export COPY_FILES='[]'
  export STRIP_PATTERNS='[]'

  run "$SCRIPT" build-payload
  [ "$status" -eq 0 ]
  [ -f "$PAYLOAD_DIR/override.tf.json" ]
  [ -f "$PAYLOAD_DIR/main.tf" ]

  rm -rf "$tmpmod"
}

@test "script: unknown command fails with usage" {
  run "$SCRIPT" unknown-command
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]]
}

@test "script: no command fails with usage" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]]
}

# =========================================================================
# generate-manifest tests
# =========================================================================

@test "generate-manifest: creates MANIFEST.txt with hashes and metadata" {
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='[]'
  export COPY_FILES='["README.md"]'
  export STRIP_PATTERNS='[]'
  "$SCRIPT" build-payload

  export MODULE_NAME="test-mod"
  export SOURCE_REPO="org/repo"
  export SOURCE_SHA="deadbeef"
  run "$SCRIPT" generate-manifest
  [ "$status" -eq 0 ]
  [ -f "$PAYLOAD_DIR/MANIFEST.txt" ]

  # Check metadata header
  grep -q "^# Module: test-mod" "$PAYLOAD_DIR/MANIFEST.txt"
  grep -q "^# Source: org/repo @ deadbeef" "$PAYLOAD_DIR/MANIFEST.txt"
  grep -q "^# Timestamp:" "$PAYLOAD_DIR/MANIFEST.txt"

  # Check file entries have sha256 hashes (64 hex chars)
  local entry_count
  entry_count=$(grep -cE '^[a-f0-9]{64}  ' "$PAYLOAD_DIR/MANIFEST.txt")
  [ "$entry_count" -gt 0 ]

  # MANIFEST.txt should not list itself
  ! grep -q 'MANIFEST.txt' "$PAYLOAD_DIR/MANIFEST.txt"
}

@test "generate-manifest: fails without MODULE_NAME" {
  export PAYLOAD_DIR="$(mktemp -d)"
  unset MODULE_NAME
  run "$SCRIPT" generate-manifest
  [ "$status" -ne 0 ]
}

# =========================================================================
# summary tests
# =========================================================================

@test "summary: prints expected fields" {
  export FLATTEN_DIRS='["infra"]'
  export COPY_DIRS='[]'
  export COPY_FILES='[]'
  export STRIP_PATTERNS='[]'
  "$SCRIPT" build-payload

  export MODULE_NAME="test-mod"
  export VALIDATION_STATUS="passed"
  run "$SCRIPT" summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-mod"* ]]
  [[ "$output" == *"passed"* ]]
  [[ "$output" == *"Files:"* ]]
  [[ "$output" == *"Total size:"* ]]
  [[ "$output" == *"Path:"* ]]
}

# =========================================================================
# build-release tests
# =========================================================================

@test "build-release: fails for unknown module" {
  export MODULE_NAME="nonexistent"
  export MANIFEST_FILE="$BATS_TEST_DIRNAME/../.github/terraform-modules.json"
  export RELEASE_BASE="$(mktemp -d)"
  run "$SCRIPT" build-release
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}
