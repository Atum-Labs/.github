#!/usr/bin/env bash
#
# test.sh — Self-test for the customer-impact label check.
#
# Runs check.sh the way CI does (--repo/--pr) against a stub `gh` that serves
# each label set as paginated API pages, two labels per page, and applies the
# check's own --jq filter to each page separately, as `gh api --paginate --jq`
# does. That makes multi-page label sets real: a count taken per page would
# print one number per page and get them wrong. Takes no arguments, touches
# nothing outside its temp directory, and needs only bash, grep and jq.
#
# Usage: customer-impact-policy/test.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check.sh"

command -v jq >/dev/null 2>&1 || { echo "test.sh needs jq" >&2; exit 2; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
unset GITHUB_ACTIONS || true

# The stub gh. It answers only the call check.sh makes, and fails loudly on
# anything else, so a change to that call cannot pass silently.
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${STUB_GH_FAIL:-}" = "1" ] && { echo "gh: HTTP 502" >&2; exit 1; }
[ "$1" = "api" ] || { echo "stub gh: unexpected subcommand $1" >&2; exit 99; }
url="$2"; shift 2
paginate=0; filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paginate=1; shift ;;
    --jq) filter="$2"; shift 2 ;;
    *) echo "stub gh: unexpected argument $1" >&2; exit 99 ;;
  esac
done
[ "$url" = "repos/${STUB_REPO}/issues/${STUB_PR}/labels" ] \
  || { echo "stub gh: unexpected URL $url" >&2; exit 99; }
[ -n "$filter" ] || { echo "stub gh: expected --jq" >&2; exit 99; }
pages=("${STUB_PAGES_DIR}"/page-*.json)
[ "$paginate" = "1" ] || pages=("${pages[0]}")
for page in "${pages[@]}"; do
  jq -r "$filter" "$page"
done
STUB
chmod +x "${tmpdir}/bin/gh"

export STUB_REPO="octo-org/octo-repo"
export STUB_PR="42"
export STUB_PAGES_DIR="${tmpdir}/pages"

passed=0
failed=0

# write_pages <label...> — the label set as API pages of two labels each.
# Zero labels is one empty page, as the API returns.
write_pages() {
  rm -rf "$STUB_PAGES_DIR"
  mkdir -p "$STUB_PAGES_DIR"
  local n=0 page=1 chunk=()
  if [ $# -eq 0 ]; then
    echo '[]' > "${STUB_PAGES_DIR}/page-001.json"
    return
  fi
  for label in "$@"; do
    chunk+=("$label")
    n=$((n + 1))
    if [ $((n % 2)) -eq 0 ] || [ "$n" -eq $# ]; then
      printf '%s\n' "${chunk[@]}" \
        | jq -R '{name: .}' | jq -s '.' \
        > "$(printf '%s/page-%03d.json' "$STUB_PAGES_DIR" "$page")"
      page=$((page + 1))
      chunk=()
    fi
  done
}

# run_case <pass|fail|usage-error> <name> <expected output substring> <cmd...>
run_case() {
  local expect="$1" name="$2" needle="$3"
  shift 3
  local want out rc
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
  if [ "$rc" -eq "$want" ] && [[ "$out" == *"$needle"* ]]; then
    echo "ok   ${name}"
    passed=$((passed + 1))
  else
    echo "FAIL ${name} — expected exit ${want} and output containing '${needle}', got exit ${rc}"
    printf '%s\n' "$out" | sed 's/^/       /'
    failed=$((failed + 1))
  fi
}

# expect <pass|fail> <name> <expected output substring> <label...>
expect() {
  local expect="$1" name="$2" needle="$3"
  shift 3
  write_pages "$@"
  run_case "$expect" "$name" "$needle" \
    env PATH="${tmpdir}/bin:${PATH}" "$CHECK" --repo "$STUB_REPO" --pr "$STUB_PR"
}

MISSING="missing a customer-impact label"
NOT_LEVEL="not one of the four levels"
OK="ok: exactly one customer-impact label"

echo "== no valid label"
expect fail "no labels at all" "$MISSING"
expect fail "unrelated labels only" "$MISSING" "bug" "documentation"
expect fail "review-priority label only" "$MISSING" "review-priority:important"

echo ""
echo "== exactly one valid label"
expect pass "customer-impact: none" "$OK" "customer-impact: none"
expect pass "customer-impact: low" "$OK" "customer-impact: low"
expect pass "customer-impact: medium" "$OK" "customer-impact: medium"
expect pass "customer-impact: high" "$OK" "customer-impact: high"
expect pass "one valid label beside unrelated labels" "$OK" \
  "review-priority:blocking" "bug" "customer-impact: medium" "documentation"

echo ""
echo "== more than one valid label"
expect fail "two valid labels" "has 2 customer-impact labels. Keep exactly one." \
  "customer-impact: none" "customer-impact: high"
expect fail "three valid labels" "has 3 customer-impact labels. Keep exactly one." \
  "customer-impact: low" "customer-impact: medium" "customer-impact: high"

echo ""
echo "== near-miss spellings"
expect fail "no space after the colon" "$NOT_LEVEL" "customer-impact:none"
expect fail "capitalised" "$NOT_LEVEL" "Customer-Impact: none"
expect fail "unknown level" "$NOT_LEVEL" "customer-impact: urgent"
expect fail "trailing space" "$NOT_LEVEL" "customer-impact: none "
expect fail "near-miss beside a valid label" "$NOT_LEVEL" \
  "customer-impact: low" "customer-impact: urgent"
expect fail "capitalised beside a valid label" "$NOT_LEVEL" \
  "Customer-Impact: none" "customer-impact: none"

echo ""
echo "== more than one page of labels (two labels per page)"
# The valid label is on the last of three pages: a check that read only the
# first page would miss it.
expect pass "valid label on page 3 of 3" "$OK" \
  "bug" "documentation" "enhancement" "question" "customer-impact: low"
# One valid label on each of two pages: per-page counts would be 1 and 1, each
# of which looks like a pass.
expect fail "two valid labels on different pages" \
  "has 2 customer-impact labels. Keep exactly one." \
  "bug" "customer-impact: low" "documentation" "customer-impact: high"
expect fail "near-miss on a later page than the valid label" "$NOT_LEVEL" \
  "customer-impact: none" "bug" "documentation" "customer-impact:none"

echo ""
echo "== input and environment"
printf '%s\n' "bug" "customer-impact: high" > "${tmpdir}/labels.txt"
run_case pass "--labels-file reads one label per line" "$OK" \
  "$CHECK" --labels-file "${tmpdir}/labels.txt"
# shellcheck disable=SC2016 # $1 is expanded by the inner bash, on purpose.
run_case fail "--labels-file - reads stdin" "$MISSING" \
  bash -c 'printf "bug\n" | "$1" --labels-file -' _ "$CHECK"
write_pages "customer-impact: none"
run_case usage-error "an API failure is an error, not 'no labels'" "could not read the labels" \
  env PATH="${tmpdir}/bin:${PATH}" STUB_GH_FAIL=1 "$CHECK" --repo "$STUB_REPO" --pr "$STUB_PR"
run_case usage-error "a non-numeric --pr is an error" "must be a pull request number" \
  "$CHECK" --repo "$STUB_REPO" --pr ""
run_case usage-error "an unreadable labels file is an error" "cannot read labels file" \
  "$CHECK" --labels-file "${tmpdir}/nope"
run_case fail "GitHub Actions output is an ::error:: annotation" "::error::PR is missing" \
  env GITHUB_ACTIONS=true "$CHECK" --labels-file /dev/null

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAILED: ${failed} failed, ${passed} passed."
  exit 1
fi
echo "PASSED: ${passed} checks."
