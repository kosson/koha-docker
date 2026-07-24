# 2026-07-24 — Alpine vs Ubuntu CVE comparison

**Status:** ✅ COMPLETED  
**Scope:** Local image security comparison between `kosson/koha-alpine:26.11` and `kosson/koha-ubuntu:latest`  
**Method:** Trivy image scan against the local Docker daemon, scanning OS and language packages with the same severity set (`UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL`)

---

## Context

A direct vulnerability comparison was requested after the Alpine Koha image was built and verified locally. The goal was to compare the Alpine image against the existing Ubuntu image using the same scanner and settings, then summarize the result in a tracker note.

---

## Scan setup

Images compared:

- `kosson/koha-alpine:26.11`
- `kosson/koha-ubuntu:latest`

Scanner details:

- Trivy container image: `aquasec/trivy:latest`
- Target source: local Docker daemon via `/var/run/docker.sock`
- Report format: JSON
- Scope: vulnerability scanning only
- Severity levels: `UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL`

---

## Comparison table

| Image | Local size | OS package vulns | Language package vulns | Total vulns |
| --- | ---: | ---: | ---: | ---: |
| `kosson/koha-alpine:26.11` | 1.81 GB | 0 | 0 | 0 |
| `kosson/koha-ubuntu:latest` | 4.48 GB | 3,198 | 483 | 3,681 |

---

## Observations

1. The Alpine image scanned clean in this run: no OS-package or language-package vulnerabilities were reported by Trivy.
2. The Ubuntu image carried a much larger vulnerability surface, especially in OS packages.
3. The Alpine image is also materially smaller locally, which matches the disk-space reduction observed during migration.

---

## Validation notes

- The Alpine scan report contained two result sections:
  - OS packages: `0` vulnerabilities
  - Node.js / language packages: `0` vulnerabilities
- The Ubuntu scan report contained two result sections:
  - OS packages: `3,198` vulnerabilities
  - Node.js / language packages: `483` vulnerabilities
- The comparison was performed on the local images already present on this machine, not on registry tags.

---

## Outcome

The Alpine build provides a substantially smaller and cleaner local image than the Ubuntu build in this environment. For the scanned state, Alpine reduced the reported CVE count from `3,681` to `0`.