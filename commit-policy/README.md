# Commit Message Adherence

A single CI check that holds every commit an Atum-Labs PR introduces to the org's
commit-message rules, plus a local git hook that runs the same rules at
`git commit` so you don't wait for CI to find out.

Today there are two rules, both about AI attribution, but the check is a container
for commit-message rules generally. Adding the next one is a new file in
[`rules/`](rules); no workflow or caller change.

## Contents

| Path | What it is |
| ---- | ---------- |
| [`check-commit-messages.sh`](check-commit-messages.sh) | The driver. Selects commits, runs every rule against each message, aggregates the result. |
| [`rules/`](rules) | One rule per file, plus `ai-identities.patterns` (the agent list, shared by both rules) and `lib-ai-identities.sh` (the matcher they share). |
| [`hooks/commit-msg`](hooks/commit-msg) | The git hook, installed into a repo by the installer. |
| [`install-hooks.sh`](install-hooks.sh) | Installs / refreshes / removes the hook in a local repo. |
| [`test.sh`](test.sh) | Self-test. No arguments, no network, no state outside its temp dir. |
| [`../.github/workflows/commit-message-adherence.yml`](../.github/workflows/commit-message-adherence.yml) | The CI check — reusable workflow and org required workflow. |
| [`../workflow-templates/commit-message-adherence.yml`](../workflow-templates/commit-message-adherence.yml) | Starter caller workflow, offered to every org repo in the Actions UI. |

## Install the local hook

From inside the repo you want it in, pointing at your clone of this repo:

```sh
~/dev/Atum-Labs/.github/commit-policy/install-hooks.sh
```

That writes a `commit-msg` hook and a copy of the rules into the repo's
`.git/hooks/`. Nothing lands in the working tree, so there is nothing to commit
and no per-repo copy of the policy to keep in sync.

```sh
install-hooks.sh --check       # what's installed, and is it current
install-hooks.sh --uninstall   # remove it
install-hooks.sh ~/dev/Atum-Labs/atum-core   # install into some other repo
```

Because the rules are *copied*, re-run the installer after pulling this repo to
pick up rule changes. `--check` reports a stale install. The CI check always runs
the current rules and is the authority; the hook is a fast local preview of it.

It's a `commit-msg` hook, not `pre-commit`: `pre-commit` runs before the message
exists, so it cannot inspect one. `git commit --no-verify` bypasses it for a
single commit — CI still has the final say.

An existing `commit-msg` hook is moved to `commit-msg.commit-policy.bak` rather
than overwritten, and the installer says so. It is not chained, so merge it in
yourself if you still need it.

## Run it by hand

```sh
# What a PR would add to main — the form CI uses
commit-policy/check-commit-messages.sh --base origin/main --head HEAD

# A message in a file, a single commit, an arbitrary range
commit-policy/check-commit-messages.sh --message-file .git/COMMIT_EDITMSG
commit-policy/check-commit-messages.sh --rev HEAD
commit-policy/check-commit-messages.sh --range origin/main..HEAD

commit-policy/check-commit-messages.sh --list   # the active rules
```

Exit codes: `0` clean, `1` a violation, `2` a usage or environment problem.
A `2` never means "clean" — an empty rule set or an unresolvable base ref fails
loudly rather than reporting a vacuous green.

## Why the check is PR-scoped, and must stay that way

This replaces a `commit_message_pattern` rule in the org's "Protect ALL branches"
push ruleset (`13148241`). That rule was unusable, and the reason generalises to
any push-time check:

`main` already carries commits with the forbidden trailers — 3 from Cursor
(earliest 2026-06-18), 6 from Claude (earliest 2025-08-14). A push ruleset
validates every commit *newly reachable from the pushed ref*, including commits
that already exist elsewhere in the repo and merely became ancestors of this ref
for the first time. So the moment a branch rebased onto a `main` containing one of
those commits, its push was rejected over a commit its author never wrote —
[atum-core#1664](https://github.com/Atum-Labs/atum-core/pull/1664),
[#1665](https://github.com/Atum-Labs/atum-core/pull/1665), and
[#1666](https://github.com/Atum-Labs/atum-core/pull/1666). A ruleset cannot be
scoped to "commits after X", and purging the offending commits would mean
re-signing ~928 commits behind a YubiKey touch plus force-pushing `main`.

This check instead asks git for the commits reachable from the PR head but **not**
from the current tip of the base branch. Historical commits are ancestors of both
sides, so they are never in range, and no amount of rebasing can put them there.

Three details in the workflow carry that guarantee, and are worth preserving:

- The range is anchored on the base branch's **current tip**
  (`refs/remotes/origin/<base>`), not on `pull_request.base.sha`. `base.sha` is the
  base tip as of the webhook; if the branch later merged a newer base in, the
  commits between the two would land inside the range and the check would start
  judging commits the PR author didn't write — the same bug in a new place.
- `types:` includes **`edited`**. The default `pull_request` types are
  `opened`/`synchronize`/`reopened`, and retargeting a PR's base branch fires none
  of them — it fires `edited`. Since the range is computed against the base branch,
  a stacked PR retargeted to `main` would otherwise keep the green result it earned
  against its old base, even though its range now includes commits the old base was
  hiding. For a required check that is a stale pass on exactly the commits this
  check exists to catch.
- Checkout uses `fetch-depth: 0` with `filter: blob:none`. Full commit history is
  required to compute the range; file contents are not, since only messages are
  read. The filter keeps a full-history fetch cheap on a large monorepo.

## Wire it into a repo

Two routes. Both end at the same reusable workflow.

**Org required workflow** (how `Verify Commit Signatures` is wired) — point the
org's required-workflow setting at
`Atum-Labs/.github/.github/workflows/commit-message-adherence.yml@main`. No file
in any repo. Preferred for org-wide rollout.

**Per-repo caller** — copy
[`../workflow-templates/commit-message-adherence.yml`](../workflow-templates/commit-message-adherence.yml)
to `.github/workflows/commit-message-adherence.yml` in the repo, or pick
"Commit Message Adherence" from the repo's Actions → New workflow page, which
offers it to every org repo from this repo's `workflow-templates/`.

Either way the repo needs the `DOT_GITHUB_READ_TOKEN` secret — the workflow uses
it to read these scripts out of this private repo, the same way
`verify-commit-signatures.yml` does. The caller forwards it with
`secrets: inherit`.

To make it required, take the check's context name from an actual completed run
(`gh pr checks <pr>`) rather than guessing it — it depends on the route, since a
reusable-workflow call reports as `<caller job> / <called job>`. Then add it to the
branch ruleset's required status checks.

## Add a rule

A rule is one executable in [`rules/`](rules) answering three subcommands:

| Invocation | Contract |
| ---------- | -------- |
| `rule.sh check <message-file> [<identity-file>]` | Exit `0` clean, `1` with one violation line per problem on stdout, `2` if the rule itself is broken. |
| `rule.sh describe` | One line naming what the rule requires. Shown by `--list` and in failure output. |
| `rule.sh remediation` | How to fix it. Printed once per failing rule at the end of a run. |

The driver finds rules by globbing `rules/*.sh`, so dropping the file in is the
whole wiring step. Files named `lib-*.sh` are skipped — they are helpers rules
source, not rules. Copy `no-ai-coauthor-trailer.sh` as the starting shape, add
cases to [`test.sh`](test.sh), and run it.

A rule sees the commit message, and optionally the commit's author and committer
in `<identity-file>`:

```
author: Name <email>
committer: Name <email>
```

Nothing else — no diff, no branch, no file list. That is deliberate: it is what
lets the same rule back both the CI check and a `commit-msg` hook, where none of
the rest exists yet. The identity file is absent when there is no identity to
report, and a rule that only reads the message ignores the argument.

In hook mode the driver also does what `git commit` would do before storing a
message: it drops comment lines and everything below the `commit.verbose`
scissors line, so rules never judge text that will not end up in the commit.

## The two AI-attribution rules

Team policy is no AI attribution on commits at all. Both rules draw their agent
list from [`rules/ai-identities.patterns`](rules/ai-identities.patterns) — Claude,
Cursor, and Sculptor, by name and by the address each commits as. Add a line there
to cover a new agent; that file is the whole interface.

### `no-ai-coauthor-trailer`

Rejects `Co-authored-by:` trailers crediting an agent. Human `Co-authored-by:`
trailers are valid and present in this repo's own history, so this is not a
blanket ban.

Candidate trailers are found two ways, because either alone has a hole:

1. `git interpret-trailers --parse`, authoritative for real trailers and correct
   about unfolding wrapped ones.
2. Every **unindented** line matching `^Co-authored-by:`, anywhere in the message.

Pass 2 exists because `--parse` only treats the last paragraph as a trailer block
when at least 25% of its lines look like trailers. Four prose lines followed by
`Co-Authored-By: Claude <…>` in the same paragraph is 20%, so `--parse` reports
nothing and pass 1 alone would let it through — something the old push ruleset's
plain regex did catch.

The unindented requirement is what keeps pass 2 from flagging a commit that
*documents* the rule: a real trailer is never indented, while a quoted example is
either inline in a sentence or in an indented block. Both forms are covered by
tests.

### `no-ai-commit-identity`

Rejects commits whose **author or committer** is an agent identity, even when the
message is clean.

This is in a check named "commit message" on purpose. A commit authored as
`Cursor Agent <cursoragent@cursor.com>` carries no trailer, so the trailer rule
passes it — and then the squash merge puts the trailer on the base branch anyway,
because GitHub synthesises a `Co-authored-by:` trailer for every distinct author
among the squashed commits and `atum-core` squashes with
`squash_merge_commit_message=COMMIT_MESSAGES`. An agent identity on a branch commit
becomes an AI co-author trailer on `main` — the exact thing whose presence in
history forced this check to exist. Checking only the message leaves that open.

In hook mode there is no commit yet, so the rule judges the identity `git commit`
is about to use (`git var GIT_AUTHOR_IDENT` / `GIT_COMMITTER_IDENT`), which covers
an agent that sets `user.email` for itself. It cannot see a `git commit --author=`
override, since git applies that after the hook runs; CI catches that one.

### Known sharp edge

Patterns are anchored to the start of the name, so a contributor whose given name
is one of the agent names (Claude is a common French name) would trip both rules.
Narrow that pattern in `ai-identities.patterns` if it ever happens.

## Test

```sh
commit-policy/test.sh
```

43 checks over crafted messages and a throwaway repo. The ones worth knowing about:

- the #1664/#1665/#1666 regression — a clean branch stacked on base-branch history
  that *does* contain forbidden trailers, judged against a newer base tip, must pass
- a trailer buried under prose below git's 25% trailer-block threshold must fail,
  while an indented example of the same trailer must pass
- a commit authored by an agent with a clean message must fail, and the test asserts
  that the trailer rule alone would have passed it
- `GitHub <noreply@github.com>` as committer must pass, so squash and merge-queue
  commits are not mistaken for agents
