#!/usr/bin/env bash
#
# no-ai-coauthor-trailer.sh — Reject Co-authored-by: trailers that credit an AI
# coding agent.
#
# Team policy is no AI co-author trailers at all. Human Co-authored-by: trailers
# are fine and common, so this matches only the agent identities listed in
# ai-identities.patterns — add a line there to cover a new agent.
#
# Two passes find the candidate trailers, because either one alone has a hole:
#
#   1. `git interpret-trailers --parse`, which is authoritative for real
#      trailers and correctly unfolds wrapped ones.
#   2. Every *unindented* line matching ^Co-authored-by:, anywhere in the
#      message.
#
# Pass 2 exists because --parse only treats the last paragraph as a trailer
# block when at least 25% of its lines look like trailers. Four prose lines
# followed by `Co-Authored-By: Claude <...>` in the same paragraph is 20%, so
# --parse reports nothing and pass 1 alone would let it through. The old push
# ruleset's regex caught that, and so must this.
#
# The unindented requirement is what keeps pass 2 from flagging a commit that
# *documents* the rule: a real trailer is never indented, while a quoted example
# in a commit message is either inline in a sentence or in an indented block.
#
# Usage: no-ai-coauthor-trailer.sh <check <message-file> [<identity-file>] | describe | remediation>
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib-ai-identities.sh
. "${SCRIPT_DIR}/lib-ai-identities.sh"

describe() {
  echo "Commits must not credit an AI agent with a Co-authored-by: trailer"
}

remediation() {
  cat <<'EOF'
Drop the AI Co-authored-by: trailer from the offending commit message(s).

  # most recent commit
  git commit --amend

  # anything older — mark the commits "reword"
  git rebase -i <base>

Stop the trailer coming back:
  - Claude Code:  remove the Co-Authored-By line from the attribution rules in
                  your CLAUDE.md / settings, or tell the session not to add it.
  - Cursor:       Settings -> disable the "Co-authored-by" commit trailer.
  - Sculptor:     disable commit co-authorship in its settings.

Human Co-authored-by: trailers are fine — only AI agents are rejected.
EOF
}

# Strips the "Co-authored-by:" key, leaving the "Name <email>" value that the
# patterns are anchored against.
strip_key() {
  sed -E 's/^[[:space:]]*[Cc][Oo]-[Aa][Uu][Tt][Hh][Oo][Rr][Ee][Dd]-[Bb][Yy]:[[:space:]]*//'
}

check() {
  local msg_file="$1"
  [ -f "$msg_file" ] || { echo "message file not found: ${msg_file}" >&2; exit 2; }

  local parsed unindented values
  parsed="$(git interpret-trailers --parse < "$msg_file" 2>/dev/null \
    | grep -iE '^co-authored-by:[[:space:]]*' | strip_key || true)"
  unindented="$(grep -iE '^co-authored-by:[[:space:]]*' "$msg_file" | strip_key || true)"

  # Dedupe: a real trailer block shows up in both passes.
  values="$(printf '%s\n%s\n' "$parsed" "$unindented" | grep -v '^$' | sort -u || true)"
  [ -n "$values" ] || return 0

  local found=0 value
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    if ai_identity_match "$value"; then
      echo "forbidden AI co-author trailer: Co-authored-by: ${value}"
      found=1
    fi
  done <<VALUES
$values
VALUES

  [ "$found" -eq 0 ] || return 1
  return 0
}

case "${1:-}" in
  check) shift; check "${1:-}" ;;
  describe) describe ;;
  remediation) remediation ;;
  *) echo "Usage: $0 <check <message-file> [<identity-file>] | describe | remediation>" >&2; exit 2 ;;
esac
