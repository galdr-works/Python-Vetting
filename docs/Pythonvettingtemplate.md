# pyvet — Closed Network Package Vetting Pipeline

> **How to use this template:** copy this file (or the `.docx` version) to a
> new file per package — e.g. `PyYAML-verdict.md` — and fill it in as you
> work through the eleven steps in the main [README](../README.md#the-process).
> Keep the completed copy alongside the SBOM and scan output files
> (`sbom.spdx.json`, `grype.json`, `pip-audit.json`, `osv.json`,
> `bandit.json`, `*-guarddog.txt`, `*.scorecard`) as the archival findings
> record for that package.

## Package Information

| Field | Value |
| --- | --- |
| **Package Name** | |
| **Pinned Version** | |
| **PyPI / Source URL** | |
| **Upstream Repository** | |
| **Requested By** | |
| **Date Requested** | |

## Sign-Off

| Field | Value |
| --- | --- |
| **Tested By (Analyst)** | |
| **Date Tested** | |
| **Approved By (Reviewer)** | |
| **Date Approved** | |

## Final Verdict

- [ ] Go
- [ ] Conditional Go
- [ ] No-Go

*See [Section 11 (Verdict)](#11-verdict) for the decision framework and required rationale before this box is marked.*

## Findings Dashboard

*Quick-scan summary — fill in after completing all ten steps below. Detail goes in the numbered sections that follow.*

| Step / Tool | Key Result | Status |
| --- | --- | --- |
| **1. Pin (`pip-compile`)** | | |
| **2. Fetch (`pip download`)** | | |
| **3. Install (isolated venv)** | | |
| **4. SBOM (`syft`)** | | |
| **5. Grype (CVE scan)** | | |
| **6. `pip-audit`** | | |
| **7. `osv-scanner`** | | |
| **8. Bandit (SAST)** | | |
| **9. Guarddog (behavioral)** | | |
| **10. Scorecard (supply chain)** | | |

*Status: use Clean / Findings (documented below) / Blocking. For Guarddog, use Clean / Flagged. For Scorecard, use the aggregate score.*

## The Process

### 1. Pin, Fetch & Install

*Preparation steps — confirm each before scanning begins. See the [pyvet process documentation](../README.md#the-process) for the full command reference.*

- [ ] `requirements.in` created
- [ ] `pip-compile` run with `--generate-hashes`
- [ ] `pip download --require-hashes` completed with no errors
- [ ] Installed into a fresh, isolated venv (not system/shared Python)

| Field | Value |
| --- | --- |
| **Lockfile Hash Count** | |
| **Artifacts Downloaded** | |

### 4. SBOM (`syft`)

*Independent enumeration of what actually landed in the venv. Flag any package not present in the lockfile.*

| Field | Value |
| --- | --- |
| **SBOM Format** | SPDX JSON |
| **SBOM File Reference** | |
| **Packages Detected** | |

- [ ] Package count matches expected closure (lockfile + bootstrap tooling only)

### 5. `grype` — CVE Scan

*Scanned from the archived SBOM. List in-scope package findings first; document bootstrap-tooling findings (e.g. `pip`) separately below as non-blocking.*

| Package | Version | Vuln ID | Severity | Fix Status |
| --- | --- | --- | --- | --- |
| | | | | |
| | | | | |
| | | | | |
| | | | | |

**Bootstrap / Out-of-Scope Findings**

> *e.g. pip 25.1.1 — 4 known CVEs, all fixed in later versions; not part of the vetted closure.*

### 6. `pip-audit`

*Run against the installed venv directly (independent resolution logic from grype).*

| Package | Version | Vuln ID | Severity | Description |
| --- | --- | --- | --- | --- |
| | | | | |
| | | | | |
| | | | | |
| | | | | |

### 7. `osv-scanner`

*Run against the lockfile directly.*

| Package | Version | Vuln ID | Severity | Description |
| --- | --- | --- | --- | --- |
| | | | | |
| | | | | |
| | | | | |
| | | | | |

### 8. Bandit — Static Analysis

*Scanned against installed source in `venv/lib/`, medium severity and confidence or higher. Test files excluded.*

| File | Issue | Severity | Confidence | Test ID |
| --- | --- | --- | --- | --- |
| | | | | |
| | | | | |
| | | | | |
| | | | | |

### 9. Guarddog — Malicious Behavior Detection

*Run against the downloaded wheel/sdist artifacts. Any positive finding here is an automatic No-Go — see [Section 11](#11-verdict).*

**Indicators Found:** \_\_\_\_

| Indicator | Description | Risk |
| --- | --- | --- |
| | | |
| | | |

### 10. Scorecard — Supply Chain Health

*Forward-looking signal on the upstream repository. Advisory — informs re-vet cadence, does not block the current version.*

| Field | Value |
| --- | --- |
| **Aggregate Score** | \_\_\_ / 10 |
| **Repository Scanned** | |

| Check | Score | Notes |
| --- | --- | --- |
| **Vulnerabilities** | | |
| **Maintained** | | |
| **Code-Review** | | |
| **Branch-Protection** | | |
| **CI-Tests** | | |
| **SAST** | | |
| **Pinned-Dependencies** | | |
| **Security-Policy** | | |
| **Token-Permissions** | | |

*Add additional check rows as needed — see the full pyvet Scorecard reference for the complete check list.*

### 11. Verdict

**Decision Framework (Reference)**

| Finding | Outcome |
| --- | --- |
| **Any Guarddog malicious-behavior indicator** | No-Go — no exceptions |
| **Critical/High CVE, in-scope package, no fix available** | No-Go until patched, then re-vet |
| **Critical/High CVE with a fix available, or CVE confined to bootstrap tooling** | Conditional Go — documented |
| **Medium/Low CVE, or medium Bandit finding** | Conditional Go — documented, non-blocking |
| **Low Scorecard aggregate score** | Advisory only — informs re-vet cadence |

**Analyst Rationale**

*Document why the package is approved, conditionally approved, or rejected — reference specific findings from Sections 5–10.*

> *Analyst narrative...*

**Divergence / Notes**

*Document any disagreement between scanners (e.g. grype vs. pip-audit) and how it was resolved. See "A Note on Scanner Disagreement" in the pyvet process documentation.*

> *Notes on scanner divergence, bootstrap findings, or other context...*

**Final Decision**

- [ ] Go
- [ ] Conditional Go
- [ ] No-Go

**Conditions (if Conditional Go)**

> *Conditions or follow-up actions required...*

**Signatures**

| Field | Value |
| --- | --- |
| **Analyst (Tested By)** | |
| **Date** | |
| **Reviewer (Approved By)** | |
| **Date** | |