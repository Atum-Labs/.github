# Customer Impact Label

A single CI check, `customer-impact-label`, that fails an Atum-Labs PR unless it
carries exactly one `customer-impact` label. The label says how much of the change
a customer or integrator can observe, so a release can list what customers will
see differently before it ships. The PR template's
[Customer impact section](../PULL_REQUEST_TEMPLATE.md) (added in
[#1](https://github.com/Atum-Labs/.github/pull/1)) is where the author says why.

## The four levels

Judge by what someone outside the company can observe, not by the size of the diff.

- `customer-impact: none`: nothing a customer or integrator can observe (CI, deploy, internal refactors).
- `customer-impact: low`: observable but within what they already expect (a new optional field, a new named error code, an opt-in feature).
- `customer-impact: medium`: changes something they experience or tune (a wait or latency, a limit, a default, an error path they handle).
- `customer-impact: high`: breaking or money-moving (a removed or renamed field, a request that was accepted now refused, a settlement, refund or deadline timing change).

## What the check does

| Labels on the PR | Result |
| ---------------- | ------ |
| none of the four | fail: "PR is missing a customer-impact label. Add exactly one of: ..." |
| exactly one of the four | pass |
| two or more of the four | fail: "PR has N customer-impact labels. Keep exactly one." |
| a near-miss (`customer-impact:none`, `Customer-Impact: none`, `customer-impact: urgent`, a trailing space), alone or beside a valid one | fail: "PR has a customer-impact label that is not one of the four levels. ..." |

- Labels are read from the API when the job runs (`gh api repos/$REPO/issues/$PR/labels --paginate`),
  not from the event payload, and counted one name per line, so a PR with more
  than one page of labels is counted correctly.
- It re-runs on `labeled` and `unlabeled`, and runs are grouped per PR with
  `cancel-in-progress`, so a burst of label changes ends on the final labels.
- Drafts are checked. A draft without a label shows red until it is labeled.
- On `merge_group` it passes through: the queue entry was checked as a PR.
- A label added by another workflow with `GITHUB_TOKEN` does not fire `labeled`,
  so it does not re-run the check; push or toggle the label to re-run it.

## Contents

| Path | What it is |
| ---- | ---------- |
| [`check.sh`](check.sh) | The rule. `--repo owner/name --pr N` reads the labels with `gh`; `--labels-file path` (or `-` for stdin) takes one label per line. Exit `0` pass, `1` fail, `2` usage or API error. |
| [`test.sh`](test.sh) | Self-test. Runs `check.sh` against a stub `gh` that serves each label set as API pages of two labels. No arguments, no network. |
| [`../.github/workflows/customer-impact-label.yml`](../.github/workflows/customer-impact-label.yml) | The CI check: org required workflow and reusable workflow. |
| [`../workflow-templates/customer-impact-label.yml`](../workflow-templates/customer-impact-label.yml) | Starter caller workflow, offered to every org repo in the Actions UI. |

Run it by hand against a real PR:

```sh
customer-impact-policy/check.sh --repo Atum-Labs/.github --pr 1
```

## Adopt it in a repo

1. **Create the four labels first.** Once the check is required, every open PR
   without exactly one label turns red and cannot merge, so the labels have to
   exist, and open PRs should be labeled, before that step:

   ```sh
   for level in none low medium high; do
     gh label create "customer-impact: ${level}" --repo Atum-Labs/REPO
   done
   ```

2. **Run the check.** Either copy
   [`../workflow-templates/customer-impact-label.yml`](../workflow-templates/customer-impact-label.yml)
   to `.github/workflows/customer-impact-label.yml` in the repo, or pick
   "Customer Impact Label" from the repo's Actions → New workflow page. Let it
   report without being required for a few days.
3. **Make it required.** Take the check's context name from a completed run
   (`gh pr checks`) rather than guessing it: through the caller it reports as
   `customer-impact-label / customer-impact-label`. Add it to the repo's branch
   ruleset as a required status check.

**Org-wide instead of per repo:** point an org ruleset's "Require workflows to
pass" rule at
`Atum-Labs/.github/.github/workflows/customer-impact-label.yml@main`, the way
`Verify Commit Signatures` is wired. That needs an org ruleset, which only an
org admin can create; the per-repo caller and branch ruleset above is the route
that does not.

## Test

```sh
customer-impact-policy/test.sh
```

25 checks: no label, each of the four levels alone, two and three valid labels,
each near-miss alone and beside a valid label, label sets spread over three API
pages, and the error paths (a failed API call is exit `2`, never "no labels").
