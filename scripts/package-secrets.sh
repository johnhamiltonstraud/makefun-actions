#!/usr/bin/env bash
# package-secrets.sh — build credentials.tar.gz.gpg for the Actions repo.
# Runs ONLY on the VM, by hand. Reads mode-600 keypair files, encrypts them
# with a passphrase (generated once, stored OUTSIDE the repo at
# ~/workspace/makefun-actions-passphrase.txt, mode 600). Prints NO secret,
# NO passphrase, NO key material — only OK/FAIL and file names.
# Usage: package-secrets.sh [wallet numbers...]   (default: 210)
# The archive is committed to the PRIVATE repo; the passphrase is set as a
# GitHub Secret by deploy.sh. Re-run to add more wallets (it rebuilds the
# whole archive from the keypair files on disk).
set -euo pipefail
REPO="$HOME/workspace/makefun-actions"
PASS_FILE="$HOME/workspace/makefun-actions-passphrase.txt"
WALLETS="${*:-210}"
if [ ! -f "$PASS_FILE" ]; then
  openssl rand -base64 32 | tr -d '\n' > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  echo "generated new passphrase file (mode 600, kept OUTSIDE the repo): $PASS_FILE"
fi
chmod 600 "$PASS_FILE"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
for N in $WALLETS; do
  KP="$HOME/workspace/your_files/eoa-testnet-wallets/makefun-keypairs/wallet-$N.json"
  [ -f "$KP" ] || { echo "FAIL: no keypair for wallet $N: $KP" >&2; exit 1; }
  cp "$KP" "$STAGE/keypair-wallet-$N.json"; chmod 600 "$STAGE/keypair-wallet-$N.json"
  CR="$HOME/workspace/makefun-work/credentials-wallet-$N.json"
  if [ -f "$CR" ]; then cp "$CR" "$STAGE/credentials-wallet-$N.json"; chmod 600 "$STAGE/credentials-wallet-$N.json"; fi
done
tar czf "$STAGE/credentials.tar.gz" -C "$STAGE" $(cd "$STAGE" && ls keypair-*.json credentials-*.json 2>/dev/null)
gpg --batch --yes --quiet --passphrase-file "$PASS_FILE" \
  --symmetric --cipher-algo AES256 \
  --output "$REPO/credentials.tar.gz.gpg" "$STAGE/credentials.tar.gz"
chmod 600 "$REPO/credentials.tar.gz.gpg"
# Verify round-trip silently (compare bytes, print only OK/FAIL).
VERIFY="$(mktemp -d)"; trap 'rm -rf "$STAGE" "$VERIFY"' EXIT
gpg --batch --yes --quiet --passphrase-file "$PASS_FILE" \
  --output "$VERIFY/credentials.tar.gz" --decrypt "$REPO/credentials.tar.gz.gpg"
if cmp -s "$STAGE/credentials.tar.gz" "$VERIFY/credentials.tar.gz"; then
  echo "OK archive verified: $REPO/credentials.tar.gz.gpg (wallets: $WALLETS)"
else
  echo "FAIL: archive round-trip mismatch" >&2; exit 1
fi
