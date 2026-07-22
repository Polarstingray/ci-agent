"""Producer-side enforcement of the shared platform vocabulary (Contract §1).

platforms.json is the machine-readable list of valid os_arch identifiers,
byte-identical to the copy in the repman repo. These tests keep the pipeline's
builder definitions and default configuration inside that vocabulary, so the
producer can never emit a target the consumer's vocabulary does not recognize.
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from core.builders import parse_builder

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
PLATFORMS = os.path.join(REPO_ROOT, "platforms.json")
BUILDERS_DIR = os.path.join(REPO_ROOT, "builders")


def _vocab():
    with open(PLATFORMS) as f:
        return {p["os_arch"]: p for p in json.load(f)["platforms"]}


class TestPlatformVocabulary:
    def test_vocab_entries_are_self_consistent(self):
        # Each entry's os_arch must equal "<os>_<arch>".
        for os_arch, p in _vocab().items():
            assert os_arch == f"{p['os']}_{p['arch']}"

    def test_parse_builder_accepts_every_vocab_entry(self):
        for os_arch, p in _vocab().items():
            assert parse_builder(os_arch) == (p["os"], p["arch"])

    def test_every_builder_definition_is_in_vocabulary(self):
        # Every builders/<name>-builder.yml[.disabled] must name a known platform.
        vocab = _vocab()
        found = []
        for entry in os.listdir(BUILDERS_DIR):
            if "-builder.yml" not in entry:
                continue
            name = entry.split("-builder.yml", 1)[0]
            found.append(name)
            assert name in vocab, f"builder '{name}' is not in platforms.json"
        assert found, "no builder definitions found"

    def test_default_builder_is_in_vocabulary(self):
        # DEFAULT_BUILDER in data/config.env must be a known platform.
        cfg = os.path.join(REPO_ROOT, "data", "config.env")
        default = None
        with open(cfg) as f:
            for line in f:
                line = line.strip()
                if line.startswith("DEFAULT_BUILDER="):
                    default = line.split("=", 1)[1].strip().strip('"').strip("'")
                    break
        assert default is not None, "DEFAULT_BUILDER not set in config.env"
        assert default in _vocab(), f"DEFAULT_BUILDER '{default}' not in platforms.json"
