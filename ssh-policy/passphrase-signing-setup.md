# SSH Commit Signing Setup (Passphrase-Protected Key)

This guide covers the **passphrase-protected ed25519 key** path for team
members who do not yet have a YubiKey. If you have a YubiKey, follow the
[YubiKey signing setup guide](https://github.com/Atum-Labs/atum-gists/blob/main/yubikey-signing-setup.md)
instead.

All commits to Atum-Labs repositories must be signed with an approved SSH
key. The approved keys live in a private bucket that only the signing-keys
admins can edit; CI rejects commits that are unsigned
or signed with an unapproved key. YubiKey-backed keys are preferred;
passphrase-protected ed25519 keys are the accepted alternative.

Because passphrase protection cannot be verified in CI, each developer using
this path must complete a screen-shared demo call to prove their key is
passphrase-protected (see
[Passphrase verification call](#passphrase-verification-call)).

---

## Prerequisites

- **git** (any recent version)
- **gh** — the [GitHub CLI](https://cli.github.com/)
- **ssh-keygen** (ships with OpenSSH on macOS and Linux)

## 1. Generate an ed25519 key with a passphrase

```bash
ssh-keygen -t ed25519 -C "$(git config user.email)" -f ~/.ssh/id_ed25519_signing
```

When prompted, **enter a non-empty passphrase**. A passphrase-less key will
not pass the verification call.

## 2. Configure git for SSH commit signing

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519_signing.pub
git config --global commit.gpgsign true
```

Make sure your name and email are set. Use your GitHub noreply address so
your email stays private:

```bash
git config --global user.name "Your Name"
git config --global user.email "<ID>+<USERNAME>@users.noreply.github.com"
```

You can find your GitHub noreply email at
<https://github.com/settings/emails> (look for the
`<ID>+<USERNAME>@users.noreply.github.com` line).

## 3. Add key to GitHub

Add the key as both a **signing** key and an **authentication** key:

```bash
gh ssh-key add ~/.ssh/id_ed25519_signing.pub --title "signing key" --type signing
gh ssh-key add ~/.ssh/id_ed25519_signing.pub --title "signing key" --type authentication
```

## 4. Authorize key for SSO

GitHub requires SSH keys to be authorized for each SSO-enabled organization.

1. Go to <https://github.com/settings/keys>
2. Find the key you just added
3. Click **Configure SSO** → **Authorize** next to **Atum-Labs**

Repeat this for both the signing and authentication entries if they appear
separately.

## 5. Configure local signature verification (optional)

To verify your own signatures locally (e.g. with `git log --show-signature`),
create an `allowed_signers` file with your key:

```bash
echo "$(git config user.email) $(cat ~/.ssh/id_ed25519_signing.pub)" > ~/.ssh/allowed_signers
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
```

## 6. Request approval for your key

Send your entry to a signing-keys admin (a member of
`gcp--management--signing-keys-admin@atumlabs.xyz`). Each entry follows the
SSH `allowed_signers` format:

```
<email> <key-type> <base64-key> <comment>
```

Generate your entry:

```bash
echo "$(git config user.email) $(cat ~/.ssh/id_ed25519_signing.pub)"
```

Send the output **before** the demo call so the reviewer can cross-reference
the key you sent with the key shown live.

## 7. Passphrase verification call

A reviewer will schedule a short screen-shared call with you. During the
call you will run the script below while sharing your screen. The reviewer
will:

1. Confirm the public key displayed matches the key you sent
2. Watch you sign a test file — the prompt for a passphrase proves the key
   is protected
3. Confirm the signature verifies successfully

After the call, the reviewer adds your key to the approved signing keys.

### Demonstration script

Copy and paste this entire block into your terminal during the call:

```bash
#!/usr/bin/env bash
set -euo pipefail

KEY="${HOME}/.ssh/id_ed25519_signing"
EMAIL="$(git config user.email)"

echo "=== Public key (allowed_signers format) ==="
echo "${EMAIL} $(cat "${KEY}.pub")"
echo ""

echo "=== Key fingerprint ==="
ssh-keygen -lf "${KEY}.pub"
echo ""

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "test data" > "${tmpdir}/testfile"

echo "=== Signing (you will be prompted for your passphrase) ==="
SSH_AUTH_SOCK= ssh-keygen -Y sign -f "${KEY}" -n git "${tmpdir}/testfile"
echo ""

echo "=== Verifying signature ==="
echo "${EMAIL} $(cat "${KEY}.pub")" > "${tmpdir}/allowed_signers"
ssh-keygen -Y verify \
  -f "${tmpdir}/allowed_signers" \
  -I "${EMAIL}" \
  -n git \
  -s "${tmpdir}/testfile.sig" \
  < "${tmpdir}/testfile"
```

The `SSH_AUTH_SOCK=` prefix ensures the signing command reads the key file
directly instead of using a cached agent (including macOS Keychain), so the
passphrase prompt is always triggered.
