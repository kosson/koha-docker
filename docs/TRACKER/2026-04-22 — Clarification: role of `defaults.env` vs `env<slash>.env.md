---
title: "Clarification: role of `defaults.env` vs `env/.env`"
date: 2026.04.22
tags:
 - dotenv
 - runsh
 - variables
---
# 2026-04-22 — Clarification: role of `defaults.env` vs `env/.env`

These two files look similar but serve completely different purposes and **both must be kept**.

| File | Where it is read | By whom | Purpose |
|---|---|---|---|
| `env/.env` | On the **host**, before container starts | Docker Compose (`env_file:`) | Injects runtime values as container environment variables |
| `env/defaults.env` | **Inside the container** at startup | `run.sh` line 140 | Provides the list of variable *names* to pass to `envsubst` |

The critical line in `run.sh` is:

```bash
VARS_TO_SUB=`cut -d '=' -f1 ${BUILD_DIR}/templates/defaults.env | tr '\n' ':' | ...`
```

It reads only the **left-hand side** of each `VAR=value` entry in `defaults.env` to build the `$VAR1:$VAR2:...` string that `envsubst` uses to know which placeholders to expand in the template files (`koha-conf-site.xml.in`, `koha-sites.conf`, `apache2_envvars`, etc.).
Without `defaults.env` inside the container, `envsubst` would receive no variable list and all `${VAR}` placeholders in the generated config files would remain unexpanded.
