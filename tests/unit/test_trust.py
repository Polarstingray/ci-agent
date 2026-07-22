"""Trust-root consistency (Contract §7).

The single canonical signing key is repman-ci/keys/ci.key; the ci.pub that
clients trust must be its public half, and must match the pinned fingerprint.
These tests catch exactly the drift that previously shipped a distributed ci.pub
(6FC86DD...) that did not match the CI's signing key (7C3341...).
"""
import base64
import hashlib
import os

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
CI_PUB = os.path.join(REPO_ROOT, "ci.pub")            # the distributed trust root
KEYS_PUB = os.path.join(REPO_ROOT, "keys", "ci.pub")  # public half of the signing key
FINGERPRINT = os.path.join(REPO_ROOT, "ci.pub.fingerprint")


def _read_pin():
    pin = {}
    with open(FINGERPRINT) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                pin[k.strip()] = v.strip()
    return pin


def _key_id(pub_path):
    with open(pub_path) as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    raw = base64.b64decode(lines[1])
    return raw[2:10][::-1].hex().upper()


def _sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


class TestTrustRoot:
    def test_distributed_key_matches_signing_key(self):
        # The vendored ci.pub must BE the public half of the signing key.
        with open(CI_PUB) as a, open(KEYS_PUB) as b:
            assert a.read() == b.read(), "ci.pub != keys/ci.pub (trust root drift!)"

    def test_key_id_matches_pin(self):
        assert _key_id(CI_PUB) == _read_pin()["keyid"].upper()

    def test_sha256_matches_pin(self):
        assert _sha256(CI_PUB) == _read_pin()["sha256"].lower()

    def test_fingerprint_matches_repman_copy_if_present(self):
        # The fingerprint file is shared byte-identical with the repman repo.
        repman_fp = os.path.join(REPO_ROOT, "..", "repman", "ci.pub.fingerprint")
        if not os.path.exists(repman_fp):
            return  # sibling repo not checked out; skip
        with open(FINGERPRINT) as a, open(repman_fp) as b:
            assert a.read() == b.read(), "fingerprint files differ across repos"
