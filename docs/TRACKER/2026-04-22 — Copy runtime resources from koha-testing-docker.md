---
title: Copy runtime resources from koha-testing-docker
date: 2026.04.22
tags:
 - runsh
 - templates
 - copy
---
# 2026-04-22 — Copy runtime resources from koha-testing-docker

## Goal

Provide all files that `run.sh` references at container startup but that did not yet exist in `koha-docker/`.

## Files added

| File | Source | Purpose |
|---|---|---|
| `files/templates/apache2_envvars` | `koha-testing-docker` | Apache run-user/group config, substituted by `envsubst` |
| `files/templates/bash_aliases` | `koha-testing-docker` | Shell aliases for root and instance user |
| `files/templates/bin/dbic` | `koha-testing-docker` | DBIx::Class schema regeneration helper |
| `files/templates/bin/flush_memcached` | `koha-testing-docker` | Memcached flush helper |
| `files/templates/bin/bisect_with_test` | `koha-testing-docker` | Git bisect helper |
| `files/templates/gitconfig` | `koha-testing-docker` | Git aliases for the instance user |
| `files/templates/instance_bashrc` | `koha-testing-docker` | `.bashrc` for the `kohadev-koha` instance user |
| `files/templates/koha-conf-site.xml.in` | `koha-testing-docker` | Koha Zebra/config XML template |
| `files/templates/koha-sites.conf` | `koha-testing-docker` | `koha-create` site variables |
| `files/templates/root_bashrc` | `koha-testing-docker` | `.bashrc` for the root user |
| `files/templates/sudoers` | `koha-testing-docker` | Passwordless sudo for the instance user |
| `files/templates/vimrc` | `koha-testing-docker` | Vim configuration |
| `files/git_hooks/pre-commit` | `koha-testing-docker` | Perl syntax + CSS check before commit |
| `files/git_hooks/post-checkout` | `koha-testing-docker` | Sets `blame.ignoreRevsFile` after checkout |
| `env/defaults.env` | `koha-testing-docker` | Variable-name manifest for `envsubst` (see note below) |

## Dockerfile updated

Restored the `COPY` statements and the proper `CMD` entrypoint that had been left as a placeholder in the previous step:

```yaml
COPY files/run.sh          /kohadevbox/
COPY files/templates       /kohadevbox/templates
COPY files/git_hooks       /kohadevbox/git_hooks
COPY env/defaults.env      /kohadevbox/templates/defaults.env
CMD  ["/bin/bash", "/kohadevbox/run.sh"]
```