# YubiKey SSH Key Setup for GitHub Authentication & Commit Signing

This guide covers generating a FIDO2 SSH key on a YubiKey hardware security key,
configuring it for GitHub authentication and commit signing, and enabling
agent-forwarded commit signing on remote development VMs.

## Why this setup?

### Threat model

Traditional SSH keys are files on disk. If your machine is compromised, the attacker
gets your key and can impersonate you indefinitely -- pushing malicious code, signing
commits as you, accessing production infrastructure. You might never know.

With a FIDO2 hardware security key:

- **The private key never leaves the YubiKey.** There is no file to steal. The
  YubiKey performs all cryptographic operations internally.
- **Every operation requires physical touch.** Malware can't silently use your key.
- **Every operation requires your FIDO2 PIN.** Even if someone steals your YubiKey,
  they can't use it without the PIN (and the YubiKey locks after 8 failed attempts).
- **The key handle file is encrypted with a passphrase.** Even if someone copies the
  file from your disk, they can't use it without the passphrase AND the physical
  YubiKey AND the PIN.
- **GitHub can enforce the `sk` key type at the org level.** This ensures every
  member's SSH key is backed by a hardware security key, not just a file.

### Authentication factors

This setup provides defense in depth across multiple factors:

| Factor | What | When required |
|--------|------|---------------|
| **Something you have** | YubiKey (physical device) | Every operation (touch) |
| **Something you know** | FIDO2 PIN | Every operation |
| **Something you know** | Key handle passphrase | Once per session (agent caches it) |

The FIDO2 PIN and passphrase are technically both "something you know," so this is
formally 2-factor authentication with additional defense in depth. In practice, an
attacker needs all three -- plus physical presence to touch the device.

## Prerequisites

### All platforms

- **YubiKey 5 series** (or any FIDO2-capable security key that supports `ed25519-sk`
  resident keys)
- **GitHub CLI** (`gh`)
- **Git 2.34+** -- for SSH-based commit signing

### macOS

Apple's bundled OpenSSH does not include FIDO2 (libfido2) support. You must install
OpenSSH via Homebrew:

```bash
brew install openssh libfido2 ykman
```

Ensure Homebrew's binaries take precedence. Homebrew's installer already adds
this to `~/.zprofile`, which is enough -- don't hardcode a second `PATH` entry,
as the prefix differs per install (`/opt/homebrew`, `/usr/local`, or `~`):

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"  # path as printed by the installer
```

Restart your shell and verify:

```bash
ssh -V            # Should show Homebrew's version, not Apple's
which ssh-keygen  # Should be under $HOMEBREW_PREFIX/bin, not /usr/bin
```

### Linux (Ubuntu/Debian)

The system OpenSSH works. Install the YubiKey management tool:

```bash
sudo apt install yubikey-manager libfido2-1
```

## Step 1: Set a FIDO2 PIN on your YubiKey

If you haven't already, set a FIDO2 PIN. This is stored on the YubiKey itself and is
required for `verify-required` keys:

```bash
ykman fido access change-pin
```

Choose a strong PIN. The YubiKey locks after 8 failed PIN attempts, so it doesn't
need to be extremely long, but it should not be guessable.

## Step 2: Generate the SSH key

Capture your YubiKey's serial number -- this is used to distinguish key files when
you have multiple YubiKeys:

```bash
SERIAL=$(ykman info | grep 'Serial' | awk '{print $NF}')
```

Generate the key:

```bash
ssh-keygen -t ed25519-sk \
  -O resident \
  -O verify-required \
  -O application=ssh:github \
  -C "YOUR_GITHUB_USERNAME@users.noreply.github.com YubiKey:$SERIAL" \
  -f ~/.ssh/id_ed25519_sk_$SERIAL
```

You will be prompted for:

1. **FIDO2 PIN** -- your YubiKey PIN from step 1
2. **Touch** -- physically tap the YubiKey
3. **Passphrase** -- choose a strong passphrase for the key handle file

What the flags mean:

| Flag | Purpose |
|------|---------|
| `-t ed25519-sk` | FIDO2 Ed25519 key (the `sk` suffix = "security key") |
| `-O resident` | Private key is generated and stored inside the YubiKey |
| `-O verify-required` | YubiKey requires PIN for every operation (not just touch) |
| `-O application=ssh:github` | Labels the credential on the YubiKey |
| `-C "..."` | Free-form comment embedded in the public key — the value here (email + serial) is just a convention for identification |
| `-f ~/.ssh/id_ed25519_sk_$SERIAL` | Where to save the key handle file (serial-suffixed for multi-key support) |

## Step 2b: Configure git identity

Set your git identity. Use the same email you used in the `-C` comment in Step 2:

```bash
git config --global user.name "YOUR NAME"
git config --global user.email "YOUR_GITHUB_USERNAME@users.noreply.github.com"
```

## Step 2c: Authenticate the GitHub CLI

Run `gh auth login` and follow the prompts:

1. Select **GitHub.com**
2. Select **SSH** as the preferred protocol for git operations
3. When asked to upload an SSH public key: **Skip** — Step 3 adds the key with
   descriptive titles that include the YubiKey serial number
4. Authenticate via browser

```bash
gh auth login
```

## Step 3: Add the key to GitHub

You need to add the same public key twice -- once for authentication (push/pull) and
once for commit signing:

```bash
# Temporarily grant the GitHub CLI permission to add SSH keys
gh auth refresh -h github.com -s write:public_key -s write:ssh_signing_key

# Add for authentication
gh ssh-key add ~/.ssh/id_ed25519_sk_$SERIAL.pub \
  --title "YubiKey $SERIAL $(ykman info | grep 'Form factor' | cut -d: -f2 | xargs)" \
  --type authentication

# Add for signing
gh ssh-key add ~/.ssh/id_ed25519_sk_$SERIAL.pub \
  --title "YubiKey $SERIAL $(ykman info | grep 'Form factor' | cut -d: -f2 | xargs)" \
  --type signing

# Revoke the extra scopes now that the keys are added
gh auth refresh -h github.com --remove-scopes write:public_key,write:ssh_signing_key
```

## Step 3b: Add your key to the approved signing keys registry

CI validates that every commit is signed by a key in the org's approved signing keys
registry, a private bucket that only the signing-keys admins can edit. Send your
entry to a signing-keys admin (a member of
`gcp--management--signing-keys-admin@atumlabs.xyz`):

```bash
# Generate your registry entry:
echo "$(git config user.email) $(cat ~/.ssh/id_ed25519_sk_$SERIAL.pub)"
```

Send them the output. You can verify the entry is correct by checking the
fingerprint:

```bash
ssh-keygen -lf ~/.ssh/id_ed25519_sk_$SERIAL.pub
```

The first command outputs your full registry entry (email + public key). The second
prints a short fingerprint you can use to visually confirm it matches the key shown
on your [GitHub SSH keys page](https://github.com/settings/keys).

## Step 3c: Authorize key for SSO

GitHub requires SSH keys to be authorized for each SSO-enabled organization.

1. Go to <https://github.com/settings/keys>
2. Find the key you just added
3. Click **Configure SSO** → **Authorize** next to **Atum-Labs**

Repeat this for both the signing and authentication entries if they appear
separately.

## Multiple YubiKeys?

Repeat Steps 1–3c for each additional YubiKey. Each key gets its own file
(distinguished by serial number) and its own GitHub/SSO registration. Steps 4
onward configure your primary YubiKey for daily use — update the file paths if
you switch to a different key.

## Step 4: Configure git for SSH commit signing

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519_sk_SERIAL.pub
git config --global commit.gpgsign true
git config --global tag.gpgsign true
```

Replace `SERIAL` with your primary YubiKey's serial number in the path above.

For local signature verification, set up an allowed signers file:

```bash
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
echo "YOUR_EMAIL $(cat ~/.ssh/id_ed25519_sk_SERIAL.pub)" > ~/.ssh/allowed_signers
```

Replace `YOUR_EMAIL` with your git email (e.g.,
`yourname@users.noreply.github.com`). If you have multiple YubiKeys, add an entry
for each key so signatures from any of them verify locally.

# Revised sections for macOS YubiKey SSH setup

## Step 5: Configure SSH

Create the required directories first:

```bash
mkdir -p ~/.ssh/agent ~/.ssh/sockets ~/.local/bin
chmod 700 ~/.ssh ~/.ssh/agent ~/.ssh/sockets
```

### `~/.ssh/config`

Use this configuration:

```sshconfig
Host *
  AddKeysToAgent no

Host github.com
  Hostname ssh.github.com
  Port 443
  IdentityAgent ~/.ssh/agent/ssh-agent.sock
  IdentityFile ~/.ssh/id_ed25519_sk_SERIAL
  IdentitiesOnly yes
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h-%p
  ControlPersist 600
```

Replace `SERIAL` with your YubiKey serial number.

### Why this differs from the original

- `IdentityAgent ~/.ssh/agent/ssh-agent.sock` forces GitHub SSH traffic to use the exact agent socket you control.
- `IdentitiesOnly yes` ensures SSH only offers the configured YubiKey-backed identity.
- `AddKeysToAgent no` avoids implicit key-loading behavior that can make debugging inconsistent.
- `ControlMaster` and `ControlPersist 600` keep one authenticated SSH connection open for 10 minutes so repeated Git operations do not keep re-prompting.

### Set the git remote protocol to SSH

```bash
gh config set git_protocol ssh --host github.com
```

If your repo currently uses HTTPS, switch it:

```bash
git remote set-url origin git@github.com:YOUR_ORG/YOUR_REPO.git
```

Verify:

```bash
git remote -v
```

Expected form:

```bash
origin  git@github.com:YOUR_ORG/YOUR_REPO.git (fetch)
origin  git@github.com:YOUR_ORG/YOUR_REPO.git (push)
```

---

## Step 6: SSH agent setup on macOS

Apple’s default SSH agent path is not reliable for this FIDO2/YubiKey workflow. Use Homebrew’s `ssh-agent` under `launchd` with a fixed socket and explicit askpass handling.

### 6.1 Create the askpass helper

```bash
cat > ~/.local/bin/ssh-askpass <<'EOF'
#!/bin/bash
# Prompt goes through the environment: OpenSSH's prompt contains double quotes
# (Enter passphrase for "/path/to/key":) which would break an -e string literal.
SSH_ASKPASS_PROMPT_TEXT="${1:-Enter passphrase:}" exec /usr/bin/osascript <<'APPLESCRIPT'
set promptText to system attribute "SSH_ASKPASS_PROMPT_TEXT"
display dialog promptText default answer "" with hidden answer buttons {"OK"} default button "OK"
return text returned of result
APPLESCRIPT
EOF

chmod 700 ~/.local/bin/ssh-askpass
```

### 6.2 Create the launch agent

```bash
mkdir -p ~/Library/LaunchAgents

BREW_PREFIX="$(brew --prefix)"

# Unquoted heredoc: ${BREW_PREFIX} and ${HOME} are expanded into the plist.
cat > ~/Library/LaunchAgents/com.homebrew.ssh-agent.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.homebrew.ssh-agent</string>

  <key>LimitLoadToSessionType</key>
  <array>
    <string>Aqua</string>
  </array>

  <key>ProgramArguments</key>
  <array>
    <string>${BREW_PREFIX}/bin/ssh-agent</string>
    <string>-D</string>
    <string>-a</string>
    <string>${HOME}/.ssh/agent/ssh-agent.sock</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>EnvironmentVariables</key>
  <dict>
    <key>SSH_AUTH_SOCK</key>
    <string>${HOME}/.ssh/agent/ssh-agent.sock</string>
    <key>SSH_ASKPASS</key>
    <string>${HOME}/.local/bin/ssh-askpass</string>
    <key>SSH_ASKPASS_REQUIRE</key>
    <string>force</string>
    <key>PATH</key>
    <string>${BREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
EOF
```

Nothing needs substituting by hand. If `launchctl kickstart -k` later appears to
hang, the plist names a program that does not exist -- check `ProgramArguments`
against `brew --prefix`.

### 6.3 Export the same socket in your shell

Add this to `~/.zshrc`:

```bash
export SSH_AUTH_SOCK="$HOME/.ssh/agent/ssh-agent.sock"
export SSH_ASKPASS="$HOME/.local/bin/ssh-askpass"
export SSH_ASKPASS_REQUIRE=force
```

Then reload your shell:

```bash
source ~/.zshrc
```

### 6.4 Start or restart the Homebrew agent cleanly

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.homebrew.ssh-agent.plist 2>/dev/null || true
rm -f ~/.ssh/agent/ssh-agent.sock
rm -f ~/.ssh/sockets/*
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.homebrew.ssh-agent.plist
launchctl kickstart -k gui/$(id -u)/com.homebrew.ssh-agent
```

### 6.5 Load your key into the agent

After login, or after restarting the agent, load the key once:

```bash
ssh-add ~/.ssh/id_ed25519_sk_SERIAL
```

This should prompt for the **key handle passphrase** once per session. The YubiKey PIN and touch are still required during actual signing/auth operations.

If you want to clear all loaded identities first:

```bash
ssh-add -D
ssh-add ~/.ssh/id_ed25519_sk_SERIAL
```

---

## Step 7: Verify everything works

### 7.1 Confirm the correct binaries and socket are in use

```bash
which ssh
which ssh-add
which ssh-agent
ssh -V
echo $SSH_AUTH_SOCK
```

Expected pattern:

- `ssh`, `ssh-add`, `ssh-agent` should point to `$HOMEBREW_PREFIX/bin/...`
- `SSH_AUTH_SOCK` should be `~/.ssh/agent/ssh-agent.sock`

### 7.2 Check the agent has the key loaded

```bash
ssh-add -L
```

You should see your `sk-ssh-ed25519@openssh.com ...` public key listed.

### 7.3 Test SSH authentication to GitHub

Before testing, clear any stale multiplexed connection:

```bash
ssh -O exit git@github.com 2>/dev/null || true
rm -f ~/.ssh/sockets/*
```

Now test:

```bash
ssh -T git@github.com
```

Expected result:

```text
Hi USERNAME! You've successfully authenticated, but GitHub does not provide shell access.
```

### 7.4 Test Git access

```bash
git fetch origin
```

Or clone a repo:

```bash
git clone git@github.com:YOUR_ORG/YOUR_REPO.git
```

### 7.5 Test commit signing

```bash
git checkout -b test-yubikey-signing
git commit --allow-empty -m "test: verify YubiKey commit signing"
git log --show-signature -1
```

Expected result: a valid SSH signature using your `ED25519-SK` key.

---

## Day-to-day workflow

### What you should experience

| Action | Prompts |
|---|---|
| First `ssh-add` after login | Key handle passphrase |
| First `git push` / `git pull` / `git clone` | YubiKey PIN + touch |
| `git commit` with signing enabled | YubiKey PIN + touch |
| Additional GitHub SSH operations within 10 min | Usually no prompt due to connection multiplexing |

### Normal daily use

After logging into your Mac and opening a terminal:

```bash
ssh-add ~/.ssh/id_ed25519_sk_SERIAL
```

After that, use Git normally.

---

## Troubleshooting

### `sign_and_send_pubkey: signing failed ... from agent: agent refused operation`

This usually means the key is loaded into the agent, but the agent workflow is not able to complete the FIDO2 signing operation correctly.

Use the macOS setup above and then reset the session:

```bash
ssh -O exit git@github.com 2>/dev/null || true
rm -f ~/.ssh/sockets/*
ssh-add -D
ssh-add ~/.ssh/id_ed25519_sk_SERIAL
ssh -T git@github.com
```

### Git still prompts for username/password

Your repo is still using an HTTPS remote. Check:

```bash
git remote -v
```

If you see `https://github.com/...`, switch it:

```bash
git remote set-url origin git@github.com:YOUR_ORG/YOUR_REPO.git
```

### Key works when bypassing the agent, but not through the agent

Verify:

```bash
echo $SSH_AUTH_SOCK
ssh-add -L
launchctl print gui/$(id -u)/com.homebrew.ssh-agent
```

Ensure:

- your shell uses `~/.ssh/agent/ssh-agent.sock`
- `ssh-add -L` shows the correct `sk` key
- the launch agent environment includes:
  - `SSH_AUTH_SOCK`
  - `SSH_ASKPASS`
  - `SSH_ASKPASS_REQUIRE=force`

### Authentication succeeds with `ssh -T`, but Git still fails

If `ssh -T git@github.com` succeeds, the SSH auth path is working. Any remaining Git failure is likely one of:

- wrong remote URL
- missing repo access
- repo does not exist
- org SSO authorization not completed for the SSH key

---

## Notes for the guide

The original macOS agent section failed because it relied on a looser setup:

- socket under `/tmp`
- no `IdentityAgent` pinning in `~/.ssh/config`
- no deterministic `launchd` environment for askpass
- `AddKeysToAgent yes`, which makes the session less predictable

## Step 8: Remote VM setup (commit signing via agent forwarding)

When developing on remote VMs, you can sign commits using your local YubiKey via SSH
agent forwarding. The signing operation is forwarded back to your local machine, where
the YubiKey performs the cryptographic operation (PIN + touch happen locally).

### Requirements

- **OpenSSH 9.6+** on the remote VM (for `ssh-keygen -Y sign -U`, which routes
  signing through the SSH agent)
- `ForwardAgent yes` in your SSH config for the VM host

### On the remote VM

1. Upgrade OpenSSH to 9.6+ if needed.

2. Copy your public key to the VM:

```bash
scp ~/.ssh/id_ed25519_sk_SERIAL.pub your-vm:~/.ssh/id_ed25519_sk_SERIAL.pub
```

3. SSH into the VM and configure git:

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519_sk_SERIAL.pub
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
echo "YOUR_EMAIL $(cat ~/.ssh/id_ed25519_sk_SERIAL.pub)" > ~/.ssh/allowed_signers
```

4. Create a signing wrapper that uses the forwarded agent:

```bash
mkdir -p ~/bin
cat > ~/bin/ssh-sign-agent << 'SCRIPT'
#!/bin/bash
# Wrapper around ssh-keygen that adds -U flag to route signing
# through the SSH agent (for FIDO2 keys via agent forwarding)
exec /usr/bin/ssh-keygen -U "$@"
SCRIPT
chmod +x ~/bin/ssh-sign-agent
```

5. Configure git to use the wrapper:

```bash
git config --global gpg.ssh.program ~/bin/ssh-sign-agent
```

### How it works

When you `git commit` on the remote VM:

1. Git calls the signing wrapper with the public key
2. The wrapper invokes `ssh-keygen -Y sign -U`, which asks the SSH agent to sign
3. The agent request is forwarded back to your local machine via the SSH connection
4. Your local ssh-agent performs the FIDO2 operation on the YubiKey
5. You see a PIN prompt and touch the YubiKey on your local machine
6. The signature is sent back through the forwarded agent to the remote VM
7. Git attaches the signature to the commit

### SSH config for VMs

Ensure `ForwardAgent yes` is set for your VM hosts:

```
Host my-dev-vm
    HostName <ip>
    User <username>
    IdentityFile ~/.ssh/<vm-access-key>
    ForwardAgent yes
```

## Day-to-day workflow

### What you'll experience

| Action | Prompts |
|--------|---------|
| First `ssh-add` after login | Passphrase (once per session) |
| `git push` / `git pull` | PIN + touch (once per 10 min with multiplexing) |
| `git commit` (signing) | PIN + touch |
| Subsequent git operations within 10 min | No prompts (multiplexed connection) |

### If your YubiKey is unplugged

SSH and git operations that require the key will fail with a clear error. Plug in the
YubiKey and retry.

### Recovering the key on a new machine

Because the key was generated with `-O resident`, it is stored on the YubiKey itself.
To extract the key handle on a new machine:

```bash
ssh-keygen -K
```

This downloads all resident credentials from the YubiKey. You'll need your FIDO2 PIN.

## GitHub org policy

To enforce hardware security keys across the org, a GitHub org admin should:

1. Go to **Organization Settings > Authentication security**
2. Under **SSH keys**, require the `sk` key type
3. This ensures members can only add `ecdsa-sk` or `ed25519-sk` keys, which
   require a hardware security key

Note: GitHub cannot enforce that the YubiKey has a PIN set or that the key handle
file has a passphrase. Those are local properties. The `-O verify-required` flag sets
a FIDO2 credential attribute that makes the YubiKey itself refuse to operate without
PIN verification -- this is enforced by the hardware, not by GitHub. The org should
document that keys must be generated with `-O verify-required` as part of this
security policy.

## Troubleshooting

### "agent refused operation"

Your SSH agent doesn't support FIDO2. You're probably using GNOME Keyring (Linux) or
Apple's built-in agent (macOS). Follow the agent setup in Step 6.

### "No such file or directory" when signing commits

Your `user.signingkey` git config should point to the public key **file path**, not a
`key::` literal:

```bash
git config --global user.signingkey ~/.ssh/id_ed25519_sk_SERIAL.pub
```

### Multiple PIN/touch prompts during fetch with submodules

Add SSH connection multiplexing to your `~/.ssh/config` (see Step 5). This reuses a
single authenticated connection.

### "Key enrollment failed: invalid format" (macOS)

You're using Apple's bundled `ssh-keygen` which lacks libfido2 support. Install
Homebrew's OpenSSH:

```bash
brew install openssh libfido2
```

And ensure Homebrew's binaries are first in your `PATH`.

### Key works without agent but not through agent

Verify you're using the correct agent socket:

```bash
echo $SSH_AUTH_SOCK
ssh-add -L  # Should list your sk key
```

If the socket points to GNOME Keyring (`/run/user/.../keyring/ssh`) or Apple's agent,
switch to the replacement agent as described in Step 6.
