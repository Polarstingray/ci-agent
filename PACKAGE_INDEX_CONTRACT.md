# Package Index Contract

**This file is the single source of truth for the interface between
[`repman-ci`](https://github.com/Polarstingray/repman-ci) (the producer) and
[`repman`](https://github.com/Polarstingray/repman) (the consumer).**

A byte-identical copy lives in both repositories. If you change one, change the
other in the same commit. When code and this document disagree, this document
wins and the code is a bug.

- **Producer:** `repman-ci` builds artifacts, signs them, writes `index.json`,
  and publishes both to GitHub Releases.
- **Consumer:** `repman` fetches `index.json`, resolves an artifact URL, verifies
  it, and installs it.

Everything below is the contract. Neither side may assume anything not stated
here.

---

## 1. Platform identifier (`os_arch`)

A build target is identified by a single lowercase string `"<os>_<arch>"` — the
**os_arch key**. It is used verbatim as:

- the builder name in `repman-ci` (e.g. `ubuntu_amd64`),
- the `targets` map key in `index.json`,
- the `<os>_<arch>` segment of every artifact filename,
- the pair `OS` + `ARCH` in `repman`'s `config.env` (joined with `_`).

The producer's builder and the consumer's `OS`/`ARCH` **must resolve to the same
os_arch string** or the consumer will not find the target.

The machine-readable list of valid identifiers lives in **`platforms.json`**
(byte-identical copy in both repos). Both sides validate against it in their test
suites — the producer asserts every builder definition and its default builder
are in the list; the consumer asserts its default target is. Canonical values:

| os      | arch    | os_arch          |
|---------|---------|------------------|
| ubuntu  | amd64   | `ubuntu_amd64`   |
| ubuntu  | arm64   | `ubuntu_arm64`   |
| arch    | amd64   | `arch_amd64`     |
| debian  | amd64   | `debian_amd64`   |
| alpine  | amd64   | `alpine_amd64`   |
| macos   | arm64   | `macos_arm64`    |
| windows | amd64   | `windows_amd64`  |

---

## 2. Version

Versions are strict three-component semver `MAJOR.MINOR.PATCH`, integers only
(e.g. `1.2.0`). No pre-release or build suffixes. Comparison is numeric,
component by component. The initial version of a newly registered package is
`1.0.0`.

---

## 3. Artifact filename grammar

Given package `name`, `version`, and os_arch parts `os` / `arch`, the canonical
artifact base name is:

```
<name>_v<version>_<os>_<arch>
```

> **Note the separators.** Everything is joined with underscores; the only dash
> is in the literal `_v`. The three published assets are:

```
<name>_v<version>_<os>_<arch>.tar.gz            # the signed tarball
<name>_v<version>_<os>_<arch>.tar.gz.minisig    # its minisign signature
<name>_v<version>_<os>_<arch>.tar.gz.sha256     # its sha256sum output
```

All three are lowercased.

**These names are deterministic and derivable from `name`/`version`/`os`/`arch`
alone.** The consumer derives them itself; the producer MUST emit exactly these
names. The `signature` and `sha256` fields in the index (§5) carry the same
strings and MUST match this derivation — they are an integrity cross-check, not
an alternate source of truth.

The tarball's top-level directory is `<name>/`, and it MUST contain
`<name>/metadata.json` (see §6).

---

## 4. Git tag and release URL

Each release is a GitHub Release on the **packages** repository, tagged:

```
<name>-v<version>
```

> **Note:** the *tag* uses a dash (`<name>-v<version>`); the *artifact filename*
> uses underscores (§3). They are intentionally different. Do not "fix" one to
> match the other.

The three assets for every os_arch target of that version are uploaded to this
one release.

### URL field

The `url` field of a target (§5) MUST be a GitHub release URL in one of two
accepted forms:

```
https://github.com/<owner>/packages/releases/tag/<name>-v<version>        # tag page
https://github.com/<owner>/packages/releases/download/<name>-v<version>   # download base
```

The consumer normalizes `/releases/tag/` → `/releases/download/` and then
appends `/<artifact-filename>` (§3) to fetch each asset. **A `url` that is not a
GitHub release URL is a contract violation and the consumer rejects it.**

`repman-ci` emits the `download` form by default (its `GITHUB_REPO` config value
should end in `/releases/download`). `repman` accepts either form.

---

## 5. `index.json` schema

```json
{
  "<name>": {
    "latest": "<version>",
    "versions": {
      "<version>": {
        "notes": "<optional freeform release notes>",
        "targets": {
          "<os_arch>": {
            "url":       "<github release url, see §4>",
            "signature": "<name>_v<version>_<os>_<arch>.tar.gz.minisig",
            "sha256":    "<name>_v<version>_<os>_<arch>.tar.gz.sha256"
          }
        }
      }
    }
  }
}
```

Field authority:

| Field       | Required | Read by consumer | Notes |
|-------------|----------|------------------|-------|
| `latest`    | yes      | yes              | Highest version; MUST equal the numerically greatest key in `versions`. |
| `versions`  | yes      | yes              | Map of version → entry. |
| `notes`     | no       | no (advisory)    | Human-readable; ignored by install logic. |
| `targets`   | yes      | yes              | Map of os_arch → target. |
| `url`       | yes      | yes              | The only field the consumer needs to locate assets (§4). |
| `signature` | yes      | cross-check only | MUST equal the derived name (§3). |
| `sha256`    | yes      | cross-check only | MUST equal the derived name (§3). |

The consumer derives asset filenames itself (§3); `signature`/`sha256` exist so
the index is self-describing and so a mismatch can be detected. The producer
MUST NOT emit names that differ from the derivation.

---

## 6. `metadata.json` (inside the tarball)

Every tarball contains `<name>/metadata.json`:

```json
{
  "name": "<name>",
  "version": "<version>",
  "os": "<os>",
  "arch": "<arch>",
  "dependencies": {}
}
```

The producer uses `name`/`version` here to compute the tag and release title.

---

## 7. Signing / trust root

- Artifacts and `index.json` are signed with **minisign**.
- The trust root is the public key `ci.pub`. The producer holds the private key
  (`repman-ci/keys/ci.key`); the consumer verifies against `ci.pub`, which MUST
  be the public half of that signing key (`repman-ci/keys/ci.pub`).
- There is exactly **one** authoritative key. Its fingerprint is pinned in
  `ci.pub.fingerprint` (byte-identical in both repos):

  | field    | value |
  |----------|-------|
  | `keyid`  | `7C3341BABBA99FE3` |
  | `sha256` | `dc4fdca59180c5d4af9dfc8ef2766c414529e4f4880efb6a41e326e878059bee` |

- The consumer fetches the key via `repman fetch-key` from `PUBKEY_URL` and
  **verifies its key id against the pinned `keyid`**, refusing (and deleting) any
  key that does not match — so a compromised or misconfigured `PUBKEY_URL` cannot
  swap the trust root. Any `ci.pub` vendored in a repo is a convenience mirror
  and MUST match this fingerprint; both repos' test suites assert it.
- **Consumer key location:** the fetched key lives at `sig/ci.pub` in the data
  dir. This single location is used by index verification, package-install
  verification, and `repman verify` alike.

### Key rotation (chain of trust)

To rotate the trust root, the producer signs the **new** `ci.pub` with the
**old** (currently trusted) private key and publishes two files:

```
ci.pub            # the new public key            -> PUBKEY_URL
ci.pub.minisig    # new ci.pub signed by old key  -> PUBKEY_MINISIG_URL
```

`repman update-key` downloads both, verifies the new key against the key it
**currently** trusts (`sig/ci.pub`), and only then atomically swaps in the new
key and advances its pinned fingerprint. An attacker without the old private key
cannot forge the transition, so the trust root cannot be hijacked. Producer tool:
`repman-ci/scripts/rotate_key.sh`. Retire the old signing key only after clients
have rotated.

## 8. Index distribution

`index.json` is published to the packages repo alongside its detached signature
and checksum:

```
index/index.json
index/index.json.minisig
index/index.json.sha256
```

The consumer's `INDEX_URL`, `INDEX_MINISIG_URL`, and `INDEX_SHA256_URL` point at
these three files (raw). It downloads all three, verifies sha256 **and**
minisign before atomically replacing its local copy.

---

## Changelog discipline

Any change to filename grammar (§3), the URL forms (§4), the index schema (§5),
or the os_arch vocabulary (§1) is a **breaking change to the contract**. It must
be made in both repositories together, and this file updated in the same change.
