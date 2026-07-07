---
title: "Map of Content — Koha Docker Architecture"
tags: [map-of-content, overview, navigation, index]
---
# Map of Content — Koha Docker Architecture

This vault is a navigational guide to the Koha Docker project at `~/Documents/koha-docker`. Use these notes to understand the architecture, operations, and known issues.

## Quick Links

- [[01 - Architecture Overview]] — High-level diagram, service list, data flow
- [[02 - Container Breakdown]] — Per-container details, ports, roles
- [[03 - Docker Compose Deep Dive]] — How the compose files orchestrate everything
- [[04 - Stack.sh Orchestrator]] — The main startup script, commands, flow
- [[05 - Koha Container (run.sh)]] — Container entrypoint, initialization sequence
- [[06 - Environment Variables]] — All env vars, scopes, defaults, secrets
- [[07 - Networking]] — 5 networks, routing, DNS/nip.io, Traefik labels
- [[08 - TLS & Security]] — Two TLS layers, certs, auth, known vulnerabilities
- [[09 - OpenSearch Cluster]] — 5-node setup, mTLS, data, health, Dashboards
- [[10 - MariaDB & Database]] — DB setup, schema, user grants, reset flow
- [[11 - Operations & Maintenance]] — Start, stop, reset, resume, rebuild, logs
- [[12 - Troubleshooting]] — Common errors, diagnostics, netcheck.sh
- [[13 - Security Audit (ISSUES.md)]] — Full issue catalog, severity, remediation
- [[14 - Patches & Hotfixes]] — Applied patches, how to manage them
- [[15 - Demo Data & MARC Import]] — insert_data.pl, MARC import workflow, pitfalls
- [[16 - Dockerfile Breakdown]] — Layer-by-layer analysis, package decisions
- [[17 - Perl Integration in Koha]] — How Perl scripts tie the stack together

## Cross-References

| When you need to... | Read this |
|---|---|
| Understand the whole picture | [[01 - Architecture Overview]] |
| Debug a connection failure | [[07 - Networking]], [[12 - Troubleshooting]] |
| Rotate passwords | [[06 - Environment Variables]], [[08 - TLS & Security]] |
| Fix a startup error | [[04 - Stack.sh Orchestrator]], [[12 - Troubleshooting]] |
| Understand security risks | [[13 - Security Audit (ISSUES.md)]] |
| Import MARC records | [[15 - Demo Data & MARC Import]] |
| Customize the image | [[16 - Dockerfile Breakdown]] |
| Configure HTTPS | [[07 - Networking]], [[08 - TLS & Security]] |
