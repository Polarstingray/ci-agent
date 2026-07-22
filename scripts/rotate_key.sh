#!/usr/bin/env bash
#
# rotate_key.sh — produce a signed trust-root rotation for repman clients.
#
# Generates a NEW minisign keypair and signs the new public key with the CURRENT
# (old) private key, producing the transition signature that `repman update-key`
# verifies (chain of trust — see PACKAGE_INDEX_CONTRACT.md §7). It then updates
# this repo's vendored ci.pub and ci.pub.fingerprint to the new key.
#
# It does NOT publish. After running, review the changes, publish the new
# `ci.pub` and `ci.pub.minisig` to where PUBKEY_URL / PUBKEY_MINISIG_URL serve
# them, and commit the updated ci.pub + ci.pub.fingerprint in both repos. Only
# then sign future releases with the new key.
#
# Usage:  scripts/rotate_key.sh [--out <dir>]
# Env:    CI_KEY    current (old) minisign secret key   (from config.env)
#         SIG_PASS  passphrase for CI_KEY               (from config.env)
set -euo pipefail

source "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/bootstrap.sh"

OUT_DIR="$WORKING_DIR"
if [[ "${1:-}" == "--out" ]]; then OUT_DIR="$2"; fi

command -v minisign >/dev/null || { echo "minisign not found" >&2; exit 1; }
[[ -f "$CI_KEY" ]] || { echo "current signing key not found: $CI_KEY" >&2; exit 1; }
[[ -n "${SIG_PASS:-}" ]] || { echo "SIG_PASS not set" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NEW_KEY="$TMP/ci.key"
NEW_PUB="$TMP/ci.pub"

echo "Generating new keypair..."
printf '%s\n%s\n' "$SIG_PASS" "$SIG_PASS" | minisign -G -p "$NEW_PUB" -s "$NEW_KEY" >/dev/null

echo "Signing the new public key with the current (old) key (transition signature)..."
printf '%s\n' "$SIG_PASS" | minisign -S -s "$CI_KEY" -m "$NEW_PUB" >/dev/null   # -> $NEW_PUB.minisig

# Derive the new key id + sha256 for the pin.
read -r NEW_ID NEW_SHA < <(
  python3 - "$NEW_PUB" <<'PY'
import base64, hashlib, sys
p = sys.argv[1]
lines = [l.strip() for l in open(p) if l.strip()]
kid = base64.b64decode(lines[1])[2:10][::-1].hex().upper()
sha = hashlib.sha256(open(p, "rb").read()).hexdigest()
print(kid, sha)
PY
)

echo "Installing rotation artifacts to $OUT_DIR ..."
mkdir -p "$OUT_DIR/keys"
cp "$NEW_KEY"           "$OUT_DIR/keys/ci.key"
cp "$NEW_PUB"           "$OUT_DIR/keys/ci.pub"
cp "$NEW_PUB"           "$OUT_DIR/ci.pub"                 # distributed trust root mirror
cp "$NEW_PUB.minisig"   "$OUT_DIR/ci.pub.minisig"         # transition signature to publish
cat > "$OUT_DIR/ci.pub.fingerprint" <<EOF
# Canonical repman-ci signing key fingerprint (minisign).
# The trust root ci.pub in this repo MUST match these values, and MUST be the
# public half of the key repman-ci signs with (repman-ci/keys/ci.key).
# See PACKAGE_INDEX_CONTRACT.md §7. Byte-identical copy in the repman repo.
keyid=$NEW_ID
sha256=$NEW_SHA
EOF

cat <<EOF

Rotation prepared. New key id: $NEW_ID

Next steps:
  1. Publish  $OUT_DIR/ci.pub          -> PUBKEY_URL
             $OUT_DIR/ci.pub.minisig  -> PUBKEY_MINISIG_URL
  2. Copy ci.pub + ci.pub.fingerprint to the repman repo (keep them byte-identical).
  3. Commit both repos. Clients run 'repman update-key' to adopt the new key.
  4. Only AFTER clients have rotated, retire the old key from signing.
EOF
