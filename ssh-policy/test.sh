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
