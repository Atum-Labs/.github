#!/usr/bin/env bash
#
# test.sh — Self-test for the commit-message adherence check.
#
# Runs the driver and rules against crafted messages and against a throwaway
# repository, including the scenario that made the old push ruleset unusable: a
# branch stacked on base-branch history that already contains a forbidden
# trailer. Takes no arguments, touches nothing outside its temp directory, and
# needs only git and bash.
#
# Usage: commit-policy/test.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check-commit-messages.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Keep a developer's own git config (hooks, trailer settings, signing) out of the
# fixtures, and make commits reproducible.
export GIT_CONFIG_GLOBAL="${tmpdir}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test Author"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test Author"
export GIT_COMMITTER_EMAIL="test@example.com"
: > "$GIT_CONFIG_GLOBAL"
unset GITHUB_ACTIONS || true

passed=0
failed=0

# expect_message <expected-exit: pass|fail> <name> <message>
expect_message() {
  local expect="$1" name="$2" message="$3"
  local msg_file="${tmpdir}/msg" out rc

  printf '%s' "$message" > "$msg_file"
  set +e
  out="$("$CHECK" --message-file "$msg_file" 2>&1)"
  rc=$?
  set -e

  local want=0
  [ "$expect" = "pass" ] || want=1

  if [ "$rc" -eq "$want" ]; then
    echo "ok   ${name}"
    passed=$((passed + 1))
  else
    echo "FAIL ${name} — expected exit ${want}, got ${rc}"
    printf '%s\n' "$out" | sed 's/^/       /'
    failed=$((failed + 1))
  fi
}

# expect_cmd <expected-exit: pass|fail|usage-error> <name> <command...>
expect_cmd() {
  local expect="$1" name="$2"
  shift 2
  local out rc want
  case "$expect" in
    pass) want=0 ;;
    fail) want=1 ;;
    usage-error) want=2 ;;
    *) echo "bad expectation: ${expect}" >&2; exit 2 ;;
  esac

  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -eq "$want" ]; then
    echo "ok   ${name}"
    passed=$((passed + 1))
  else
    echo "FAIL ${name} — expected exit ${want}, got ${rc}"
    printf '%s\n' "$out" | sed 's/^/       /'
    failed=$((failed + 1))
  fi
}

echo "== rules discovered"
"$CHECK" --list
echo ""

echo "== single messages"

expect_message pass "plain message" \
'feat: add a thing

Body text.
'

expect_message pass "human co-author is allowed" \
'docs: fix a typo

Co-authored-by: Peter Olds <2372558+polds@users.noreply.github.com>
'

expect_message fail "Claude trailer" \
'feat: add a thing

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
'

expect_message fail "Claude trailer, no email" \
'feat: add a thing

Co-authored-by: Claude
'

expect_message fail "Cursor trailer" \
'feat: add a thing

Co-authored-by: Cursor Agent <cursoragent@cursor.com>
'

expect_message fail "Sculptor trailer" \
'feat: add a thing

Co-authored-by: Sculptor <sculptor@imbue.com>
'

expect_message fail "Anthropic address under a different name" \
'feat: add a thing

Co-authored-by: Some Assistant <noreply@anthropic.com>
'

expect_message fail "mixed human and AI trailers" \
'feat: add a thing

Co-authored-by: Peter Olds <p@example.com>
Co-authored-by: Cursor <cursoragent@cursor.com>
'

# The trailer only counts where git counts it: in the trailer block. This is what
# lets a commit that documents the rule describe the forbidden trailer in prose.
expect_message pass "trailer named in the body, not the trailer block" \
'docs: document the trailer rule

The rule rejects a "Co-authored-by: Claude" trailer, and leaves human
co-author trailers alone.

Co-authored-by: Peter Olds <p@example.com>
'

# A name that merely contains an agent name must not trip the rule.
expect_message pass "human whose name starts similarly" \
'feat: add a thing

Co-authored-by: Claudette Dubois <claudette@example.com>
'

# git interpret-trailers --parse only treats the last paragraph as a trailer
# block when >=25% of its lines look like trailers. Below that threshold it
# reports nothing, so the unindented-line pass has to catch these.
expect_message fail "trailer buried under prose, below the 25% trailer threshold" \
'feat: something real

This is prose line one of the last paragraph.
This is prose line two and it keeps going.
This is prose line three still going.
This is prose line four almost done.
Co-Authored-By: Claude <noreply@anthropic.com>
'

expect_message fail "single prose line then a trailer, same paragraph" \
'feat: something real

Some explanation of the change.
Co-authored-by: Cursor <cursoragent@cursor.com>
'

# ...but an indented example is a quotation, not a trailer. A real trailer is
# never indented, so this is what lets a commit document the rule.
expect_message pass "indented example of a forbidden trailer" \
'docs: explain the rule

The rule rejects a trailer block like this one:

    Co-Authored-By: Claude <noreply@anthropic.com>

Human co-author trailers are untouched.
'

echo ""
echo "== repository ranges"

repo="${tmpdir}/repo"
git init -q -b main "$repo"
cd "$repo"

commit() {
  git commit -q --allow-empty --cleanup=verbatim -F - <<EOF
$1
EOF
}

# Base-branch history that already carries a forbidden trailer, exactly like the
# 9 such commits on atum-core's main. Nothing below may ever flag these.
commit 'chore: first commit'
commit 'feat: historical work

Co-Authored-By: Claude <noreply@anthropic.com>
'
commit 'feat: more historical work

Co-authored-by: Cursor <cursoragent@cursor.com>
'
git tag old-main
commit 'chore: main moves on'
git tag new-main

expect_cmd fail "base branch history is dirty (sanity check)" \
  "$CHECK" --range "$(git rev-list --max-parents=0 HEAD)..new-main"

# The headline case: a clean branch stacked on the *old* base history, then
# judged against the *current* base tip — the atum-core#1664/#1665/#1666
# scenario. The forbidden commits are ancestors of both sides, so they fall out
# of the range and the branch passes.
git checkout -q -b clean-stacked-on-old-main old-main
commit 'feat: my own clean commit'
commit 'fix: another clean commit'

expect_cmd pass "clean branch stacked on old base history, judged against new base tip" \
  "$CHECK" --base new-main --head clean-stacked-on-old-main

expect_cmd pass "same branch judged against the base commit it forked from" \
  "$CHECK" --base old-main --head clean-stacked-on-old-main

# Merging a newer base in must not drag the base's own bad commits into range.
git merge -q --no-ff -m 'Merge branch main into clean-stacked-on-old-main' new-main
expect_cmd pass "clean branch that merged a newer base in" \
  "$CHECK" --base new-main --head clean-stacked-on-old-main

# A branch that adds its own bad commit is still caught.
git checkout -q -b dirty-branch new-main
commit 'feat: my own work

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
'
expect_cmd fail "branch adding its own AI-trailer commit" \
  "$CHECK" --base new-main --head dirty-branch

expect_cmd fail "single revision mode" "$CHECK" --rev dirty-branch

# Nothing to add is not a failure.
git checkout -q -b no-op new-main
expect_cmd pass "branch with no commits of its own" \
  "$CHECK" --base new-main --head no-op

echo ""
echo "== commit identity"

# A commit authored by an agent identity carries no trailer, so the trailer rule
# passes it — but a squash merge turns a non-primary author into a
# Co-authored-by: trailer on the base branch. Catching the identity is what keeps
# that path from putting the trailer on main.
git checkout -q -b agent-authored new-main
# `env`, not a `VAR=v commit ...` prefix: for a shell *function* bash keeps such
# assignments in effect after the call, which would leak the agent identity into
# every later commit in this file.
env GIT_AUTHOR_NAME="Cursor Agent" GIT_AUTHOR_EMAIL="cursoragent@cursor.com" \
  git commit -q --allow-empty -m 'feat: work with no trailer at all'

expect_cmd fail "commit authored by an agent identity, message clean" \
  "$CHECK" --base new-main --head agent-authored
expect_cmd pass "...and the trailer rule alone would have passed it" \
  "$CHECK" --only no-ai-coauthor-trailer --base new-main --head agent-authored
expect_cmd fail "...while the identity rule alone catches it" \
  "$CHECK" --only no-ai-commit-identity --base new-main --head agent-authored

git checkout -q -b agent-committed new-main
env GIT_COMMITTER_NAME="Claude" GIT_COMMITTER_EMAIL="noreply@anthropic.com" \
  git commit -q --allow-empty -m 'feat: work committed by an agent'
expect_cmd fail "commit committed by an agent identity" \
  "$CHECK" --base new-main --head agent-committed

# web-flow and release bots must not look like agents.
git checkout -q -b bot-committed new-main
env GIT_COMMITTER_NAME="GitHub" GIT_COMMITTER_EMAIL="noreply@github.com" \
  git commit -q --allow-empty -m 'chore: squash commit as GitHub would make it'
expect_cmd pass "GitHub web-flow committer is not an agent" \
  "$CHECK" --base new-main --head bot-committed

echo ""
echo "== hook installation"

cd "$repo"
expect_cmd fail "--check before install reports missing" \
  "${SCRIPT_DIR}/install-hooks.sh" --check "$repo"
expect_cmd pass "install" "${SCRIPT_DIR}/install-hooks.sh" "$repo"
expect_cmd pass "--check after install reports up to date" \
  "${SCRIPT_DIR}/install-hooks.sh" --check "$repo"

git checkout -q -b hook-test new-main
expect_cmd pass "hook lets a clean commit through" \
  git commit -q --allow-empty -m 'chore: clean commit through the hook'
expect_cmd fail "hook blocks an AI-trailer commit" \
  git commit -q --allow-empty --cleanup=verbatim -m 'chore: blocked commit

Co-Authored-By: Claude <noreply@anthropic.com>
'
expect_cmd pass "--no-verify bypasses the hook" \
  git commit -q --allow-empty --no-verify --cleanup=verbatim -m 'chore: bypassed commit

Co-Authored-By: Claude <noreply@anthropic.com>
'

# The hook has no commit yet, so it judges the identity `git commit` is about to
# use. A repo-local user.email is how an agent usually sets itself up, and is the
# case worth catching before CI.
git config user.name "Cursor Agent"
git config user.email "cursoragent@cursor.com"
expect_cmd fail "hook blocks a commit made under an agent identity" \
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
  git commit -q --allow-empty -m 'chore: committed under an agent identity'
git config --unset user.name
git config --unset user.email

# git's own instructional comments and the commit.verbose diff are stripped
# before the rules see the message, exactly as `git commit` would strip them.
expect_message pass "git comment lines are ignored" \
'chore: a real subject

# Please enter the commit message for your changes.
# Co-Authored-By: Claude <noreply@anthropic.com>
'

expect_message pass "content below the scissors line is ignored" \
'chore: a real subject

# ------------------------ >8 ------------------------
Co-Authored-By: Claude <noreply@anthropic.com>
'

# An unrelated pre-existing hook must be preserved, not silently dropped.
hooks_dir="$(cd -- "$(git rev-parse --git-common-dir)" && pwd)/hooks"
expect_cmd pass "uninstall" "${SCRIPT_DIR}/install-hooks.sh" --uninstall "$repo"
printf '#!/bin/sh\nexit 0\n' > "${hooks_dir}/commit-msg"
chmod +x "${hooks_dir}/commit-msg"
expect_cmd pass "install over a foreign hook" "${SCRIPT_DIR}/install-hooks.sh" "$repo"
if [ -f "${hooks_dir}/commit-msg.commit-policy.bak" ]; then
  echo "ok   foreign hook was backed up"
  passed=$((passed + 1))
else
  echo "FAIL foreign hook was not backed up"
  failed=$((failed + 1))
fi

echo ""
echo "== rule selection"
cd "$repo"
expect_cmd fail "--only runs the named rule" \
  "$CHECK" --only no-ai-coauthor-trailer --base new-main --head dirty-branch
# Skipping every rule must not report a vacuous pass — an empty rule set is far
# more likely to be a broken --rules-dir than an intentional no-op.
expect_cmd usage-error "skipping every rule is an error, not a pass" \
  "$CHECK" --skip no-ai-coauthor-trailer,no-ai-commit-identity \
  --base new-main --head dirty-branch

# lib-*.sh are sourced helpers, not rules, and must not be run as rules.
if "$CHECK" --list | grep -q '^lib-'; then
  echo "FAIL lib-* helper was listed as a rule"
  failed=$((failed + 1))
else
  echo "ok   lib-* helpers are not treated as rules"
  passed=$((passed + 1))
fi
expect_cmd usage-error "an unknown --only name is an error, not a pass" \
  "$CHECK" --only no-such-rule --base new-main --head dirty-branch
expect_cmd usage-error "a bad --rules-dir is an error, not a pass" \
  "$CHECK" --rules-dir "${tmpdir}/nope" --base new-main --head dirty-branch
expect_cmd usage-error "an unfetched base ref is an error, not a pass" \
  "$CHECK" --base refs/remotes/origin/does-not-exist --head dirty-branch

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAILED: ${failed} failed, ${passed} passed."
  exit 1
fi
echo "PASSED: ${passed} checks."
