---
title: "Dockerfile Breakdown"
tags: [dockerfile, ubuntu-24.04, layers, apt, koha-common, nodejs, yarn, cypress, perl-tools, apt-install-retry, uid-collision, crlf, image-size, build-time]
---

# Dockerfile Breakdown

Layer-by-layer analysis of the Koha container image.

---

## File

Location: `/home/kosson/Documents/koha-docker/Dockerfile` (236 lines)
Base image: `ubuntu:24.04` (Noble Numbat)

---

## Layer Analysis

### Layers 1-2: Setup

```dockerfile
FROM ubuntu:24.04

LABEL maintainer="kosson@gmail.com"
ENV PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ENV DEBIAN_FRONTEND=noninteractive
ENV REFRESHED_AT=2026-05-15
```

- **ubuntu:24.04** — Noble Numbat, LTS release
- **DEBIAN_FRONTEND=noninteractive** — No prompts during apt install
- **REFRESHED_AT** — Build timestamp marker

### Layer 3: UID Fix

```dockerfile
RUN userdel -r ubuntu 2>/dev/null || true
```

Removes the pre-created `ubuntu` user (UID 1000) so that `kohadev-koha` can use UID 1000. This is a hack documented in ISSUES.md #6.

### Layer 4: APT Mirror Fix

```dockerfile
RUN sed -i \
    -e 's|http://archive.ubuntu.com/ubuntu|http://mirrors.kernel.org/ubuntu|g' \
    -e 's|http://security.ubuntu.com/ubuntu|http://mirrors.kernel.org/ubuntu|g' \
    /etc/apt/sources.list.d/ubuntu.sources
```

Redirects apt sources from Canonical CDN to `mirrors.kernel.org`. The Canonical CDN IPs (91.189.91.x / 185.125.x.x) are unreachable from the user's network.

### Layer 5: APT Resilience

```dockerfile
RUN echo 'Acquire::Retries "8";'                   >  /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::http::Timeout "600";'          >> /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::https::Timeout "600";'         >> /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::Queue-Mode "host";'            >> /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::Max-FutureTime "86400";'       >> /etc/apt/apt.conf.d/80-retries
```

- **Retries**: 8 attempts per operation
- **Timeout**: 600 seconds (10 minutes)
- **Queue-Mode "host"**: Sequential connections per hostname (prevents idle-connection drops)
- **Max-FutureTime**: 86400 seconds — tolerates clock skew from VMs waking from sleep

### Layer 6: apt-install-retry Helper

```dockerfile
RUN cat > /usr/local/bin/apt-install-retry <<'EOF'
#!/bin/sh
set -eu
# ... retry logic with back-off ...
EOF
RUN chmod +x /usr/local/bin/apt-install-retry
```

Shell script wrapper that retries `apt-get update` + `install` up to 4 times with exponential back-off (5s, 10s, 15s). Prevents transient mirror failures from breaking the build.

### Layer 7: Base Packages

```dockerfile
RUN /bin/sh /usr/local/bin/apt-install-retry \
    apache2 build-essential codespell cpanminus git lsb-release \
    tig libcarp-always-perl libgit-repository-perl libmemcached-tools \
    libmodule-install-perl libperl-critic-perl libtest-differences-perl \
    libtest-perl-critic-perl libtest-perl-critic-progressive-perl \
    libfile-chdir-perl libdata-printer-perl pmtools locales \
    netcat-openbsd python3-gdbm vim nano tmux wget curl \
    apt-transport-https plocate iproute2
```

Key packages:
- **apache2** — Web server for Koha
- **git, tig** — Version control (source management)
- **cpanminus** — Perl module installer
- **libcarp-always-perl** — Perl debugging (always Carp)
- **libperl-critic-perl** — Perl style checking
- **vim, nano, tmux** — Terminal editors/terminal multiplexer
- **netcat-openbsd** — Network troubleshooting

### Layer 8: Locales

```dockerfile
RUN echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && echo "fr_FR.UTF-8 UTF-8" >> /etc/locale.gen \
    && echo "fi_FI.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && dpkg-reconfigure locales \
    && /usr/sbin/update-locale LANG=en_US.UTF-8
```

Installs English (US), French (FR), and Finnish (FI) locales. Defaults to en_US.UTF-8.

### Layer 9: Apache Configuration

```dockerfile
RUN a2dismod mpm_event
RUN a2dissite 000-default
RUN a2enmod rewrite headers proxy_http cgi
```

- **Disables mpm_event** — Uses mpm_prefork instead (Koha needs prefork for some CGI modules)
- **Disables default site** — Will be replaced by Koha's config
- **Enables modules**: rewrite, headers, proxy_http, cgi

### Layer 10: Koha Repository

```dockerfile
RUN curl -s http://debian.koha-community.org/koha/gpg.asc | \
    gpg --dearmor -o /etc/apt/trusted.gpg.d/koha.gpg && \
    chmod 644 /etc/apt/trusted.gpg.d/koha.gpg && \
    echo "deb [signed-by=/etc/apt/trusted.gpg.d/koha.gpg] http://debian.koha-community.org/koha-staging dev main" >> /etc/apt/sources.list.d/koha.list
```

Adds the official Koha APT repository (staging branch, dev release). This is where `koha-common` package comes from.

### Layer 11: koha-common

```dockerfile
RUN /bin/sh /usr/local/bin/apt-install-retry \
    koha-common \
    && /etc/init.d/koha-common stop \
    && rm -rf /usr/share/koha/misc/translator/po/*
```

Installs the core Koha package, stops the service, and removes translation PO files (saves space).

### Layer 12: Working Directory

```dockerfile
RUN mkdir /kohadevbox
WORKDIR /kohadevbox
```

Creates the development root. The Koha source is bind-mounted here.

### Layer 13: Development Packages

```dockerfile
RUN /bin/sh /usr/local/bin/apt-install-retry \
    perltidy libexpat1-dev libtemplate-plugin-gettext-perl \
    libdevel-cover-perl libmoosex-attribute-env-perl \
    libtest-dbix-class-perl libtap-harness-junit-perl \
    libtext-csv-unicode-perl libdevel-cover-report-clover-perl \
    libwebservice-ils-perl libselenium-remote-driver-perl
```

Key dev packages:
- **perltidy** — Perl code formatter
- **libdevel-cover-perl** — Code coverage
- **libtemplate-plugin-gettext-perl** — Template engine localization
- **libwebservice-ils-perl** — ILS API (circulation, patron services)
- **libselenium-remote-driver-perl** — Browser automation testing
- **libtest-dbix-class-perl** — DBIx::Class testing

### Layer 14-15: Node.js & Yarn Repositories

```dockerfile
RUN wget -O- -q https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor \
    | tee /usr/share/keyrings/nodesource.gpg >/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list

RUN wget -O- -q https://dl.yarnpkg.com/debian/pubkey.gpg \
    | gpg --dearmor \
    | tee /usr/share/keyrings/yarnkey.gpg >/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/yarnkey.gpg] https://dl.yarnpkg.com/debian stable main" > /etc/apt/sources.list.d/yarn.list
```

Adds Node.js 20.x and Yarn repositories.

### Layer 16: Node.js & Yarn

```dockerfile
RUN /bin/sh /usr/local/bin/apt-install-retry \
    nodejs yarn

RUN yarn global add gulp-cli
```

Installs Node.js and Yarn. Also installs `gulp-cli` globally for Koha frontend builds.

### Layer 17: Frontend Dependencies

```dockerfile
RUN cd /kohadevbox \
    && wget -q https://gitlab.com/koha-community/Koha/-/raw/main/package.json?inline=false -O package.json \
    && wget -q https://gitlab.com/koha-community/Koha/-/raw/main/yarn.lock?inline=false -O yarn.lock \
    && yarn cache clean \
    && yarn install --modules-folder /kohadevbox/node_modules \
    && mv /root/.cache/Cypress /kohadevbox && chown -R 1000 /kohadevbox/Cypress \
    && rm -f package.json yarn.lock
```

Downloads and installs JavaScript dependencies:
- `package.json` + `yarn.lock` from Koha's GitLab repo
- Installs to `/kohadevbox/node_modules` (for bind-mount visibility)
- Moves Cypress cache to the bind-mount dir
- Cleans up temp files

### Layer 18: git-bz Helper

```dockerfile
RUN cd /kohadevbox \
    && git clone --depth 1 https://gitlab.com/koha-community/perl-git-bz.git \
    && cd perl-git-bz && cpanm --installdeps . \
    && ln -s /kohadevbox/perl-git-bz/bin/git-bz /usr/bin/git-bz
```

Installs `git-bz` — Bugzilla integration for git. Creates a symlink so it's accessible as a system command.

### Layer 19: Helper Repositories

```dockerfile
RUN cd /kohadevbox \
    && git clone https://gitlab.com/koha-community/koha-misc4dev.git   misc4dev \
    && git clone https://gitlab.com/koha-community/koha-gitify.git     gitify \
    && git clone https://gitlab.com/koha-community/qa-test-tools.git   qa-test-tools \
    && chown -R 1000 misc4dev gitify qa-test-tools
```

Clones development helper tools:
- **koha-misc4dev** — Sample data, utilities
- **koha-gitify** — Git workflow helper
- **qa-test-tools** — QA testing tools

### Layer 20: How-To Guide

```dockerfile
RUN cd /kohadevbox \
    && git clone https://gitlab.com/koha-community/koha-howto.git howto
```

Clones the Koha how-to documentation.

### Layer 21: Utility Packages

```dockerfile
RUN /bin/sh /usr/local/bin/apt-install-retry \
    bugz inotify-tools
```

- **bugz** — Bugzilla CLI tool
- **inotify-tools** — File system monitoring (for auto-reload)

### Layer 22: Cypress Testing

```dockerfile
RUN /bin/sh /usr/local/bin/apt-install-retry \
    libgtk2.0-0t64 libgtk-3-0t64 libgbm-dev libnotify-dev \
    libnss3 libxss1 libasound2t64 libxtst6 xauth xvfb
```

Ubuntu 24.04 specific: `t64` variants and `libgconf-2-4` removed. Required for Cypress end-to-end testing.

### Layer 23: koha-reload-starman

```dockerfile
RUN cd /kohadevbox \
    && wget https://gitlab.com/mjames/koha-reload-starman/-/raw/master/koha-reload-starman \
    && chmod 755 koha-reload-starman
```

Downloads a utility for hot-reloading Koha with Starman (Perl web server).

### Layer 24: Volumes & COPY

```dockerfile
VOLUME /kohadevbox/koha

COPY files/run.sh /kohadevbox/
COPY files/templates /kohadevbox/templates
COPY files/git_hooks /kohadevbox/git_hooks
COPY env/defaults.env /kohadevbox/templates/defaults.env
```

- Declares `/kohadevbox/koha` as a volume (bind mount target)
- Copies runtime scripts, templates, git hooks, and default env

### Layer 25: CRLF Normalization

```dockerfile
RUN sed -i 's/\r$//' /kohadevbox/run.sh \
    && find /kohadevbox/templates -type f -exec sed -i 's/\r$//' {} + \
    && find /kohadevbox/git_hooks  -type f -exec sed -i 's/\r$//' {} + \
    && chmod +x /kohadevbox/run.sh
```

Ensures Linux line endings for all scripts (cross-platform safety). See ISSUES.md #11.

### Layer 26: Final Config

```dockerfile
EXPOSE 6001 8080 8081

CMD ["/bin/bash", "/kohadevbox/run.sh"]
```

- **6001** — Starman (Perl web server, optional)
- **8080** — OPAC (Apache)
- **8081** — Staff (Apache)
- CMD runs the entrypoint script

---

## Image Size Estimate

| Category | Approximate Size |
|---|---|
| ubuntu:24.04 base | ~75 MB |
| Apache + Perl + koha-common | ~500 MB |
| Node.js + Yarn + node_modules | ~300 MB |
| Development tools | ~200 MB |
| Git repos (misc4dev, etc.) | ~100 MB |
| **Total** | **~1.2 GB** |

---

## Build Time

| Phase | Approximate Time |
|---|---|
| Base apt packages | 1-3 min |
| koha-common | 1-2 min |
| Node.js + Yarn install | 2-4 min |
| Git clones | 1-2 min |
| Cypress packages | 1-2 min |
| **Total** | **6-13 min** |
