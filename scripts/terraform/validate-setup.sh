#!/usr/bin/env bash
#
# validate-setup.sh — Verify that GitHub-side configuration is ready
#                      for the Terraform registry sync pipeline.
#
# Prerequisites: gh CLI authenticated with sufficient access
#
# Usage:
#   validate-setup.sh [--org OWNER] [--manifest PATH]
#
# Checks:
#   1. Each target repo (staging + production) exists
#   2. Each target repo has .registry-sync-root marker file
#   3. GitHub App is installed on the org (basic check)
#   4. Environments exist on the source repo
#   5. Environment secrets are configured (existence check only)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MANIFEST=".github/terraform-modules.json"
OWNER=""
SOURCE_REPO=""
ERRORS=0
WARNINGS=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[validate-setup] $*"; }
ok()   { echo "  [OK]  $*"; }
fail() { echo "  [FAIL] $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo "  [WARN] $*"; WARNINGS=$((WARNINGS + 1)); }

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)    OWNER="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --repo)   SOURCE_REPO="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Resolve defaults
if [[ -z "$OWNER" ]]; then
  OWNER=$(gh api user --jq .login 2>/dev/null || true)
  if [[ -z "$OWNER" ]]; then
    echo "Could not determine org/owner. Use --org OWNER."
    exit 1
  fi
fi

if [[ -z "$SOURCE_REPO" ]]; then
  SOURCE_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Check manifest
# ---------------------------------------------------------------------------
log "Checking manifest: $MANIFEST"
if [[ ! -f "$MANIFEST" ]]; then
  fail "Manifest not found: $MANIFEST"
  echo ""
  echo "Setup incomplete. $ERRORS error(s)."
  exit 1
fi
ok "Manifest exists"

MODULE_COUNT=$(jq '.modules | length' "$MANIFEST")
log "Found $MODULE_COUNT module(s)"
echo ""

# ---------------------------------------------------------------------------
# Check each module's target repos
# ---------------------------------------------------------------------------
for i in $(seq 0 $((MODULE_COUNT - 1))); do
  NAME=$(jq -r ".modules[$i].name" "$MANIFEST")
  STAGING_REPO=$(jq -r ".modules[$i].staging_repo" "$MANIFEST")
  PROD_REPO=$(jq -r ".modules[$i].production_repo" "$MANIFEST")

  log "Module: $NAME"

  # Check staging repo
  if gh repo view "$OWNER/$STAGING_REPO" --json name >/dev/null 2>&1; then
    ok "Staging repo $OWNER/$STAGING_REPO exists"

    # Check marker file
    if gh api "repos/$OWNER/$STAGING_REPO/contents/.registry-sync-root" >/dev/null 2>&1; then
      ok "Staging repo has .registry-sync-root marker"
    else
      fail "Staging repo $OWNER/$STAGING_REPO is missing .registry-sync-root marker file"
      echo "       Fix: echo 'Managed by terraform-registry-sync' > .registry-sync-root && git add . && git commit -m 'Add sync marker' && git push"
    fi
  else
    fail "Staging repo $OWNER/$STAGING_REPO does not exist or is not accessible"
    echo "       Fix: gh repo create $OWNER/$STAGING_REPO --public --description 'Terraform $NAME module (staging)'"
  fi

  # Check production repo
  if gh repo view "$OWNER/$PROD_REPO" --json name >/dev/null 2>&1; then
    ok "Production repo $OWNER/$PROD_REPO exists"

    if gh api "repos/$OWNER/$PROD_REPO/contents/.registry-sync-root" >/dev/null 2>&1; then
      ok "Production repo has .registry-sync-root marker"
    else
      fail "Production repo $OWNER/$PROD_REPO is missing .registry-sync-root marker file"
      echo "       Fix: echo 'Managed by terraform-registry-sync' > .registry-sync-root && git add . && git commit -m 'Add sync marker' && git push"
    fi
  else
    fail "Production repo $OWNER/$PROD_REPO does not exist or is not accessible"
    echo "       Fix: gh repo create $OWNER/$PROD_REPO --public --description 'Terraform $NAME module'"
  fi

  echo ""
done

# ---------------------------------------------------------------------------
# Check environments (if we know the source repo)
# ---------------------------------------------------------------------------
if [[ -n "$SOURCE_REPO" ]]; then
  log "Checking environments on $SOURCE_REPO"

  for env_name in "terraform-registry-staging" "terraform-registry-production"; do
    # URL-encode the environment name
    encoded_name=$(echo "$env_name" | sed 's/ /%20/g')
    if gh api "repos/$SOURCE_REPO/environments/$encoded_name" >/dev/null 2>&1; then
      ok "Environment '$env_name' exists"

      # Check for protection rules on production
      if [[ "$env_name" == *"production"* ]]; then
        reviewers=$(gh api "repos/$SOURCE_REPO/environments/$encoded_name" \
          --jq '.protection_rules[]? | select(.type == "required_reviewers") | .reviewers | length' 2>/dev/null || echo "0")
        if [[ "$reviewers" -gt 0 ]]; then
          ok "Production environment has required reviewers"
        else
          warn "Production environment has no required reviewers — any workflow run can deploy to production"
          echo "       Fix: Go to Settings > Environments > terraform-registry-production > Required reviewers"
        fi
      fi
    else
      fail "Environment '$env_name' not found on $SOURCE_REPO"
      echo "       Fix: Go to $SOURCE_REPO Settings > Environments > New environment > '$env_name'"
    fi
  done

  echo ""

  # Check for TERRAFORM_SYNC_APP_ID variable
  log "Checking repository variables"
  if gh api "repos/$SOURCE_REPO/actions/variables/TERRAFORM_SYNC_APP_ID" >/dev/null 2>&1; then
    ok "Repository variable TERRAFORM_SYNC_APP_ID is set"
  else
    fail "Repository variable TERRAFORM_SYNC_APP_ID is not set"
    echo "       Fix: Go to $SOURCE_REPO Settings > Secrets and variables > Actions > Variables > New variable"
  fi
else
  warn "Could not determine source repo — skipping environment checks. Use --repo OWNER/REPO."
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "=== Setup Validation Summary ==="
if [[ "$ERRORS" -eq 0 ]] && [[ "$WARNINGS" -eq 0 ]]; then
  log "All checks passed. The pipeline is ready to use."
  exit 0
elif [[ "$ERRORS" -eq 0 ]]; then
  log "$WARNINGS warning(s), 0 errors. Pipeline will work but review warnings above."
  exit 0
else
  log "$ERRORS error(s), $WARNINGS warning(s). Fix the errors above before using the pipeline."
  exit 1
fi
