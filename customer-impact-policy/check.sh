#!/usr/bin/env bash
#
# check.sh — Require exactly one customer-impact label on a pull request.
#
# A PR passes only when it carries exactly one of:
#   customer-impact: none
#   customer-impact: low
#   customer-impact: medium
#   customer-impact: high
#
# No label fails, two or more fail, and any other label that starts with
# "customer-impact" (case-insensitively: a missing space, a capital letter, an
# unknown level, a trailing space) fails, alone or next to a valid one.
#
# Usage:
#   check.sh --repo <owner/name> --pr <number>   # read the PR's labels with gh
#   check.sh --labels-file <path>                # one label name per line; - for stdin
#
# --repo/--pr is the form CI uses. It reads the labels from the API at run time,
# not from the event payload, so a burst of labeled/unlabeled events that
# cancels earlier runs still ends on the PR's final labels. It needs gh with
# GH_TOKEN set.
#
# Exit codes:
#   0 — exactly one valid customer-impact label
#   1 — the PR breaks the rule
#   2 — usage or environment error
#
set -euo pipefail

LEVELS="customer-impact: none, customer-impact: low, customer-impact: medium, customer-impact: high"

REPO=""
PR=""
LABELS_FILE=""

die() {
  echo "Error: $*" >&2
  exit 2
}

usage() {
  sed -n '3,29p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'
}

# Print a failure as a GitHub annotation in Actions, plain text elsewhere.
fail() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::error::$*"
  else
    echo "Error: $*"
  fi
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --labels-file) LABELS_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ -n "$LABELS_FILE" ]; then
  if [ -n "$REPO" ] || [ -n "$PR" ]; then
    die "--labels-file conflicts with --repo/--pr; pick one"
  fi
  if [ "$LABELS_FILE" = "-" ]; then
    labels=$(cat)
  else
    [ -r "$LABELS_FILE" ] || die "cannot read labels file: $LABELS_FILE"
    labels=$(cat -- "$LABELS_FILE")
  fi
else
  [ -n "$REPO" ] || die "--repo is required (or use --labels-file)"
  [[ "$PR" =~ ^[0-9]+$ ]] || die "--pr must be a pull request number, got '${PR}'"
  command -v gh >/dev/null 2>&1 || die "gh is not installed"
  # One name per line, so --paginate cannot split the count per page. A failed
  # API call stops the script here with exit 2; it never falls through to
  # "no labels".
  labels=$(gh api "repos/${REPO}/issues/${PR}/labels" --paginate --jq '.[].name') \
    || die "could not read the labels of ${REPO}#${PR}"
fi

# grep -c prints 0 and exits 1 when nothing matches; `|| true` keeps the 0 and
# lets the checks below decide.
valid=$(printf '%s\n' "$labels" \
  | grep -Ec '^customer-impact: (none|low|medium|high)$' || true)
# Anything else that starts with customer-impact (a misspelt level, a missing
# space) is not counted as valid and also fails the check.
any=$(printf '%s\n' "$labels" | grep -Eic '^customer-impact' || true)
echo "customer-impact labels: $valid valid, $any starting with customer-impact"

if [ "$any" -ne "$valid" ]; then
  fail "PR has a customer-impact label that is not one of the four levels. Use exactly one of: ${LEVELS}."
fi
if [ "$valid" -eq 0 ]; then
  fail "PR is missing a customer-impact label. Add exactly one of: ${LEVELS}."
fi
if [ "$valid" -gt 1 ]; then
  fail "PR has $valid customer-impact labels. Keep exactly one."
fi
echo "ok: exactly one customer-impact label"
