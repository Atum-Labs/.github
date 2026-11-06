#!/usr/bin/env bash
#
# lib-ai-identities.sh — Shared by the two rules that match a "Name <email>"
# string against the AI agent list in ai-identities.patterns.
#
# Not a rule itself. The driver only globs rules/*.sh for files it can run as
# rules, so this is named lib-* and the driver skips the prefix.
#
# Sourced, not executed. Provides:
#   ai_identity_patterns          — echoes the pattern list, comments stripped
#   ai_identity_match <string>    — 0 if <string> matches any pattern, else 1
#
# shellcheck shell=bash

_AI_IDENTITIES_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AI_IDENTITIES_FILE="${COMMIT_POLICY_AI_IDENTITIES:-${_AI_IDENTITIES_LIB_DIR}/ai-identities.patterns}"

ai_identity_patterns() {
  [ -f "$AI_IDENTITIES_FILE" ] || {
    echo "patterns file not found: ${AI_IDENTITIES_FILE}" >&2
    exit 2
  }
  sed -E 's/[[:space:]]+$//; /^[[:space:]]*(#|$)/d' "$AI_IDENTITIES_FILE"
}

# ai_identity_match <string>
ai_identity_match() {
  local value="$1" pattern
  while IFS= read -r pattern; do
    if printf '%s\n' "$value" | grep -qiE "$pattern"; then
      return 0
    fi
  done <<PATTERNS
$(ai_identity_patterns)
PATTERNS
  return 1
}
