#!/usr/bin/env bash
#
# verify-pr-signatures.sh — Verify that all commits in a GitHub PR are signed
# with approved SSH keys.
#
# Usage:
#   verify-pr-signatures.sh <owner/repo> <pr-number> <approved-signing-keys-file>
#
# Requires: gh (GitHub CLI), ssh-keygen, jq
# Expects: GH_TOKEN or gh auth to be configured
#
# Checks (in order):
#   1. Commit is signed and verified by GitHub
#   2. Signature is SSH format (not GPG)
#   3. Signing key is in the approved-signing-keys registry
#   4. [Optional] Signing key is sk (security key) type
#
# Exit codes:
#   0 — all commits pass
#   1 — one or more commits failed
#   2 — usage error
#
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "Usage: $0 <owner/repo> <pr-number> <approved-signing-keys-file>" >&2
  exit 2
fi

REPO="$1"
PR_NUMBER="$2"
APPROVED_KEYS_FILE="$3"

if [ ! -f "$APPROVED_KEYS_FILE" ]; then
  echo "Error: approved signing keys file not found: ${APPROVED_KEYS_FILE}" >&2
  exit 2
fi

# Whether to require hardware security key (sk) type.
# Set REQUIRE_SK_KEY_TYPE=true to enforce.
REQUIRE_SK_KEY_TYPE="${REQUIRE_SK_KEY_TYPE:-false}"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

failed=0
checked=0

echo "Checking commits in ${REPO} PR #${PR_NUMBER}..."
echo "Approved keys: ${APPROVED_KEYS_FILE}"
echo ""

while IFS= read -r encoded; do

  sha=$(echo "$encoded" | base64 -d | jq -r '.sha')
  author=$(echo "$encoded" | base64 -d | jq -r '.author.login // "unknown"')
  committer=$(echo "$encoded" | base64 -d | jq -r '.committer.login // "unknown"')
  message=$(echo "$encoded" | base64 -d | jq -r '.commit.message' | head -1)
  short_sha="${sha:0:8}"

  checked=$((checked + 1))

  echo "--- ${short_sha}: ${message}"

  # Skip GitHub-generated merge commits
  if [ "$committer" = "web-flow" ]; then
    echo "  SKIP (GitHub merge commit)"
    echo ""
    continue
  fi

  # Skip bot commits
  if [[ "$author" == *"[bot]"* ]] || [[ "$committer" == *"[bot]"* ]]; then
    echo "  SKIP (bot: ${author})"
    echo ""
    continue
  fi

  # Fetch verification details
  verification=$(gh api "repos/${REPO}/commits/${sha}" \
    --jq '.commit.verification | {verified, reason, signature}')

  verified=$(echo "$verification" | jq -r '.verified')
  reason=$(echo "$verification" | jq -r '.reason')
  signature=$(echo "$verification" | jq -r '.signature // empty')

  # CHECK 1: Signed and verified
  if [ "$verified" != "true" ]; then
    echo "  FAIL: not verified (${reason})"
    echo "::error title=Unsigned commit::${short_sha} by ${author}: ${reason}"
    failed=$((failed + 1))
    echo ""
    continue
  fi

  # CHECK 2: SSH signature format
  if [ -z "$signature" ] || ! echo "$signature" | grep -q "BEGIN SSH SIGNATURE"; then
    echo "  FAIL: not SSH-signed (GPG or unknown format)"
    echo "::error title=Non-SSH signature::${short_sha} by ${author}: policy requires gpg.format=ssh"
    failed=$((failed + 1))
    echo ""
    continue
  fi

  # CHECK 3: Key is in the approved registry
  echo "$signature" > "${tmpdir}/sig"
  principal=$(ssh-keygen -Y find-principals -s "${tmpdir}/sig" -f "$APPROVED_KEYS_FILE" 2>/dev/null || true)

  if [ -z "$principal" ]; then
    echo "  FAIL: signing key not in approved registry"
    echo "::error title=Unapproved key::${short_sha} by ${author}: signing key is not in the approved-signing-keys registry"
    failed=$((failed + 1))
    echo ""
    continue
  fi

  # CHECK 4: sk (security key) type [optional]
  if [ "$REQUIRE_SK_KEY_TYPE" = "true" ]; then
    # Look up the matched principal's key type in the registry
    key_type=$(grep "^${principal} " "$APPROVED_KEYS_FILE" | awk '{print $2}')
    case "$key_type" in
      sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
        ;;
      *)
        echo "  FAIL: key for ${principal} is not a security key type (${key_type})"
        echo "::error title=Non-SK key::${short_sha} by ${author}: key type ${key_type} is not a hardware security key"
        failed=$((failed + 1))
        echo ""
        continue
        ;;
    esac
  fi

  echo "  OK (${principal})"
  echo ""
done < <(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/commits" --jq '.[] | @base64')

if [ "$checked" -eq 0 ]; then
  echo ""
  echo "FAILED: no commits were found — check GITHUB_TOKEN permissions (needs pull-requests: read)."
  exit 1
fi

if [ "$failed" -gt 0 ]; then
  echo ""
  echo "FAILED: ${failed} commit(s) failed signature policy."
  echo ""
  echo "Requirements:"
  echo "  1. Commits must be signed:       git config --global commit.gpgsign true"
  echo "  2. Signing must use SSH:          git config --global gpg.format ssh"
  echo "  3. Signing key must be approved:  see your org's YubiKey SSH setup guide"
  exit 1
fi

echo "All commits passed signature verification."
