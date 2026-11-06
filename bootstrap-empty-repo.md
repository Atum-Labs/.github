# Bootstrapping a New Repository

The first commit to a new Atum-Labs repo cannot be pushed by either the owner account or a regular contributor account acting alone. This guide explains why and walks through the two-account procedure we use.

## Why a fresh repo can't accept its first commit

Atum-Labs enforces two organization-level [repository rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets):

- **Protect ALL branches** (id `13148241`) — requires every commit to be signed by a verified key, blocks branch deletion, and forbids certain commit-message patterns. No bypass actors.
- **Protect Default Branches** (id `13148604`) — requires linear history, a reviewed pull request, and a successful run of the **Verify Commit Signatures** [required workflow](https://docs.github.com/en/actions/using-workflows/required-workflows). No bypass actors.

The required-workflow rule creates a chicken-and-egg on an empty repo: the workflow can only run on a commit that exists, but the rule rejects the push before the commit lands. The web UI's "Initialize with README" hits the same wall. The error looks like:

> Required workflow 'Verify Commit Signatures, Verify Commit Signatures' is not satisfied

The only way through is a one-time, narrowly-scoped bypass on the "Protect Default Branches" ruleset.

## Why this needs two people (or two accounts)

GitHub's permission model and our policy split the necessary capabilities across two roles, and neither can do this alone:

| Capability                                                                 | Held by                            | Atum-Labs example   |
| -------------------------------------------------------------------------- | ---------------------------------- | ------------------- |
| Create a new organization repository                                       | Organization **owner** only — `members_can_create_repositories` is `false` for this org | `gene-atum-admin`   |
| Edit `bypass_actors` on an organization ruleset                            | Organization **owner** (or a custom org role with "Manage organization repository rules") | `gene-atum-admin`   |
| Push a commit that passes the **required signatures** rule                 | Any account with a verified signing key registered on the account and Write access to the repo | `geneAum`           |

The owner account in this org **does not** have a signing key registered on GitHub (by policy — separation of duties between rule administration and code authorship), so its commits would be rejected by the required-signatures rule. The contributor account **does** have a signing key but **cannot** edit org rulesets.

So we need both: the owner opens a narrowly-scoped bypass on the workflow ruleset only, the contributor pushes the signed initial commit, the owner closes the bypass. The required-signatures rule stays enforced the whole time because it lives on the other ruleset.

The example accounts below — `gene-atum-admin` (owner) and `geneAum` (contributor, member of the `core-team` team) — can be substituted for **any organization owner** and **any organization member in a team that's added as a bypass actor**. Bypass can also be granted by repository role (e.g. "Write") instead of by team; team-scoped is preferred because it limits which org members get the elevated capability.

## Procedure

Both accounts must already be authenticated to `gh` (`gh auth status` lists both). The signing account's YubiKey (or other signing key) must be available locally.

### 1. Owner creates the repo

Done in the GitHub UI or via `gh repo create Atum-Labs/<NEW_REPO> --private`. Members cannot do this step.

### 2. Contributor prepares the signed commit locally (no bypass yet)

```sh
gh auth switch --user geneAum
cd ~/dev/Atum-Labs
git clone git@github.com:Atum-Labs/<NEW_REPO>.git
cd <NEW_REPO>
touch .gitkeep
git add .gitkeep
git commit -m "Initial commit"
git log --show-signature -1   # confirm "Good ... signature"
```

Doing this before the bypass keeps the bypass window short.

### 3. Owner snapshots the ruleset and applies the bypass

```sh
gh auth switch --user gene-atum-admin

# Snapshot — used to restore byte-for-byte in step 5.
gh api /orgs/Atum-Labs/rulesets/13148604 > /tmp/ruleset-13148604.json
jq '{name, target, enforcement, bypass_actors, conditions, rules}' \
   /tmp/ruleset-13148604.json > /tmp/ruleset-noop.json

# Bypass body — core-team (id 13143826) is APPENDED to the existing bypass actors.
# The ruleset already grants bypass to the atum-release-bot app (actor_id 4508958,
# actor_type Integration); `+=` preserves it. Do not use `. + {bypass_actors: [...]}`,
# which replaces the whole array and would silently revoke that app's bypass.
jq '.bypass_actors += [{actor_id: 13143826, actor_type: "Team", bypass_mode: "always"}]' \
   /tmp/ruleset-noop.json > /tmp/ruleset-team-bypass.json

gh api -X PUT /orgs/Atum-Labs/rulesets/13148604 \
   --input /tmp/ruleset-team-bypass.json \
   | jq '{name, bypass_actors}'
```

While this bypass is live, any `core-team` member can push directly to the default branch of any repo without the workflow check or PR review. Move directly to step 4; do not pause.

### 4. Contributor pushes the initial commit

```sh
gh auth switch --user geneAum
cd ~/dev/Atum-Labs/<NEW_REPO>
git push -u origin main
```

A line like `Bypassed rule violations for refs/heads/main: Required workflow 'Verify Commit Signatures'` is expected — it confirms only that one rule was bypassed.

### 5. Owner restores the ruleset

```sh
gh auth switch --user gene-atum-admin
gh api -X PUT /orgs/Atum-Labs/rulesets/13148604 \
   --input /tmp/ruleset-noop.json \
   | jq '{name, bypass_actors, enforcement}'
```

Verify the restore against the step-3 snapshot rather than against any expected literal — the
pre-existing bypass actors are part of the ruleset's normal state, so `[]` is *not* the target:

```sh
gh api /orgs/Atum-Labs/rulesets/13148604 \
   | jq '{name, target, enforcement, bypass_actors, conditions, rules}' > /tmp/ruleset-after.json
diff /tmp/ruleset-noop.json /tmp/ruleset-after.json && echo "restored byte-for-byte"
```

The `core-team` entry should be gone and every other actor left as it was.

## Asking Claude Code to do this

Claude Code can run the whole procedure if both `gh` accounts are authenticated locally. A prompt like:

> I created a new repo at `https://github.com/Atum-Labs/<NEW_REPO>` and the first commit is blocked by the required-workflow rule. Use the procedure in `.github/bootstrap-empty-repo.md` to push a signed `.gitkeep` and revert the bypass.

Touch the YubiKey when prompted for the clone and the push.
