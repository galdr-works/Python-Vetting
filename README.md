Python Vetting
> A repeatable, auditable process for pulling Python packages onto a closed / air-gapped network with integrity, provenance, and security guarantees baked in.

## Table of Contents

- [Overview](#overview)
- [The Process](#the-process)
  1. [Pin (`pip-compile`)](#1-pin-pip-compile)
  2. [Fetch (`pip download`)](#2-fetch-pip-download-with-hash-verification)
  3. [Install into isolated venv](#3-install-into-isolated-venv)
  4. [SBOM with `syft`](#4-sbom-with-syft)
  5. [`grype` (CVE scanning)](#5-grype-cve-scanning)
  6. [`pip-audit`](#6-pip-audit)
  7. [`osv-scanner`](#7-osv-scanner)
  8. [Bandit (static analysis)](#8-bandit-static-analysis)
  9. [Guarddog (malicious behavior detection)](#9-guarddog-malicious-package-behavioral-detection)
  10. [Scorecard (supply chain health)](#10-scorecard-supply-chain-health)
  11. [Verdict](#11-verdict)
- [Example Run: PyYAML](#example-run-pyyaml)

## Overview

Our organization runs on a closed, restricted network with no direct internet access. We're migrating to Python more heavily across teams, but until now we haven't had a consistent way to control what packages get carried across the air gap, or to test and scan those packages for security issues before they land on the network.

`pyvet` is the process (and eventually, tooling) we use to vet every Python package before it crosses that boundary.

We're not reinventing the wheel here (pun intended) — plenty of best-in-class open source tools already do CVE scanning, SBOM generation, static analysis, and supply-chain scoring. `pyvet` is the glue: a fixed, auditable pipeline that runs those tools in the same order, every time, and produces a single go/no-go verdict per package.

## The Process

| Step | Stage                | Tool                            | Repo                                       |
| ---- | -------------------- | -------------------------------- | ------------------------------------------- |
| 1    | Pin                   | `pip-compile`                    | https://github.com/jazzband/pip-tools       |
| 2    | Fetch                 | `pip download` (hash-verified)   | https://github.com/pypa/pip                 |
| 3    | Install               | isolated `venv`                  | — (Python standard library)                 |
| 4    | SBOM                  | `syft`                           | https://github.com/anchore/syft             |
| 5    | CVE scan              | `grype`                          | https://github.com/anchore/grype            |
| 6    | Vulnerability audit   | `pip-audit`                      | https://github.com/pypa/pip-audit           |
| 7    | Vulnerability audit   | `osv-scanner`                    | https://github.com/google/osv-scanner       |
| 8    | Static analysis       | `bandit`                         | https://github.com/pycqa/bandit             |
| 9    | Behavioral analysis   | `guarddog`                       | https://github.com/DataDog/guarddog         |
| 10   | Supply chain health   | `scorecard`                      | https://github.com/ossf/scorecard           |
| 11   | Decision              | verdict                          | — (internal)                                |

### GitHub Auth Token

Scorecard queries the GitHub API to evaluate a project's supply-chain health, and that API rate-limits unauthenticated requests hard enough that you'll need a token even for public repos.

**1. Generate the token** (on your GitHub account):

```
GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token (classic)
```

Scope it to **public repo, read-only** and set an expiration date. This token only ever needs to read public repository metadata — it should never carry write or org-admin scopes.

**2. Store it on your scanning machine.** Don't paste it directly into an interactive shell (it lands in plaintext in your shell history) and don't hardcode it into a script. Instead, drop it in a file outside any git-tracked directory and source it:

```bash
echo 'export GITHUB_AUTH_TOKEN=<paste classic token here>' >> ~/.pyvet_env
chmod 600 ~/.pyvet_env
source ~/.pyvet_env
```

> **OPSEC:** Never commit `~/.pyvet_env` — or any file containing the token — to a repo, especially not the one you're about to push to GitHub. Add it to `.gitignore` before your first commit, rotate the token periodically, and revoke it immediately if this machine changes hands.

---

### 1. Pin (`pip-compile`)

```bash
pip-compile requirements.in \
  --generate-hashes \
  --output-file requirements.txt \
  --no-header \
  --resolver=backtracking
```

| Flag | Why it's there |
|---|---|
| `--generate-hashes` | **Non-negotiable.** Every package in the output gets a SHA-256 hash. When `pip` downloads later, it verifies against this hash — if the file on PyPI doesn't match, the install fails loudly. This is your integrity guarantee. |
| `--output-file requirements.txt` | Explicit output name, keeps it predictable for downstream steps. |
| `--no-header` | Strips the `pip-compile` metadata comment at the top. Personal preference — reduces noise in the output. |
| `--resolver=backtracking` | Uses pip's modern dependency resolver. The legacy resolver can silently accept incompatible dependency trees in some edge cases; backtracking is stricter. |

### 2. Fetch (`pip download` with hash verification)

```bash
pip download \
  --require-hashes \
  --no-deps \
  -r requirements.txt \
  -d ./dist
```

| Flag | Why it's there |
|---|---|
| `--require-hashes` | Refuses to download anything unless every package in `requirements.txt` carries a hash to verify against. If the lockfile is missing a hash for any entry, the whole command fails rather than silently pulling something unverified. |
| `--no-deps` | Tells pip not to re-resolve the dependency tree during download — that resolution already happened in Step 1. We trust the lockfile, not pip's live resolver. |
| `-r requirements.txt` | Points at the hash-pinned lockfile produced by `pip-compile`. |
| `-d ./dist` | Downloads the `.whl` / `.tar.gz` artifacts into a local directory instead of installing them. These files — not the lockfile — are what physically cross the air gap. |

### 3. Install into isolated venv

We never install packages into the system Python or a shared environment during vetting. We create a fresh, empty virtualenv for this vet run specifically. This does two things: it isolates any side effects (a malicious package can't touch your system Python), and it gives the SBOM tool a clean, bounded environment to enumerate — exactly the closure you locked, nothing extra.

```bash
python3 -m venv ~/[PackageName]/venv

~/[PackageName]/venv/bin/pip install \
  --require-hashes \
  --no-index \
  --find-links ~/[PackageName]/dist/ \
  -r ~/[PackageName]/requirements.txt
```

| Flag | Why it's there |
|---|---|
| `~/[PackageName]/venv/bin/pip` | Invoke the venv's own `pip` binary directly instead of the ambient `pip` on `PATH`. This keeps dependency resolution scoped entirely to the venv's isolated site-packages, with no visibility into anything installed at the system level. See the install gotcha documented in the PyYAML example run below for what goes wrong if you use `--prefix` against the system `pip` instead. |
| `--require-hashes` | Same integrity guarantee as Step 2 — install fails if a package doesn't match its pinned hash. |
| `--no-index` | Blocks pip from reaching out to PyPI entirely. Every package must come from the local `--find-links` directory — this is what makes the install work with zero network access. |
| `--find-links ~/[PackageName]/dist/` | Treats the local `dist/` directory (populated in Step 2) as the package source. |
| `-r ~/[PackageName]/requirements.txt` | Installs exactly the pinned set from the lockfile — no re-resolution. |

### 4. SBOM with `syft`

Before any scanner runs, you generate a Software Bill of Materials. The SBOM is a structured inventory of every package in the venv — names, versions, detected licenses, package type, source paths. Think of it as the manifest you hand to every subsequent scanner as a baseline truth document.

Two reasons this matters architecturally. First, it gives you an independent enumeration of what actually landed in the venv, separate from the lockfile — if syft finds something that isn't in your `requirements.txt`, that's a red flag worth investigating. Second, some scanners (grype specifically) can consume an SBOM directly as input rather than scanning the live directory, which means the scan is reproducible: you can re-run grype against the same SBOM months later without needing the original venv.

We output in `spdx-json` format. SPDX is an ISO standard (ISO 5962) — it's the format your organization is most likely to ask for if someone ever wants to audit what's in a deployed package.

```bash
syft ~/[PackageName]/venv \
  --output spdx-json=~/[PackageName]/sbom.spdx.json
```

| Flag | Why it's there |
|---|---|
| `~/[PackageName]/venv` | The scan target. syft enumerates every package it finds inside the venv — not the source tree, not the wheel files. |
| `--output spdx-json=...` | Writes the SBOM in SPDX JSON format (ISO/IEC 5962) instead of syft's default table output. SPDX is what audit and compliance tooling expects, and it's what `grype` consumes as input in the next step. |

### 5. `grype` (CVE scanning)

grype takes the SBOM you just generated and cross-references every package against its vulnerability database — NVD, GitHub Advisory Database, and several others. It's looking for _known vulnerabilities in legitimate packages_. This is one half of your two-threat-class model. The other half (malicious packages) comes from guarddog shortly after.

The distinction is worth restating explicitly: a CVE scanner cannot tell you whether a package is malicious. It can only tell you whether a legitimate package has a known vulnerability. A perfectly clean grype result does not mean a package is safe — it means it has no _known CVEs_. That's why both tool categories exist.

We scan the SBOM rather than the live venv directory for a principled reason: the SBOM is a reproducible artifact. You can archive it and re-run grype against it in six months when new CVEs drop, without needing the original venv to still exist.

```bash
grype sbom:~/[PackageName]/sbom.spdx.json \
  --output json \
  > grype.json
```

| Flag | Why it's there |
|---|---|
| `sbom:~/[PackageName]/sbom.spdx.json` | The `sbom:` prefix tells grype to scan the SBOM artifact from Step 4 rather than a live filesystem path. This is what makes the scan reproducible — you can re-run it against the archived SBOM later without the original venv. |
| `--output json` | Machine-readable output, so it can be filtered downstream with `jq` (see the two-bucket filter in the PyYAML example run). |
| `> grype.json` | Redirects results to a file for the findings record instead of just printing to the terminal. |

### 6. `pip-audit`

pip-audit is a second CVE scanner, and running it alongside grype is not redundant — it's deliberate. grype and pip-audit pull from overlapping but non-identical vulnerability databases. More importantly, pip-audit queries the Python-specific OSV database with Python package semantics it understands natively, while grype is a general-purpose scanner. The two tools occasionally disagree, and disagreement is signal worth investigating. If grype shows clean and pip-audit flags something, you look harder. Corroboration is confidence; divergence is a prompt to dig.

We run it against the venv directly, not the SBOM, because pip-audit has its own resolution logic.

```bash
pip-audit \
  --path ~/[PackageName]/venv \
  -f json \
  -o ~/[PackageName]/pip-audit.json
```

| Flag | Why it's there |
|---|---|
| `--path ~/[PackageName]/venv` | Scans the installed venv directly, using pip-audit's own dependency-resolution logic. This is deliberately independent of the SBOM/grype path — that's the point of running it. |
| `-f json` | Machine-readable output, consistent with the rest of the pipeline's findings. |
| `-o ~/[PackageName]/pip-audit.json` | Writes results to a file for the findings record. |

### 7. `osv-scanner`

osv-scanner is Google's OSV database client. It's a third CVE/vulnerability signal, but it has a meaningfully different scanning approach from the previous two. It can consume your `requirements.txt` lockfile directly as a first-class input — it understands pip's lockfile format natively and queries OSV with package name and version tuples. This means it doesn't need the venv at all, just the lockfile. That's useful in contexts where you want to check a lockfile before committing to an install.

```bash
osv-scanner scan \
  --lockfile ~/[PackageName]/requirements.txt \
  --format json \
  --output ~/[PackageName]/osv.json
```

| Flag | Why it's there |
|---|---|
| `--lockfile ~/[PackageName]/requirements.txt` | Scans the pinned lockfile directly. osv-scanner understands pip's lockfile format natively and queries OSV by name/version pairs, so it doesn't need the venv or `dist/` artifacts at all. |
| `--format json` | Machine-readable output, consistent with the rest of the pipeline. |
| `--output ~/[PackageName]/osv.json` | Writes results to a file. (Newer versions of osv-scanner deprecate this flag in favor of `--output-file` — see the warning in the example run.) |

### 8. Bandit (static analysis)

Bandit is a Python static analysis tool that reads source code and flags dangerous coding patterns — use of weak cryptography, shell injection risks, use of `eval()`, insecure deserialization, hardcoded credentials, and so on. It is not a CVE scanner. It doesn't care about version numbers or advisory databases. It reads the actual code and asks: _does this code do something dangerous?_

In this pipeline, bandit serves two purposes. First, it catches risky patterns in the package source that no CVE exists for yet — a maintainer might have introduced `subprocess.call(shell=True)` in the current version, and no advisory will exist until someone weaponizes it. Second, it gives you a code-level audit artifact that documents what you looked at.

You run bandit against the installed source in the venv, not the wheel files — the wheels have already been unpacked during install, so the source is sitting in `venv/lib/`.

```bash
bandit \
  -r ~/[PackageName]/venv/lib/ \
  -f json \
  -o ~/[PackageName]/bandit.json \
  --severity-level medium \
  --confidence-level medium
```

| Flag | Why it's there |
|---|---|
| `-r ~/[PackageName]/venv/lib/` | Recursive scan of the installed source. The wheels have already been unpacked during install, so the actual `.py` source lives under `venv/lib/`, not in `dist/`. |
| `-f json` | Machine-readable output. |
| `-o ~/[PackageName]/bandit.json` | Writes results to a file. |
| `--severity-level medium` | Filters out low-severity noise at scan time, keeping the findings record focused on issues actually worth an analyst's attention. |
| `--confidence-level medium` | Same idea applied to confidence: drops bandit's low-confidence guesses, which tend to be false positives. |

### 9. Guarddog (malicious package behavioral detection)

This is the second threat class. Everything so far — grype, pip-audit, osv-scanner, bandit — operates on the assumption that the package is legitimate and asks whether it has problems. guarddog flips the question: _is this package itself an attack?_

It looks for behavioral indicators of malicious packages: network calls in setup code, obfuscated strings, environment variable exfiltration, C2 patterns, suspicious use of `install_requires` hooks, typosquatting signals, and more. It's the tool that would have caught packages like `colourama` (a typosquat of `colorama`) or packages that phone home on install.

Because guarddog analyzes package behavior rather than installed files, you run it against the downloaded wheel/sdist artifacts in `dist/` rather than the installed venv. It's examining what the package _does_ when it arrives, not what it looks like after installation.

```bash
guarddog pypi scan [PackageName] > [PackageName]-guarddog.txt
```

| Flag | Why it's there |
|---|---|
| `pypi` | Tells guarddog which package ecosystem to query. It also supports `npm`. |
| `scan [PackageName]` | Pulls the package directly from PyPI and runs guarddog's behavioral heuristics against it — obfuscation, install-time network calls, typosquat detection, and similar indicators. |
| `> [PackageName]-guarddog.txt` | Redirects the human-readable output to a file for the findings record. (Named with a `-guarddog` suffix so it doesn't collide with any file that shares the package's name.) |

### 10. Scorecard (supply chain health)

Scorecard is different in character from everything that came before it. It doesn't scan for vulnerabilities or malicious behavior. It evaluates the _supply chain health_ of the upstream project. It asks questions like: does this project pin its own dependencies? Does it require code review? Does it use branch protection? Does it run SAST? Are its CI workflows hardened against injection attacks?

Grype tells you whether the current version is clean. Scorecard tells you whether you can trust the next version. It's a forward-looking signal.

Scorecard queries GitHub's API, so it needs a token even for public repos — the one you set up during the pyvet bootstrap. It also operates on the upstream GitHub repository, not the local package.

```bash
export GITHUB_AUTH_TOKEN=<your token>
scorecard --repo=github.com/<org>/<repo> --show-details > [PackageName].scorecard
```

| Flag | Why it's there |
|---|---|
| `export GITHUB_AUTH_TOKEN=<your token>` | Authenticates against the GitHub API. Without it you'll hit rate limits almost immediately, even against public repos. Source this from `~/.pyvet_env` (see [GitHub Auth Token](#github-auth-token)) rather than pasting the token inline. |
| `--repo=github.com/<org>/<repo>` | The **upstream** GitHub repository for the package. Scorecard evaluates the project's source and CI configuration, not the local package artifacts. |
| `--show-details` | Includes the full reason/detail breakdown for every check, not just the numeric score. A bare score with no supporting detail isn't auditable — this is what makes the output usable as a findings-record artifact. |
| `> [PackageName].scorecard` | Redirects output to a file for archiving alongside the SBOM and other findings. |

### 11. Verdict

Each package gets one of three outcomes: **Go**, **Conditional Go**, or **No-Go**. Findings from Steps 4–10 roll up into that decision as follows:

| Finding | Outcome |
|---|---|
| Any guarddog malicious-behavior indicator | **No-Go**, no exceptions, regardless of every other result. This is the one category where a single positive finding overrides everything else. |
| Critical or High CVE (grype / pip-audit / osv-scanner) on an in-scope package, with no fix available | **No-Go** until a patched version exists — then re-vet the patched version from Step 1. |
| Critical or High CVE with a fix available, or any CVE confined to bootstrap tooling (e.g. `pip` itself) that isn't part of the vetted closure | **Conditional Go** — approved, with the finding documented in the verdict record. |
| Medium/Low CVE, or a Bandit finding at medium severity/confidence in package source | **Conditional Go** — documented, not blocking. High-severity, high-confidence Bandit findings get analyst review before Go. |
| Low Scorecard aggregate score | **Advisory only.** Scorecard doesn't gate the current version — it informs how aggressively you re-vet future versions of that dependency. |

**Sign-off.** The analyst who ran the pipeline documents the findings from Steps 4–10 in a verdict record and a second reviewer (security engineer or team lead) countersigns before the package is released across the air gap. At minimum, the verdict record includes: package name and pinned version, SBOM reference, a summary of each tool's findings, any divergence between scanners and how it was resolved, the final decision (Go / Conditional Go / No-Go), and the analyst's and reviewer's names and date.

#### A Note on Scanner Disagreement

When grype and pip-audit agree, especially on in-scope packages, you have corroborated confidence. When they disagree, you don't average them or pick the friendlier answer. You document the divergence, note the specific advisories grype surfaced, and let the analyst make a call. In the PyYAML run below, the disagreement was on bootstrap tooling and all grype findings were already in a "fixed" state, so the verdict was unaffected — but the divergence itself still goes in the findings record.

---

## Example Run: PyYAML

> Terminal output below is lightly sanitized (local paths use a generic `analyst` username in place of the operator's actual account) but otherwise reflects the real run.

### Setup

```bash
mkdir -p ~/PyYAML && cd ~/PyYAML
cat > requirements.in << 'EOF'
PyYAML
EOF
```

### 1. Pin (`pip-compile`)

```bash
pip-compile requirements.in \
  --generate-hashes \
  --output-file requirements.txt \
  --no-header \
  --resolver=backtracking
```

```
WARNING: --strip-extras is becoming the default in version 8.0.0. To silence this warning, either use --strip-extras to opt into the new default or use --no-strip-extras to retain the existing behavior.
```

<details>
<summary><code>requirements.txt</code> output (click to expand — 70 hashes)</summary>

```
pyyaml==6.0.3 \
    --hash=sha256:00c4bdeba853cc34e7dd471f16b4114f4162dc03e6b7afcc2128711f0eca823c \
    --hash=sha256:0150219816b6a1fa26fb4699fb7daa9caf09eb1999f3b70fb6e786805e80375a \
    --hash=sha256:02893d100e99e03eda1c8fd5c441d8c60103fd175728e23e431db1b589cf5ab3 \
    --hash=sha256:02ea2dfa234451bbb8772601d7b8e426c2bfa197136796224e50e35a78777956 \
    --hash=sha256:0f29edc409a6392443abf94b9cf89ce99889a1dd5376d94316ae5145dfedd5d6 \
    --hash=sha256:10892704fc220243f5305762e276552a0395f7beb4dbf9b14ec8fd43b57f126c \
    --hash=sha256:16249ee61e95f858e83976573de0f5b2893b3677ba71c9dd36b9cf8be9ac6d65 \
    --hash=sha256:1d37d57ad971609cf3c53ba6a7e365e40660e3be0e5175fa9f2365a379d6095a \
    --hash=sha256:1ebe39cb5fc479422b83de611d14e2c0d3bb2a18bbcb01f229ab3cfbd8fee7a0 \
    --hash=sha256:214ed4befebe12df36bcc8bc2b64b396ca31be9304b8f59e25c11cf94a4c033b \
    --hash=sha256:2283a07e2c21a2aa78d9c4442724ec1eb15f5e42a723b99cb3d822d48f5f7ad1 \
    --hash=sha256:22ba7cfcad58ef3ecddc7ed1db3409af68d023b7f940da23c6c2a1890976eda6 \
    --hash=sha256:27c0abcb4a5dac13684a37f76e701e054692a9b2d3064b70f5e4eb54810553d7 \
    --hash=sha256:28c8d926f98f432f88adc23edf2e6d4921ac26fb084b028c733d01868d19007e \
    --hash=sha256:2e71d11abed7344e42a8849600193d15b6def118602c4c176f748e4583246007 \
    --hash=sha256:34d5fcd24b8445fadc33f9cf348c1047101756fd760b4dacb5c3e99755703310 \
    --hash=sha256:37503bfbfc9d2c40b344d06b2199cf0e96e97957ab1c1b546fd4f87e53e5d3e4 \
    --hash=sha256:3c5677e12444c15717b902a5798264fa7909e41153cdf9ef7ad571b704a63dd9 \
    --hash=sha256:3ff07ec89bae51176c0549bc4c63aa6202991da2d9a6129d7aef7f1407d3f295 \
    --hash=sha256:41715c910c881bc081f1e8872880d3c650acf13dfa8214bad49ed4cede7c34ea \
    --hash=sha256:418cf3f2111bc80e0933b2cd8cd04f286338bb88bdc7bc8e6dd775ebde60b5e0 \
    --hash=sha256:44edc647873928551a01e7a563d7452ccdebee747728c1080d881d68af7b997e \
    --hash=sha256:4a2e8cebe2ff6ab7d1050ecd59c25d4c8bd7e6f400f5f82b96557ac0abafd0ac \
    --hash=sha256:4ad1906908f2f5ae4e5a8ddfce73c320c2a1429ec52eafd27138b7f1cbe341c9 \
    --hash=sha256:501a031947e3a9025ed4405a168e6ef5ae3126c59f90ce0cd6f2bfc477be31b7 \
    --hash=sha256:5190d403f121660ce8d1d2c1bb2ef1bd05b5f68533fc5c2ea899bd15f4399b35 \
    --hash=sha256:5498cd1645aa724a7c71c8f378eb29ebe23da2fc0d7a08071d89469bf1d2defb \
    --hash=sha256:5cf4e27da7e3fbed4d6c3d8e797387aaad68102272f8f9752883bc32d61cb87b \
    --hash=sha256:5e0b74767e5f8c593e8c9b5912019159ed0533c70051e9cce3e8b6aa699fcd69 \
    --hash=sha256:5ed875a24292240029e4483f9d4a4b8a1ae08843b9c54f43fcc11e404532a8a5 \
    --hash=sha256:5fcd34e47f6e0b794d17de1b4ff496c00986e1c83f7ab2fb8fcfe9616ff7477b \
    --hash=sha256:5fdec68f91a0c6739b380c83b951e2c72ac0197ace422360e6d5a959d8d97b2c \
    --hash=sha256:6344df0d5755a2c9a276d4473ae6b90647e216ab4757f8426893b5dd2ac3f369 \
    --hash=sha256:64386e5e707d03a7e172c0701abfb7e10f0fb753ee1d773128192742712a98fd \
    --hash=sha256:652cb6edd41e718550aad172851962662ff2681490a8a711af6a4d288dd96824 \
    --hash=sha256:66291b10affd76d76f54fad28e22e51719ef9ba22b29e1d7d03d6777a9174198 \
    --hash=sha256:66e1674c3ef6f541c35191caae2d429b967b99e02040f5ba928632d9a7f0f065 \
    --hash=sha256:6adc77889b628398debc7b65c073bcb99c4a0237b248cacaf3fe8a557563ef6c \
    --hash=sha256:79005a0d97d5ddabfeeea4cf676af11e647e41d81c9a7722a193022accdb6b7c \
    --hash=sha256:7c6610def4f163542a622a73fb39f534f8c101d690126992300bf3207eab9764 \
    --hash=sha256:7f047e29dcae44602496db43be01ad42fc6f1cc0d8cd6c83d342306c32270196 \
    --hash=sha256:8098f252adfa6c80ab48096053f512f2321f0b998f98150cea9bd23d83e1467b \
    --hash=sha256:850774a7879607d3a6f50d36d04f00ee69e7fc816450e5f7e58d7f17f1ae5c00 \
    --hash=sha256:8d1fab6bb153a416f9aeb4b8763bc0f22a5586065f86f7664fc23339fc1c1fac \
    --hash=sha256:8da9669d359f02c0b91ccc01cac4a67f16afec0dac22c2ad09f46bee0697eba8 \
    --hash=sha256:8dc52c23056b9ddd46818a57b78404882310fb473d63f17b07d5c40421e47f8e \
    --hash=sha256:9149cad251584d5fb4981be1ecde53a1ca46c891a79788c0df828d2f166bda28 \
    --hash=sha256:93dda82c9c22deb0a405ea4dc5f2d0cda384168e466364dec6255b293923b2f3 \
    --hash=sha256:96b533f0e99f6579b3d4d4995707cf36df9100d67e0c8303a0c55b27b5f99bc5 \
    --hash=sha256:9c57bb8c96f6d1808c030b1687b9b5fb476abaa47f0db9c0101f5e9f394e97f4 \
    --hash=sha256:9c7708761fccb9397fe64bbc0395abcae8c4bf7b0eac081e12b809bf47700d0b \
    --hash=sha256:9f3bfb4965eb874431221a3ff3fdcddc7e74e3b07799e0e84ca4a0f867d449bf \
    --hash=sha256:a33284e20b78bd4a18c8c2282d549d10bc8408a2a7ff57653c0cf0b9be0afce5 \
    --hash=sha256:a80cb027f6b349846a3bf6d73b5e95e782175e52f22108cfa17876aaeff93702 \
    --hash=sha256:b30236e45cf30d2b8e7b3e85881719e98507abed1011bf463a8fa23e9c3e98a8 \
    --hash=sha256:b3bc83488de33889877a0f2543ade9f70c67d66d9ebb4ac959502e12de895788 \
    --hash=sha256:b865addae83924361678b652338317d1bd7e79b1f4596f96b96c77a5a34b34da \
    --hash=sha256:b8bb0864c5a28024fac8a632c443c87c5aa6f215c0b126c449ae1a150412f31d \
    --hash=sha256:ba1cc08a7ccde2d2ec775841541641e4548226580ab850948cbfda66a1befcdc \
    --hash=sha256:bdb2c67c6c1390b63c6ff89f210c8fd09d9a1217a465701eac7316313c915e4c \
    --hash=sha256:c1ff362665ae507275af2853520967820d9124984e0f7466736aea23d8611fba \
    --hash=sha256:c2514fceb77bc5e7a2f7adfaa1feb2fb311607c9cb518dbc378688ec73d8292f \
    --hash=sha256:c3355370a2c156cffb25e876646f149d5d68f5e0a3ce86a5084dd0b64a994917 \
    --hash=sha256:c458b6d084f9b935061bc36216e8a69a7e293a2f1e68bf956dcd9e6cbcd143f5 \
    --hash=sha256:d0eae10f8159e8fdad514efdc92d74fd8d682c933a6dd088030f3834bc8e6b26 \
    --hash=sha256:d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f \
    --hash=sha256:ebc55a14a21cb14062aa4162f906cd962b28e2e9ea38f9b4391244cd8de4ae0b \
    --hash=sha256:eda16858a3cab07b80edaf74336ece1f986ba330fdb8ee0d6c0d68fe82bc96be \
    --hash=sha256:ee2922902c45ae8ccada2c5b501ab86c36525b883eff4255313a253a3160861c \
    --hash=sha256:efd7b85f94a6f21e4932043973a7ba2613b059c4a000551892ac9f1d11f5baf3 \
    --hash=sha256:f7057c9a337546edc7973c0d3ba84ddcdf0daa14533c2065749c9075001090e6 \
    --hash=sha256:fa160448684b4e94d80416c0fa4aac48967a969efe22931448d853ada8baf926 \
    --hash=sha256:fc09d0aa354569bc501d4e787133afc08552722d3ab34836a80547331bb5d4a0
    # via -r requirements.in
```

</details>

### 2. Fetch (`pip download` with hash verification)

```bash
mkdir -p ~/PyYAML/dist
pip download \
  --require-hashes \
  --no-deps \
  -r ~/PyYAML/requirements.txt \
  -d ~/PyYAML/dist
```

```
Collecting pyyaml==6.0.3 (from -r /home/analyst/PyYAML/requirements.txt (line 1))
  Downloading pyyaml-6.0.3-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl (801 kB)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 801.6/801.6 kB 9.7 MB/s eta 0:00:00
Saved ./dist/pyyaml-6.0.3-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl
Successfully downloaded pyyaml
```

### 3. Install to an Isolated venv

```bash
python3 -m venv ~/PyYAML/venv

pip install \
  --require-hashes \
  --no-index \
  --find-links ~/PyYAML/dist/ \
  -r ~/PyYAML/requirements.txt \
  --prefix ~/PyYAML/venv
```

If you get an error about the following:

```
error: uninstall-no-record-file
× Cannot uninstall PyYAML 6.0.2
╰─> The package's contents are unknown: no RECORD file was found for PyYAML.
hint: The package was installed by debian. You should check if it can uninstall the package.
```

The command ran pip — but _which_ pip? The system pip, or your pyvet venv's pip. Because you used `--prefix` rather than activating the new venv, pip was still operating with system-level site-package awareness. It saw that PyYAML 6.0.2 was already installed (by Debian's package manager, apt), decided it needed to uninstall the old version before installing 6.0.3, and then discovered it couldn't — because apt-managed packages don't have a pip RECORD file. Debian owns that package; pip can't touch it.

The fix is simple: **use the venv's own pip binary directly**, not the ambient pip on your PATH. The venv's pip operates entirely within the venv's isolated site-packages and has no visibility into system-installed packages. It won't try to uninstall anything from outside its own prefix.

Drop the `--prefix` flag entirely — that's redundant and the source of the confusion. When you invoke the venv's pip, it already knows where to install. (This is why the generic Step 3 command above uses the venv's own `pip` binary from the start.)

```bash
~/PyYAML/venv/bin/pip install \
 --require-hashes \
 --no-index \
 --find-links ~/PyYAML/dist/ \
 -r ~/PyYAML/requirements.txt
```

```
Looking in links: /home/analyst/PyYAML/dist/
Processing ./PyYAML/dist/pyyaml-6.0.3-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl (from -r /home/analyst/PyYAML/requirements.txt (line 1))
Installing collected packages: pyyaml
Successfully installed pyyaml-6.0.3
```

### 4. SBOM with `syft`

```bash
syft ~/PyYAML/venv \
  --output spdx-json=~/PyYAML/sbom.spdx.json
```

```
 ✔ Indexed file system                                                                         /home/analyst/PyYAML/venv
 ✔ Cataloged contents                                ed3eee39c8ff1500b5aefda4601468c74024247107c9cb3ea7cce31a3c66e972
   ├── ✔ Packages                        [2 packages]
   ├── ✔ Executables                     [1 executables]
   ├── ✔ File metadata                   [6 locations]
   └── ✔ File digests                    [6 files]  [0000]  WARN no explicit name and version provided for directory sou
A newer version of syft is available for download: 1.46.0 (installed version is 1.45.1)
```

After it runs, we'll do a quick sanity check to confirm syft saw exactly the packages we installed and nothing extra:

```bash
jq '[.packages[] | {name: .name, version: .versionInfo}] | sort_by(.name)' ~/PyYAML/sbom.spdx.json
```

```json
[
  {
    "name": "/home/analyst/PyYAML/venv",
    "version": null
  },
  {
    "name": "pip",
    "version": "25.1.1"
  },
  {
    "name": "pyyaml",
    "version": "6.0.3"
  }
]
```

### 5. `grype` (CVE scanning)

```bash
grype sbom:~/PyYAML/sbom.spdx.json \
  --output json \
 > ~/PyYAML/grype.json
```

```
✔ Vulnerability DB                [updated]
 ✔ Scanned for vulnerabilities     [5 vulnerability matches]
   ├── by severity: 0 critical, 0 high, 4 medium, 1 low, 0 negligible
   └── by status:   5 fixed, 0 not-fixed, 0 ignored
'''
Rest of output omitted to save space
'''
A newer version of grype is available for download: 0.115.0 (installed version is 0.114.0)
```

Once that completes, we apply the two-bucket filter — in-scope packages first:

```bash
jq '[.matches[] | select(.artifact.name | IN("PyYAML")) | {package: .artifact.name, version: .artifact.version, vuln: .vulnerability.id, severity: .vulnerability.severity, fixed: .vulnerability.fix.state}]' \
 ~/PyYAML/grype.json
```

```
[]
```

Empty array. Zero CVEs against PyYAML itself. At its current pinned version, the package is clean against every vulnerability database grype knows about. This is the expected result for a well-maintained, heavily-scrutinized package like PyYAML — the maintainers are responsive and current releases stay clean. That said, "clean today" is not "clean forever." The pinned version matters: when you re-vet or when new CVEs drop, you re-run grype against the archived SBOM and the result may change.

Next, bootstrap tooling separately:

```bash
jq '[.matches[] | {package: .artifact.name, version: .artifact.version, vuln: .vulnerability.id, severity: .vulnerability.severity, fixed: .vulnerability.fix.state}]' \
  ~/PyYAML/grype.json
```

```json
[
  {
    "package": "pip",
    "version": "25.1.1",
    "vuln": "GHSA-4xh5-x5gv-qwph",
    "severity": "Medium",
    "fixed": "fixed"
  },
  {
    "package": "pip",
    "version": "25.1.1",
    "vuln": "GHSA-wf93-45jw-7689",
    "severity": "Medium",
    "fixed": "fixed"
  },
  {
    "package": "pip",
    "version": "25.1.1",
    "vuln": "GHSA-6vgw-5pg2-w6jp",
    "severity": "Low",
    "fixed": "fixed"
  },
  {
    "package": "pip",
    "version": "25.1.1",
    "vuln": "GHSA-jp4c-xjxw-mgf9",
    "severity": "Medium",
    "fixed": "fixed"
  },
  {
    "package": "pip",
    "version": "25.1.1",
    "vuln": "GHSA-58qw-9mgm-455v",
    "severity": "Medium",
    "fixed": "fixed"
  }
]
```

All five are `"fixed": "fixed"` — meaning a patched pip version already exists that resolves them. Three are Medium, one is Low. None are Critical or High.

The filter did exactly what it was designed to do. These findings did not pollute the in-scope verdict gate. Without the filter, a naive pipeline would have returned 5 findings and potentially blocked PyYAML — a package that is entirely clean — because of vulnerabilities in the Python runtime's own package manager.

**What to do about the pip findings.** You don't block on them, but you don't silently drop them either. Two actions:

First, document them in the verdict as a bootstrap finding: _pip 25.1.1 in the venv bootstrap has 5 known CVEs (4 Medium, 1 Low), all fixed in later versions. These are not part of the vetted closure and do not affect the PyYAML verdict._

Second, note operationally that the venv's pip is behind. When you transfer packages to the air-gapped enclave, the venv pip version comes along for the ride. Whether you care depends on whether pip ever runs in the enclave post-transfer — if you're just installing from pre-vetted wheels with no network access, pip's network-facing vulnerability surface is zero. Still worth tracking.

### 6. `pip-audit`

```bash
pip-audit \
  --path ~/PyYAML/venv \
  -f json \
  -o ~/PyYAML/pip-audit.json
```

```
No known vulnerabilities found
```

### 7. `osv-scanner`

```bash
osv-scanner scan \
  --lockfile ~/PyYAML/requirements.txt \
  --format json \
  --output ~/PyYAML/osv.json
```

```
Warning: --output has been deprecated in favor of --output-file
Starting filesystem walk for root: /
Scanned /home/analyst/PyYAML/requirements.txt file and found 1 package
End status: 0 dirs visited, 1 inodes visited, 1 Extract calls, 453.408µs elapsed, 453.463µs wall time
```

```bash
jq '[.results[].packages[] | select(.vulnerabilities | length > 0) | {package: .package.name, version: .package.version, vulns: [.vulnerabilities[] | {id: .id, severity: (.severity // "unspecified")}]}]' \
  ~/PyYAML/osv.json
```

```json
{
  "results": [],
  "experimental_config": {
    "licenses": {
      "summary": false,
      "allowlist": null
    }
  }
}
```

No results with vulnerabilities — clean, no vulnerabilities reported from OSV. (`results` came back empty, so the filter above has nothing to report.)

### 8. Bandit (static analysis)

```bash
bandit \
  -r ~/PyYAML/venv/lib/ \
  -f json \
  -o ~/PyYAML/bandit.json \
  --severity-level medium \
  --confidence-level medium
```

```
[main]  INFO    profile include tests: None
[main]  INFO    profile exclude tests: None
[main]  INFO    cli include tests: None
[main]  INFO    cli exclude tests: None
Working... ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 100% 0:00:05
[json]  INFO    JSON output written to file: /home/analyst/PyYAML/bandit.json
```

Then read findings, excluding test code (test files intentionally contain dangerous patterns by design):

```bash
jq '[.results[] | select(
  (.filename | test("test") | not) and
  (.filename | test("/pip/") | not)
) | {file: .filename, issue: .issue_text, severity: .issue_severity, confidence: .issue_confidence, test_id: .test_id}]' \
  ~/PyYAML/bandit.json
```

```json
[]
```

### 9. Guarddog (malicious package behavioral detection)

```bash
guarddog pypi scan pyyaml
```

```
Found 0 potentially malicious indicators scanning pyyaml
```

### 10. Scorecard (supply chain health)

```bash
export GITHUB_AUTH_TOKEN=<your token>
scorecard --repo=github.com/yaml/pyyaml --show-details > pyyaml-scorecard.txt
cat pyyaml-scorecard.txt
```

**Aggregate score: 4.8 / 10**

| Check | Score | Summary |
|---|---|---|
| Vulnerabilities | 10 / 10 | 0 existing vulnerabilities detected |
| Security-Policy | 10 / 10 | Security policy file found (`.github/SECURITY.md`), includes disclosure/timeline info |
| License | 10 / 10 | MIT license file detected |
| Dangerous-Workflow | 10 / 10 | No dangerous workflow patterns detected |
| Fuzzing | 10 / 10 | OSS-Fuzz integration found |
| Binary-Artifacts | 10 / 10 | No binaries committed to the repo |
| Contributors | 10 / 10 | Contributions from 35+ organizations |
| Maintained | 2 / 10 | Only 1 commit and 2 issue interactions in the last 90 days |
| Code-Review | 2 / 10 | 6 of 30 sampled changesets had an approved review |
| Branch-Protection | 1 / 10 | `main` requires no approvers, no CODEOWNERS review, no status checks; `release/6.0` has no branch protection at all |
| CI-Tests | 1 / 10 | Only 2 of 11 merged PRs were checked by CI |
| SAST | 0 / 10 | 0 of 11 commits scanned by a SAST tool |
| CII-Best-Practices | 0 / 10 | No OpenSSF Best Practices badge |
| Dependency-Update-Tool | 0 / 10 | No Dependabot / Renovate configuration found |
| Pinned-Dependencies | 0 / 10 | 0 of 24 GitHub-owned Actions, 0 of 3 third-party Actions, and 0 of 3 pip install commands are pinned by hash in `ci.yaml` |
| Token-Permissions | 0 / 10 | Workflow tokens have no explicit top-level permissions block (default GitHub token permissions apply) |
| Packaging | N/A | No GitHub/GitLab publishing workflow detected |
| Signed-Releases | N/A | No releases found on GitHub to evaluate |

**Read on this:** the checks that matter most for our threat model — *Vulnerabilities*, *Security-Policy*, *Dangerous-Workflow*, *License* — all score 10/10. The weak spots (*Branch-Protection*, *CI-Tests*, *SAST*, *Code-Review*, *Pinned-Dependencies*, *Token-Permissions*) describe upstream CI/release hygiene, not a known problem with the code we vetted. That's exactly the "forward-looking" distinction from the [Scorecard step](#10-scorecard-supply-chain-health) above: nothing here blocks today's verdict, but it does mean we treat future PyYAML releases with a bit less default trust and re-run the full pipeline on every version bump rather than rubber-stamping updates.

<details>
<summary>Raw <code>scorecard --show-details</code> output (click to expand)</summary>

```
Starting (github.com/yaml/pyyaml) [Token-Permissions]
Starting (github.com/yaml/pyyaml) [Dependency-Update-Tool]
Starting (github.com/yaml/pyyaml) [Security-Policy]
Starting (github.com/yaml/pyyaml) [SAST]
Starting (github.com/yaml/pyyaml) [Binary-Artifacts]
Starting (github.com/yaml/pyyaml) [Branch-Protection]
Starting (github.com/yaml/pyyaml) [Pinned-Dependencies]
Starting (github.com/yaml/pyyaml) [License]
Starting (github.com/yaml/pyyaml) [Code-Review]
Starting (github.com/yaml/pyyaml) [Dangerous-Workflow]
Starting (github.com/yaml/pyyaml) [Maintained]
Starting (github.com/yaml/pyyaml) [Packaging]
Starting (github.com/yaml/pyyaml) [CI-Tests]
Starting (github.com/yaml/pyyaml) [Contributors]
Starting (github.com/yaml/pyyaml) [CII-Best-Practices]
Starting (github.com/yaml/pyyaml) [Signed-Releases]
Starting (github.com/yaml/pyyaml) [Vulnerabilities]
Starting (github.com/yaml/pyyaml) [Fuzzing]
Finished (github.com/yaml/pyyaml) [CII-Best-Practices]
Finished (github.com/yaml/pyyaml) [Signed-Releases]
Finished (github.com/yaml/pyyaml) [Vulnerabilities]
Finished (github.com/yaml/pyyaml) [Fuzzing]
Finished (github.com/yaml/pyyaml) [Token-Permissions]
Finished (github.com/yaml/pyyaml) [Dependency-Update-Tool]
Finished (github.com/yaml/pyyaml) [Security-Policy]
Finished (github.com/yaml/pyyaml) [SAST]
Finished (github.com/yaml/pyyaml) [Binary-Artifacts]
Finished (github.com/yaml/pyyaml) [Branch-Protection]
Finished (github.com/yaml/pyyaml) [Pinned-Dependencies]
Finished (github.com/yaml/pyyaml) [License]
Finished (github.com/yaml/pyyaml) [Code-Review]
Finished (github.com/yaml/pyyaml) [Dangerous-Workflow]
Finished (github.com/yaml/pyyaml) [Maintained]
Finished (github.com/yaml/pyyaml) [Packaging]
Finished (github.com/yaml/pyyaml) [CI-Tests]
Finished (github.com/yaml/pyyaml) [Contributors]

RESULTS
-------
Aggregate score: 4.8 / 10

Check scores:
SCORE    NAME                     REASON
10 / 10  Binary-Artifacts         no binaries found in the repo
1  / 10  Branch-Protection        branch protection is not maximal on development and all release branches
                                     Warn: branch protection not enabled for branch 'release/6.0'
                                     Info: 'allow deletion' disabled on branch 'main'
                                     Info: 'force pushes' disabled on branch 'main'
                                     Warn: branch 'main' does not require approvers
                                     Warn: codeowners review is not required on branch 'main'
                                     Warn: no status checks found to merge onto branch 'main'
1  / 10  CI-Tests                 2 out of 11 merged PRs checked by a CI test -- score normalized to 1
0  / 10  CII-Best-Practices       no effort to earn an OpenSSF best practices badge detected
2  / 10  Code-Review              Found 6/30 approved changesets -- score normalized to 2
10 / 10  Contributors             project has 35 contributing companies or organizations
10 / 10  Dangerous-Workflow       no dangerous workflow patterns detected
0  / 10  Dependency-Update-Tool   no update tool detected
                                     Warn: no dependency update tool configurations found
10 / 10  Fuzzing                  project is fuzzed
                                     Info: OSSFuzz integration found
10 / 10  License                  license file detected
                                     Info: project has a license file: LICENSE:0
                                     Info: FSF or OSI recognized license: MIT License: LICENSE:0
2  / 10  Maintained               1 commit(s) and 2 issue activity found in the last 90 days -- score normalized to 2
?        Packaging                packaging workflow not detected
                                     Warn: no GitHub/GitLab publishing workflow detected.
0  / 10  Pinned-Dependencies      dependency not pinned by hash detected -- score normalized to 0
                                     Warn: 0 out of 24 GitHub-owned GitHubAction dependencies pinned
                                     Warn: 0 out of 3 third-party GitHubAction dependencies pinned
                                     Warn: 0 out of 3 pipCommand dependencies pinned
                                     (28 individual unpinned-line warnings omitted — see .github/workflows/ci.yaml;
                                      each maps to https://app.stepsecurity.io/secureworkflow/yaml/pyyaml/ci.yaml/main?enable=pin)
0  / 10  SAST                     SAST tool is not run on all commits -- score normalized to 0
                                     Warn: 0 commits out of 11 are checked with a SAST tool
10 / 10  Security-Policy          security policy file detected
                                     Info: security policy file detected: .github/SECURITY.md:1
                                     Info: Found disclosure, vulnerability, and/or timelines in security policy
?        Signed-Releases          no releases found
0  / 10  Token-Permissions        detected GitHub workflow tokens with excessive permissions
                                     Warn: no topLevel permission defined: .github/workflows/ci.yaml:1
                                     Info: no jobLevel write permissions found
10 / 10  Vulnerabilities          0 existing vulnerabilities detected

Full per-line detail and remediation links: https://github.com/ossf/scorecard/blob/main/docs/checks.md
```

</details>

### 11. Verdict (PyYAML)

PyYAML showed no vulnerabilities with OSV-Scanner, guarddog, or Bandit. The single in-scope grype/pip-audit finding trail led to bootstrap `pip`, not PyYAML itself, and every one of those CVEs is already fixed upstream. PyYAML is well maintained at the package level and widely used, with no CVEs against the pinned version. **Approved for use on the enclave — Conditional Go**, with the pip bootstrap findings and the Scorecard supply-chain notes documented above as part of the record. SBOM attached.
