#!/usr/bin/env bash
#
# cross_repo_install.sh — real, hermetic end-to-end test of the repman-ci ->
# repman seam, with NO GitHub, NO Docker, and NO mocks.
#
# It exercises the actual interface defined in PACKAGE_INDEX_CONTRACT.md:
#
#   repman-ci side (producer):
#     * core/stage.py            — real index.json generation (the format owner)
#     * minisign / tar / sha256  — real signing & packaging (same commands the
#                                  package_sign.sh / sign_index.sh scripts run)
#
#   transport:
#     * a local file:// "release" laid out exactly like GitHub Releases
#       (.../releases/download/<tag>/<asset>), served straight off disk.
#
#   repman side (consumer):
#     * the real librepman.so via the real repcli.py — fetch-key, update,
#       verify, install — with a throwaway XDG_DATA_HOME and HOME.
#
# If this passes, an artifact built and signed by repman-ci installs and runs
# through repman without any manual glue. Everything lives in a temp dir that is
# removed on exit.
#
# Usage:  tests/e2e/cross_repo_install.sh
# Env:    REPMAN_DIR   override path to the repman repo (default: sibling ../repman)
#         KEEP_TMP=1   keep the temp workspace for inspection
set -euo pipefail

CI_DIR="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
REPMAN_DIR="${REPMAN_DIR:-$(cd "$CI_DIR/../repman" 2>/dev/null && pwd || true)}"

PKG_NAME="test"
VERSION="1.0.0"
OS="ubuntu"
ARCH="amd64"
BUILDER="${OS}_${ARCH}"
SIG_PASS="e2e-passphrase"

fail() { echo "  ✗ $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

# ── Preconditions ─────────────────────────────────────────────────────────────
[[ -n "$REPMAN_DIR" && -d "$REPMAN_DIR" ]] || fail "repman repo not found; set REPMAN_DIR"
for tool in minisign tar sha256sum jq; do
    command -v "$tool" >/dev/null || fail "required tool not found: $tool"
done

# Pick a python that has python-dotenv (repcli.py and stage.py both need it).
PY=""
for cand in python3 "$CI_DIR/.venv/bin/python" "$REPMAN_DIR/cli/venv/bin/python" \
            "$HOME/.local/share/repman/cli/venv/bin/python"; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import dotenv' 2>/dev/null; then
        PY="$cand"; break
    fi
done
[[ -n "$PY" ]] || fail "no python3 with python-dotenv found (checked system + venvs)"
ok "using python: $PY"

echo "repman-ci : $CI_DIR"
echo "repman    : $REPMAN_DIR"

# Build librepman.so if absent so we always test against current sources.
if [[ ! -f "$REPMAN_DIR/build/librepman.so" ]]; then
    echo "Building librepman.so ..."
    make -C "$REPMAN_DIR" >/dev/null || fail "failed to build librepman.so"
fi
ok "librepman.so present"

# ── Hermetic workspace ────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
cleanup() { [[ "${KEEP_TMP:-0}" == 1 ]] && { echo "kept: $TMP"; return; }; rm -rf "$TMP"; }
trap cleanup EXIT
[[ "${KEEP_TMP:-0}" == 1 ]] && echo "workspace: $TMP"

RELEASE="$TMP/release"                                    # the file:// "GitHub"
DL_DIR="$RELEASE/releases/download/${PKG_NAME}-v${VERSION}"
INDEX_PUB="$RELEASE/index"
OUT="$TMP/out"
META="$TMP/metadata"
mkdir -p "$DL_DIR" "$INDEX_PUB" "$OUT" "$META"

# ── 1. Generate a throwaway minisign keypair ─────────────────────────────────
printf '%s\n%s\n' "$SIG_PASS" "$SIG_PASS" \
    | minisign -G -p "$TMP/ci.pub" -s "$TMP/ci.key" >/dev/null 2>&1 \
    || fail "minisign keygen failed"

# Pin this throwaway key so fetch-key's fingerprint check is exercised (not
# bypassed): derive its key id and hand repman a matching fingerprint file.
KEYID="$("$PY" - "$TMP/ci.pub" <<'PY'
import base64, sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
print(base64.b64decode(lines[1])[2:10][::-1].hex().upper())
PY
)"
printf 'keyid=%s\n' "$KEYID" > "$TMP/ci.pub.fingerprint"
export REPMAN_FINGERPRINT_FILE="$TMP/ci.pub.fingerprint"
ok "generated throwaway signing key (pinned id $KEYID)"

# ── 2. Produce the index via the REAL repman-ci format owner (core/stage.py) ──
# Point the artifact URL at our local file:// release base. GITHUB_REPO is read
# from the environment first (load_dotenv does not override), so this wins over
# the repo's data/config.env.
export GITHUB_REPO="file://$RELEASE/releases/download"
STAGE_OUT="$(
    "$PY" "$CI_DIR/core/stage.py" "$PKG_NAME" new -b "$BUILDER" \
        --metadata-file "$META/index.json" --out-dir "$OUT"
)"
PKG_BASENAME="$(echo "$STAGE_OUT" | tail -n1)"     # test_v1.0.0_ubuntu_amd64
[[ "$PKG_BASENAME" == "${PKG_NAME}_v${VERSION}_${OS}_${ARCH}" ]] \
    || fail "unexpected package basename: $PKG_BASENAME"
ok "staged index.json via core/stage.py ($PKG_BASENAME)"

# ── 3. Assemble the build output and package it (as package_sign.sh does) ─────
BUILDROOT="$OUT/$PKG_NAME"
mkdir -p "$BUILDROOT/bin" "$BUILDROOT/data"     # mirror test/setup.sh layout
printf '#!/bin/bash\necho "Hello World!"\n' > "$BUILDROOT/bin/program"
chmod +x "$BUILDROOT/bin/program"
printf 'e2e sample data\n' > "$BUILDROOT/data/sample.txt"
cp "$OUT/${PKG_BASENAME}_md.json" "$BUILDROOT/metadata.json"   # contract §6

TARBALL="$DL_DIR/${PKG_BASENAME}.tar.gz"
tar -czf "$TARBALL" -C "$OUT" "$PKG_NAME"
printf '%s\n' "$SIG_PASS" | minisign -S -s "$TMP/ci.key" -m "$TARBALL" >/dev/null 2>&1 \
    || fail "artifact signing failed"
( cd "$DL_DIR" && sha256sum "$(basename "$TARBALL")" > "${TARBALL}.sha256" )
ok "packaged + signed artifact into file:// release layout"

# ── 4. Sign the index (as sign_index.sh does) and publish it to file:// ───────
cp "$META/index.json" "$INDEX_PUB/index.json"
printf '%s\n' "$SIG_PASS" | minisign -S -s "$TMP/ci.key" -m "$INDEX_PUB/index.json" >/dev/null 2>&1 \
    || fail "index signing failed"
( cd "$INDEX_PUB" && sha256sum index.json > index.json.sha256 )
ok "signed + published index.json to file:// release"

# ── 5. Drive the REAL repman client against the file:// release ───────────────
export XDG_DATA_HOME="$TMP/xdg"
export HOME="$TMP/home"
# With XDG_DATA_HOME set, repman uses "$XDG_DATA_HOME/repman" as the install
# prefix (test-isolation: it never touches the real ~/.local). Symlinks land in
# its bin/, lib/, share/.
LOCAL_PREFIX="$XDG_DATA_HOME/repman"
mkdir -p "$LOCAL_PREFIX/bin" "$LOCAL_PREFIX/lib" "$LOCAL_PREFIX/share"
export OS ARCH
export PUBKEY_URL="file://$TMP/ci.pub"
export INDEX_URL="file://$INDEX_PUB/index.json"
export INDEX_SHA256_URL="file://$INDEX_PUB/index.json.sha256"
export INDEX_MINISIG_URL="file://$INDEX_PUB/index.json.minisig"

repman() { "$PY" "$REPMAN_DIR/cli/repcli.py" "$@"; }

repman ensure-dirs >/dev/null 2>&1 || fail "ensure-dirs failed"
repman fetch-key    >/dev/null       || fail "fetch-key failed"
# fetch-key writes the canonical trust root to sig/ci.pub, which every
# verification path (index update, package install, `repman verify`) now reads.
# A fetch-key-only setup is sufficient — no separate key placement needed.
[[ -f "$XDG_DATA_HOME/repman/sig/ci.pub" ]] || fail "fetch-key did not write sig/ci.pub"
ok "repman fetched public key (canonical sig/ci.pub)"

repman update       >/dev/null       || fail "repman update failed (index verify?)"
ok "repman update verified + installed index"

repman verify       >/dev/null       || fail "repman verify failed"
ok "repman verify passed on local index"

repman install "$PKG_NAME" >/dev/null || fail "repman install failed"
ok "repman install succeeded"

# ── 6. Assert the package is really installed and runnable ────────────────────
repman list | grep -q "$PKG_NAME" || fail "installed package not in 'repman list'"
BIN="$LOCAL_PREFIX/bin/program"
[[ -L "$BIN" || -x "$BIN" ]] || fail "binary not symlinked into install prefix bin/"
OUTPUT="$("$BIN")"
[[ "$OUTPUT" == "Hello World!" ]] || fail "installed binary produced: '$OUTPUT'"
ok "installed binary runs: '$OUTPUT'"

echo
echo "E2E PASS: repman-ci artifact built, signed, and installed via repman end-to-end."
