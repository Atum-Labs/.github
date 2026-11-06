#!/usr/bin/env bash
#
# no-ai-commit-identity.sh — Reject commits authored or committed by an AI
# coding agent's own git identity.
#
# Why this is in a *commit message* check: a commit authored as
# `Cursor Agent <cursoragent@cursor.com>` carries no trailer, so the trailer rule
# passes it — and then the squash merge puts the trailer on the base branch
# anyway. GitHub synthesises a Co-authored-by: trailer for every distinct author
# among the squashed commits, and atum-core squashes with
# squash_merge_commit_message=COMMIT_MESSAGES. So an agent identity on a branch
# commit becomes an AI co-author trailer on main, which is the exact thing whose
# presence in history forced this check to exist (CORE-2704).
#
# Checking the message alone would leave that path open.
#
# Uses the same agent list as the trailer rule: ai-identities.patterns.
#
# Usage: no-ai-commit-identity.sh <check <message-file> [<identity-file>] | describe | remediation>
#
# The identity file is written by the driver and holds:
#   author: Name <email>
#   committer: Name <email>
#
# It is optional. Without it there is no identity to judge and the rule passes —
# see the note in remediation about what the local hook can and cannot see.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib-ai-identities.sh
. "${SCRIPT_DIR}/lib-ai-identities.sh"

describe() {
  echo "Commits must not be authored or committed by an AI agent's git identity"
}

remediation() {
  cat <<'EOF'
Re-author the offending commit(s) under a human identity.

  # most recent commit
  git commit --amend --reset-author

  # anything older
  git rebase -i <base> --exec 'git commit --amend --no-edit --reset-author'

Then fix the source so it stops happening:

  git config user.name  "Your Name"
  git config user.email "you@atumlabs.xyz"

Check the repo-local config as well as the global one — an agent that commits
under its own identity usually sets it per repo. In Cursor, the background agent
has its own git identity setting.

Why this is rejected even with no trailer in the message: a squash merge turns a
non-primary commit author into a Co-authored-by: trailer on the base branch, so
an agent identity here becomes an AI co-author trailer on main.
EOF
}

check() {
  local msg_file="$1" ident_file="${2:-}"
  [ -f "$msg_file" ] || { echo "message file not found: ${msg_file}" >&2; exit 2; }

  # No identity supplied — nothing for this rule to judge.
  [ -n "$ident_file" ] && [ -f "$ident_file" ] || return 0

  local found=0 role value line
  while IFS= read -r line; do
    case "$line" in
      author:*|committer:*) ;;
      *) continue ;;
    esac
    role="${line%%:*}"
    value="${line#*: }"
    [ -n "$value" ] || continue
    if ai_identity_match "$value"; then
      echo "commit ${role} is an AI agent identity: ${value}"
      found=1
    fi
  done < "$ident_file"

  [ "$found" -eq 0 ] || return 1
  return 0
}

case "${1:-}" in
  check) shift; check "${1:-}" "${2:-}" ;;
  describe) describe ;;
  remediation) remediation ;;
  *) echo "Usage: $0 <check <message-file> [<identity-file>] | describe | remediation>" >&2; exit 2 ;;
esac
