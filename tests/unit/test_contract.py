"""Producer-side enforcement of PACKAGE_INDEX_CONTRACT.md.

These tests pin the interface that the `repman` client depends on. If one of
them fails, the producer has drifted from the shared contract — fix the code
(or, if the change is intentional, update PACKAGE_INDEX_CONTRACT.md in *both*
repos and the golden fixture below).
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from core.index import add_version, create_index_mdata, package_name

FIXTURE = os.path.join(
    os.path.dirname(__file__), "..", "fixtures", "contract_index.json"
)

# Contract §1 — os_arch vocabulary
OS_ARCH_RE = re.compile(r"^[a-z]+_[a-z0-9]+$")
# Contract §2 — strict 3-component semver
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
# Contract §4 — accepted GitHub release URL forms
URL_RE = re.compile(
    r"^https://github\.com/[^/]+/[^/]+/releases/(tag|download)/[^/]+-v\d+\.\d+\.\d+$"
)


def _load_fixture():
    with open(FIXTURE) as f:
        return json.load(f)


class TestFilenameGrammar:
    """Contract §3 — deterministic artifact filename grammar."""

    def test_base_uses_underscores_and_lowercase(self):
        assert package_name("MyPkg", "1.2.0", "Ubuntu", "AMD64", 0) == "mypkg_v1.2.0_ubuntu_amd64"

    def test_minisig_name(self):
        assert package_name("affirm", "1.2.0", "ubuntu", "amd64", 1) == "affirm_v1.2.0_ubuntu_amd64.tar.gz.minisig"

    def test_sha256_name(self):
        assert package_name("affirm", "1.2.0", "ubuntu", "amd64", 2) == "affirm_v1.2.0_ubuntu_amd64.tar.gz.sha256"


class TestEmittedTargetConformsToContract:
    """Contract §5 — every field a fresh target emits must satisfy the contract."""

    def _target(self):
        md = {}
        create_index_mdata(
            md, "affirm", "1.2.0", "ubuntu", "amd64",
            url="https://github.com/Polarstingray/packages/releases/download/affirm-v1.2.0",
        )
        return md["affirm"]["versions"]["1.2.0"]["targets"]["ubuntu_amd64"]

    def test_has_exactly_the_contract_fields(self):
        assert set(self._target().keys()) == {"url", "signature", "sha256"}

    def test_signature_matches_deterministic_derivation(self):
        # Contract §3/§5: signature MUST equal the derived name — no drift allowed.
        assert self._target()["signature"] == package_name("affirm", "1.2.0", "ubuntu", "amd64", 1)

    def test_sha256_matches_deterministic_derivation(self):
        assert self._target()["sha256"] == package_name("affirm", "1.2.0", "ubuntu", "amd64", 2)


class TestGoldenFixture:
    """The golden fixture is shared byte-for-byte with the repman repo; it is the
    concrete example both sides validate against."""

    def test_fixture_is_valid_json_and_nonempty(self):
        assert _load_fixture()

    def test_every_target_conforms(self):
        index = _load_fixture()
        for name, pkg in index.items():
            assert SEMVER_RE.match(pkg["latest"]), f"{name}: bad latest"
            # latest MUST be the numerically greatest version key (Contract §5)
            greatest = max(pkg["versions"], key=lambda v: list(map(int, v.split("."))))
            assert pkg["latest"] == greatest, f"{name}: latest != greatest version"
            for version, ventry in pkg["versions"].items():
                assert SEMVER_RE.match(version), f"{name} {version}: bad version key"
                for os_arch, target in ventry["targets"].items():
                    assert OS_ARCH_RE.match(os_arch), f"bad os_arch key {os_arch}"
                    os_, arch = os_arch.split("_", 1)
                    assert URL_RE.match(target["url"]), f"bad url {target['url']}"
                    assert target["signature"] == package_name(name, version, os_, arch, 1)
                    assert target["sha256"] == package_name(name, version, os_, arch, 2)

    def test_add_version_reproduces_fixture_names(self):
        # Rebuilding the fixture package through the real code path must yield the
        # same signature/sha256 names the fixture records.
        index = _load_fixture()
        for name, pkg in index.items():
            for version, ventry in pkg["versions"].items():
                for os_arch, target in ventry["targets"].items():
                    os_, arch = os_arch.split("_", 1)
                    md = {}
                    add_version(md, name, version, os_, arch, url=target["url"])
                    rebuilt = md[name]["versions"][version]["targets"][os_arch]
                    assert rebuilt["signature"] == target["signature"]
                    assert rebuilt["sha256"] == target["sha256"]
