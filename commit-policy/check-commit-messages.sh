#!/usr/bin/env bash
#
# check-commit-messages.sh — Check commit messages against the org's
# commit-message adherence rules.
#
# Every rule lives in rules/<name>.sh. This driver runs each rule against each
# message under test and aggregates the result. The CI check and the local
# commit-msg hook both go through here, so a commit that passes locally passes
# in CI.
#
# Usage:
#   check-commit-messages.sh --base <ref> --head <ref>   # commits <head> would add to <base>
#   check-commit-messages.sh --range <base>..<head>      # any git rev-list range
#   check-commit-messages.sh --rev <commit>              # a single commit
#   check-commit-messages.sh --message-file <path>       # a single message from a file (hook mode)
#   check-commit-messages.sh --list                      # list the rules and exit
#
# Options:
#   --rules-dir <dir>   Where the rules live (default: <script dir>/rules)
#   --only <a,b>        Run only these rules
#   --skip <a,b>        Skip these rules
#
# --base/--head is the form CI uses, and the reason this check exists. It asks
# git for the commits reachable from <head> but NOT from <base> — the commits
# the branch would actually add to the base branch. Commits already on the base
# branch are never examined, so rebasing onto older or newer base history can
# never make this check fail on a commit somebody else wrote.
#
# Do not "simplify" this into a check over every commit reachable from a pushed
# ref. That is precisely what made the equivalent GitHub push ruleset unusable:
# historical commits carrying a forbidden trailer became newly-reachable from
# unrelated branches after a rebase and blocked their pushes. See CORE-2704.
#
# Exit codes:
#   0 — every message passed every rule
#   1 — at least one violation
#   2 — usage or environment error
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/rules"

MODE=""
BASE=""
HEAD_REF=""
RANGE=""
REV=""
MESSAGE_FILE=""
ONLY=""
SKIP=""

die() {
  echo "Error: $*" >&2
  exit 2
}

usage() {
  sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'
}

set_mode() {
  [ -z "$MODE" ] || die "--$1 conflicts with --${MODE}; pick one input mode"
  MODE="$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base) set_mode "base"; BASE="${2:-}"; shift 2 ;;
    --head) HEAD_REF="${2:-}"; shift 2 ;;
    --range) set_mode "range"; RANGE="${2:-}"; shift 2 ;;
    --rev) set_mode "rev"; REV="${2:-}"; shift 2 ;;
    --message-file) set_mode "message-file"; MESSAGE_FILE="${2:-}"; shift 2 ;;
    --rules-dir) RULES_DIR="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --skip) SKIP="${2:-}"; shift 2 ;;
    --list) MODE="list"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$MODE" ] || { usage >&2; exit 2; }
[ -d "$RULES_DIR" ] || die "rules directory not found: ${RULES_DIR}"

in_list() {
  case ",$2," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

# Rules to run, as parallel name/path arrays. lib-*.sh are helpers shared by
# rules, not rules — they are sourced, not run.
RULE_NAMES=()
RULE_PATHS=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  name="$(basename "$path" .sh)"
  case "$name" in
    lib-*) continue ;;
  esac
  if [ -n "$ONLY" ] && ! in_list "$name" "$ONLY"; then continue; fi
  if [ -n "$SKIP" ] && in_list "$name" "$SKIP"; then continue; fi
  [ -x "$path" ] || die "rule is not executable: ${path}"
  RULE_NAMES+=("$name")
  RULE_PATHS+=("$path")
done < <(find "$RULES_DIR" -maxdepth 1 -name '*.sh' -type f | sort)

if [ "$MODE" = "list" ]; then
  if [ "${#RULE_NAMES[@]}" -eq 0 ]; then
    echo "No rules found in ${RULES_DIR}."
    exit 0
  fi
  i=0
  while [ "$i" -lt "${#RULE_NAMES[@]}" ]; do
    printf '%-32s %s\n' "${RULE_NAMES[$i]}" "$("${RULE_PATHS[$i]}" describe)"
    i=$((i + 1))
  done
  exit 0
fi

[ "${#RULE_NAMES[@]}" -gt 0 ] || die "no rules selected (rules dir ${RULES_DIR}, --only='${ONLY}', --skip='${SKIP}')"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

failed_messages=0
checked=0
# Newline-delimited list of rule indices that failed at least once, so each
# rule's remediation is printed once at the end rather than per commit.
failed_rule_indices=""

annotate() {
  # GitHub annotations must be one line; fold newlines into the literal escape.
  [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
  local title="$1" body="$2"
  printf '::error title=%s::%s\n' "$title" "${body//$'\n'/%0A}"
}

record_rule_failure() {
  local idx="$1"
  case ",${failed_rule_indices}," in
    *",${idx},"*) return 0 ;;
  esac
  failed_rule_indices="${failed_rule_indices},${idx}"
}

# check_message <message-file> <label> [<identity-file>]
#
# <label> identifies the message in output: a short sha + subject for commits,
# or "commit message" in hook mode.
#
# <identity-file> holds the commit's "author:" and "committer:" lines when they
# are known. Rules that only look at the message ignore it.
check_message() {
  local msg_file="$1" label="$2" ident_file="${3:-}"
  local i=0 rc violations rule_failed=0

  checked=$((checked + 1))
  echo "--- ${label}"

  while [ "$i" -lt "${#RULE_NAMES[@]}" ]; do
    set +e
    violations="$("${RULE_PATHS[$i]}" check "$msg_file" "$ident_file" 2>&1)"
    rc=$?
    set -e

    case "$rc" in
      0)
        echo "  OK      ${RULE_NAMES[$i]}"
        ;;
      1)
        rule_failed=1
        record_rule_failure "$i"
        echo "  FAIL    ${RULE_NAMES[$i]}"
        printf '%s\n' "$violations" | sed 's/^/            /'
        annotate "${RULE_NAMES[$i]}" "${label}: ${violations}"
        ;;
      *)
        echo "  ERROR   ${RULE_NAMES[$i]} exited ${rc}" >&2
        printf '%s\n' "$violations" | sed 's/^/            /' >&2
        exit 2
        ;;
    esac
    i=$((i + 1))
  done

  [ "$rule_failed" -eq 0 ] || failed_messages=$((failed_messages + 1))
  echo ""
}

require_rev() {
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null \
    || die "cannot resolve '$1' to a commit — is it fetched? (try: git fetch origin)"
}

check_revs() {
  local sha subject
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    subject="$(git log -1 --format=%s "$sha")"
    git log -1 --format=%B "$sha" > "${tmpdir}/msg"
    git log -1 --format='author: %an <%ae>
committer: %cn <%ce>' "$sha" > "${tmpdir}/ident"
    check_message "${tmpdir}/msg" "${sha:0:8} ${subject}" "${tmpdir}/ident"
  done
}

# Writes the identity `git commit` is about to use, for hook mode. Reflects
# config and the GIT_AUTHOR_*/GIT_COMMITTER_* environment, which covers an agent
# that sets its own identity — the case worth catching locally. It cannot see a
# `git commit --author=...` override, since git applies that after the hook runs;
# CI catches that one.
write_prospective_identity() {
  local out="$1" author committer
  git rev-parse --git-dir >/dev/null 2>&1 || return 1
  author="$(git var GIT_AUTHOR_IDENT 2>/dev/null || true)"
  committer="$(git var GIT_COMMITTER_IDENT 2>/dev/null || true)"
  [ -n "$author" ] || [ -n "$committer" ] || return 1
  # `git var` appends " <unix-timestamp> <tz>"; the rules want just "Name <email>".
  {
    [ -z "$author" ] || printf 'author: %s\n' "$(printf '%s' "$author" | sed -E 's/ [0-9]+ [+-][0-9]{4}$//')"
    [ -z "$committer" ] || printf 'committer: %s\n' "$(printf '%s' "$committer" | sed -E 's/ [0-9]+ [+-][0-9]{4}$//')"
  } > "$out"
}

# Strips what `git commit` itself would strip before storing the message, so the
# rules never see git's instructional comments or the `commit.verbose` diff below
# the scissors line. Without this, hook mode judges text that never becomes part
# of any commit.
clean_message() {
  local src="$1" dest="$2" cc
  cc="$(git config --get core.commentChar 2>/dev/null || true)"
  case "$cc" in
    ''|auto) cc='#' ;;
  esac
  sed -e "/^${cc}.*>8/,\$d" -e "/^${cc}/d" "$src" > "$dest"
}

case "$MODE" in
  base)
    [ -n "$BASE" ] || die "--base needs a ref"
    [ -n "$HEAD_REF" ] || die "--base requires --head"
    git rev-parse --git-dir >/dev/null 2>&1 || die "--base/--head must run inside a git repository"
    require_rev "$BASE"
    require_rev "$HEAD_REF"
    echo "Checking commits reachable from ${HEAD_REF} but not from ${BASE}."
    echo "Rules: ${RULE_NAMES[*]}"
    echo ""
    check_revs < <(git rev-list --reverse "$HEAD_REF" --not "$BASE")
    ;;
  range)
    [ -n "$RANGE" ] || die "--range needs a revision range"
    git rev-parse --git-dir >/dev/null 2>&1 || die "--range must run inside a git repository"
    echo "Checking commits in ${RANGE}."
    echo "Rules: ${RULE_NAMES[*]}"
    echo ""
    check_revs < <(git rev-list --reverse "$RANGE")
    ;;
  rev)
    [ -n "$REV" ] || die "--rev needs a commit"
    git rev-parse --git-dir >/dev/null 2>&1 || die "--rev must run inside a git repository"
    require_rev "$REV"
    check_revs < <(git rev-parse "$REV^{commit}")
    ;;
  message-file)
    [ -n "$MESSAGE_FILE" ] || die "--message-file needs a path"
    [ -f "$MESSAGE_FILE" ] || die "message file not found: ${MESSAGE_FILE}"
    ident_arg=""
    if write_prospective_identity "${tmpdir}/ident"; then
      ident_arg="${tmpdir}/ident"
    fi
    if clean_message "$MESSAGE_FILE" "${tmpdir}/msg" 2>/dev/null; then
      check_message "${tmpdir}/msg" "commit message" "$ident_arg"
    else
      check_message "$MESSAGE_FILE" "commit message" "$ident_arg"
    fi
    ;;
esac

if [ "$checked" -eq 0 ]; then
  echo "No commit messages to check — nothing this branch adds to the base branch."
  exit 0
fi

if [ "$failed_messages" -gt 0 ]; then
  echo "FAILED: ${failed_messages} of ${checked} commit message(s) broke commit-message policy."
  echo ""
  for idx in ${failed_rule_indices//,/ }; do
    echo "== ${RULE_NAMES[$idx]}: $("${RULE_PATHS[$idx]}" describe)"
    "${RULE_PATHS[$idx]}" remediation | sed 's/^/   /'
    echo ""
  done
  echo "Install the local hook to catch this before pushing:"
  echo "  <path-to-Atum-Labs/.github>/commit-policy/install-hooks.sh"
  exit 1
fi

echo "All ${checked} commit message(s) passed commit-message policy."
