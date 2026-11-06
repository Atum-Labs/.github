#!/usr/bin/env bash
#
# install-hooks.sh — Install the commit-message adherence check as a local git
# hook, so violations surface at `git commit` instead of on a CI check.
#
# Usage:
#   install-hooks.sh [<repo>]              # install into <repo> (default: cwd)
#   install-hooks.sh --uninstall [<repo>]
#   install-hooks.sh --check [<repo>]      # report what is installed, change nothing
#
# The hook and a copy of the rules land in the repo's hooks directory, inside
# git's private directory. Nothing is added to the working tree, so no repo has
# to carry its own copy of the policy and there is nothing to commit.
#
# Because the rules are copied, re-run this after pulling Atum-Labs/.github to
# pick up new or changed rules. The CI check always runs the current rules and
# is the authority; the hook is a fast local preview of it.
#
# Exit codes:
#   0 — installed / uninstalled / up to date
#   1 — --check found the hook missing or stale
#   2 — usage or environment error
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MARKER="managed-by: Atum-Labs/.github commit-policy"

ACTION="install"
TARGET=""

die() {
  echo "Error: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) ACTION="uninstall"; shift ;;
    --check) ACTION="check"; shift ;;
    -h|--help) sed -n '3,23p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) [ -z "$TARGET" ] || die "only one repo may be given"; TARGET="$1"; shift ;;
  esac
done

TARGET="${TARGET:-$PWD}"
[ -d "$TARGET" ] || die "not a directory: ${TARGET}"

git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: ${TARGET}"

# Resolve the hooks directory the way git itself does:
#   - core.hooksPath wins if set (it may be relative to the repo root)
#   - otherwise <common git dir>/hooks. The *common* dir matters: inside a
#     linked worktree, --git-dir points at .git/worktrees/<name>, but git runs
#     hooks from the main .git/hooks, so installing into --git-dir would create
#     a hook git never calls.
hooks_path="$(git -C "$TARGET" config --get core.hooksPath || true)"
if [ -n "$hooks_path" ]; then
  case "$hooks_path" in
    /*) HOOKS_DIR="$hooks_path" ;;
    *) HOOKS_DIR="$(git -C "$TARGET" rev-parse --show-toplevel)/${hooks_path}" ;;
  esac
  echo "Note: core.hooksPath is set; using ${HOOKS_DIR}"
else
  HOOKS_DIR="$(cd -- "$(git -C "$TARGET" rev-parse --git-common-dir)" && pwd)/hooks"
fi

HOOK_FILE="${HOOKS_DIR}/commit-msg"
POLICY_DIR="${HOOKS_DIR}/commit-policy"

is_ours() {
  [ -f "$1" ] && grep -q "$MARKER" "$1"
}

case "$ACTION" in
  check)
    if ! is_ours "$HOOK_FILE"; then
      if [ -e "$HOOK_FILE" ]; then
        echo "commit-msg hook exists but is not managed by commit-policy: ${HOOK_FILE}"
      else
        echo "commit-msg hook is not installed (${HOOK_FILE})"
      fi
      exit 1
    fi
    if ! diff -rq "${SCRIPT_DIR}/rules" "${POLICY_DIR}/rules" >/dev/null 2>&1 \
      || ! diff -q "${SCRIPT_DIR}/check-commit-messages.sh" "${POLICY_DIR}/check-commit-messages.sh" >/dev/null 2>&1 \
      || ! diff -q "${SCRIPT_DIR}/hooks/commit-msg" "$HOOK_FILE" >/dev/null 2>&1; then
      echo "commit-msg hook is installed but stale — re-run ${BASH_SOURCE[0]}"
      exit 1
    fi
    echo "commit-msg hook is installed and up to date (${HOOK_FILE})"
    "${POLICY_DIR}/check-commit-messages.sh" --list
    exit 0
    ;;

  uninstall)
    removed=0
    if is_ours "$HOOK_FILE"; then
      rm -f "$HOOK_FILE"
      echo "Removed ${HOOK_FILE}"
      removed=1
    elif [ -e "$HOOK_FILE" ]; then
      echo "Left ${HOOK_FILE} alone — it is not managed by commit-policy."
    fi
    if [ -d "$POLICY_DIR" ]; then
      rm -rf "$POLICY_DIR"
      echo "Removed ${POLICY_DIR}"
      removed=1
    fi
    [ "$removed" -eq 1 ] || echo "Nothing to uninstall."
    if [ -f "${HOOK_FILE}.commit-policy.bak" ]; then
      echo "A pre-existing hook is still parked at ${HOOK_FILE}.commit-policy.bak — restore it if you want it back."
    fi
    exit 0
    ;;
esac

[ -d "$HOOKS_DIR" ] || mkdir -p "$HOOKS_DIR"

# Never clobber somebody else's hook silently.
if [ -e "$HOOK_FILE" ] && ! is_ours "$HOOK_FILE"; then
  backup="${HOOK_FILE}.commit-policy.bak"
  [ ! -e "$backup" ] || die "refusing to overwrite ${HOOK_FILE}: a backup already exists at ${backup}; move or delete it first"
  mv "$HOOK_FILE" "$backup"
  echo "Existing commit-msg hook moved to ${backup}."
  echo "It is no longer running. Merge it into the new hook if you still need it."
fi

rm -rf "$POLICY_DIR"
mkdir -p "${POLICY_DIR}/rules"
cp "${SCRIPT_DIR}/check-commit-messages.sh" "${POLICY_DIR}/check-commit-messages.sh"
cp "${SCRIPT_DIR}/rules/"* "${POLICY_DIR}/rules/"
chmod +x "${POLICY_DIR}/check-commit-messages.sh" "${POLICY_DIR}/rules/"*.sh

cp "${SCRIPT_DIR}/hooks/commit-msg" "$HOOK_FILE"
chmod +x "$HOOK_FILE"

echo "Installed commit-msg hook: ${HOOK_FILE}"
echo "Rules copied to:           ${POLICY_DIR}"
echo ""
"${POLICY_DIR}/check-commit-messages.sh" --list
echo ""
echo "Re-run this script after pulling Atum-Labs/.github to refresh the rules."
