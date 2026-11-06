#!/usr/bin/env bash
#
# audit-org-ssh-keys.sh — Audit all SSH keys registered by org members on GitHub.
#
# Reports:
#   - Members with non-sk SSH authentication keys
#   - Members with non-sk SSH signing keys
#   - Members with no SSH keys at all
#
# Usage:
#   audit-org-ssh-keys.sh <org-name>
#
# Requires: gh (GitHub CLI), jq
# Expects: GH_TOKEN with admin:org and read:user scopes
#
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <org-name>" >&2
  exit 2
fi

ORG="$1"

echo "Auditing SSH keys for org: ${ORG}"
echo ""

non_sk_auth=0
non_sk_sign=0
no_keys=0
compliant=0

for user in $(gh api --paginate "/orgs/${ORG}/members" --jq '.[].login'); do
  auth_keys=$(gh api "/users/${user}/keys" --jq '.[] | "\(.id) \(.key | split(" ")[0])"' 2>/dev/null || true)
  sign_keys=$(gh api "/users/${user}/ssh_signing_keys" --jq '.[] | "\(.id) \(.key | split(" ")[0])"' 2>/dev/null || true)

  has_issue=false

  # Check authentication keys
  if [ -n "$auth_keys" ]; then
    while IFS= read -r key_info; do
      key_type=$(echo "$key_info" | awk '{print $2}')
      key_id=$(echo "$key_info" | awk '{print $1}')
      case "$key_type" in
        sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
          ;;
        *)
          echo "WARN: ${user} has non-sk authentication key (id=${key_id}, type=${key_type})"
          echo "::warning::${user} has non-sk SSH authentication key: ${key_type}"
          non_sk_auth=$((non_sk_auth + 1))
          has_issue=true
          ;;
      esac
    done <<< "$auth_keys"
  fi

  # Check signing keys
  if [ -n "$sign_keys" ]; then
    while IFS= read -r key_info; do
      key_type=$(echo "$key_info" | awk '{print $2}')
      key_id=$(echo "$key_info" | awk '{print $1}')
      case "$key_type" in
        sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
          ;;
        *)
          echo "WARN: ${user} has non-sk signing key (id=${key_id}, type=${key_type})"
          echo "::warning::${user} has non-sk SSH signing key: ${key_type}"
          non_sk_sign=$((non_sk_sign + 1))
          has_issue=true
          ;;
      esac
    done <<< "$sign_keys"
  fi

  # Check for no keys at all
  if [ -z "$auth_keys" ] && [ -z "$sign_keys" ]; then
    echo "INFO: ${user} has no SSH keys registered"
    no_keys=$((no_keys + 1))
    has_issue=true
  fi

  if [ "$has_issue" = false ]; then
    compliant=$((compliant + 1))
  fi
done

echo ""
echo "=== Audit Summary ==="
echo "  Compliant:              ${compliant}"
echo "  Non-sk auth keys:       ${non_sk_auth}"
echo "  Non-sk signing keys:    ${non_sk_sign}"
echo "  Members with no keys:   ${no_keys}"

if [ "$non_sk_auth" -gt 0 ] || [ "$non_sk_sign" -gt 0 ]; then
  echo ""
  echo "ACTION REQUIRED: Some members have non-security-key SSH keys."
  exit 1
fi
