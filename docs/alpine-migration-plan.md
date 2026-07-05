# Migration to Alpine

The run.sh script is complex:

It uses apt commands (apt update, apt install).
It uses perl, koha-create, koha-shell, koha-gitify, koha-enable, koha-rebuild-zebra, cpanm.
It uses apache2, service commands.
It uses mysql client commands.
It uses yarn, node, npm (implicitly via yarn).
It uses wget, curl, git.
It uses nc (netcat).
It uses sudo.
It uses sed, grep, awk (via awk? No, just sed, grep, tr, cut, head, tail).
It uses bash.
It uses lsb_release.
It uses envsubst.
It uses service for rabbitmq-server, koha-common, apache2.
The user also requested a specific output format:

## Plan for migration to Alpine:

*Base Image*: Change FROM ubuntu:24.04 to FROM perl:5.38-alpine (or alpine:3.19 + install perl). perl:5.38-alpine is a good starting point because it includes perl and cpanminus.

*Package Manager*: Replace apt-get with apk add. Replace apt-install-retry with an apk equivalent or just apk commands since Alpine's apk is generally reliable, but I should keep the retry logic or simplify it.

## System Packages Mapping:

apache2 -> apache2 (Alpine has apache2 or apache2-utils, apache2 package usually includes httpd). Actually, Alpine uses apache2 package.

build-essential -> build-base + musl-dev + perl-dev.

locales -> locales (Alpine has alpine-base or glib? No, alpine usually uses musl which doesn't strictly need locales setup, but glibc apps do. Since we are using perl:alpine, we should check if locales is needed. Usually musl handles this differently. However, koha might expect standard locale files. I might need to install glibc locale support or just set LC_ALL=C and hope, or install glibc locale. Actually, musl supports UTF-8. The script does locale-gen, which is Debian-specific. I need to replace this. In Alpine, you can just export LANG=C.UTF-8.

netcat-openbsd -> netcat-openbsd (available in Alpine).

python3-gdbm -> python3 + py3-gdbm (if needed by koha? koha doesn't usually need python unless for specific scripts. run.sh doesn't use python explicitly except maybe via cpanm or some helper? Ah, run.sh has if [ "${LSB_RELEASE}" = "trixie" ]; then .... No python in run.sh. I should keep python just in case, or remove if not needed. koha uses perl.

libgtk2.0-0t64 etc. (Cypress dependencies). These are heavy. libxcb-xinerama0 etc.
curl, wget -> curl, wget.
git -> git.
vim, nano, tmux -> vim, nano, tmux.

## User/Group Management:

userdel -r ubuntu -> Remove this. Alpine perl image might not have a user or have root. Koha creates its own user (kohadev-koha).

## Perl Modules:

cpanfile handling. The run.sh has if [ "${INSTALL_MISSING_FROM_CPANFILE}" = "yes" ]; then .... This relies on a cpanfile. I should assume the Koha source contains a cpanfile.
cpanm is in perl:alpine.

## Koha Specifics:

koha-common package. CRITICAL: Koha does not provide official Alpine packages. It uses .deb packages. This is the biggest blocker.

Workaround: I can either:

a) Build the Perl modules manually.
b) Use koha from source (which this image seems to do for the main Koha code, but koha-common provides the admin scripts koha-create, koha-shell, etc.).
c) Use dpkg inside the Alpine container to install the .deb files (using dpkg-deb or alien? No, dpkg might work but dependencies are tricky).
d) Use koha from the Ubuntu source repository but install it in a way that fits Alpine? No, koha depends on libdbd-mysql, etc.
e) Best approach for "Complex Perl App" on Alpine: Usually, you keep the infrastructure (apache, mysql) external and run the Perl app. Here, the container runs everything (apache, mysql client, koha-create).

Refined approach: Since koha-common is a .deb, we have a problem. However, koha (the main code) is just perl. We can clone koha from git.
But koha-create is a shell script from koha-common. It relies on system paths.

Alternative: Can we install koha from Debian packages into Alpine using dpkg? dpkg is in Alpine (dpkg package). We can download the .deb and try to install it. It might fail on libmysqlclient.
Alternative: Use the koha source tarball.
Alternative: The image kosson/koha-testing-docker (implied by the context of koha-testing-docker in comments) currently uses Ubuntu.
Actually, there is a way. Koha can run without the koha-common package if you configure it manually, but that's hard.

However, there are community attempts to run Koha on Alpine. The main issue is the precompiled C extensions and the koha-common scripts.

Wait, run.sh calls koha-create. If koha-create is missing, this breaks.

Provide a Dockerfile that uses perl:alpine but acknowledges the koha-common hurdle.

Better Strategy: There is a koha docker image koha (unofficial) or similar.

Actually, the most robust way to use Alpine with Koha (which is heavily dependent on Debian packaging) is to not use Alpine for the main Koha container if it requires koha-create... CRAP.

## Possible plan

Base: perl:5.38-alpine
Install dpkg so we can install koha-common.
Download .deb files from debian.koha-community.org.
dpkg --force-depends -i ... (force dependencies because Alpine uses musl).
Replace Debian specific commands in run.sh with Alpine equivalents (e.g. service -> openrc or just direct script execution, apache2 config paths).
Handle Locales: Use C.UTF-8.
Handle Apache: httpd instead of apache2. Config files differ (httpd.conf).
This is a massive refactoring of run.sh.
Refined Plan: I will generate a plan that highlights:

Base: perl:5.38-alpine.
Packages: Map apt to apk.
Koha Installation: The "Impossible" part. koha-create is Debian specific. Maybe installing koha from the Debian repo using dpkg with --force-depends, as this is the standard way to force Debian apps onto Alpine (though it often fails on C libraries).

Alternative: The "Real" way is to use koha source code and install dependencies via cpanm manually, bypassing koha-create. I will offer this as the robust path. There is a method to the madness, isn't it?

Service Management: service command is from sysvinit/sysvinit-utils. Alpine uses openrc. The run.sh uses service koha-common start. This needs to be changed to start the scripts directly or use openrc if packages allow (unlikely for Koha on Alpine).
Let's look at the run.sh script again.

koha-create, koha-shell, koha-gitify, koha-enable are the critical dependencies on koha-common.

If I remove koha-common, I must rewrite run.sh to do what those scripts do. CRAP!

koha-create essentially creates a user, a db, config files, and copies templates.

**Image Selection**: perl:5.38-alpine.
System Libs: apk add.

**Koha Setup**: Since koha-common is not available for Alpine, we must:
Option A: Install Debian packages via dpkg (Risky, might break on libmysqlclient).
Option B: Use koha source tarball and install dependencies manually (Recommended for stability). Dibs! :D :D :D

**Refactoring run.sh**:
Replace apt -> apk.
Replace locale-gen -> export LANG=C.UTF-8.
Replace service -> direct invocation of httpd and mariadb (or mysql) scripts.
Replace a2ensite -> symlink creation.
Replace koha-create -> Manual creation of directories/users or use koha source scripts if available.

**Dockerfile YAML Content**:

```yaml
FROM perl:5.38-alpine

# Install build tools and musl deps
RUN apk add --no-cache \
    build-base \
    musl-dev \
    perl-dev \
    git \
    wget \
    curl \
    bash \
    openrc \
    apache2 \
    apache2-utils \
    mariadb \
    ...
```

The koha part:

Install koha-common via dpkg (Workaround)
RUN wget http://.../koha-common.deb ... dpkg --force-depends -i koha-common*.deb

Run
*   *Note*: I must warn the user that `dpkg` on Alpine is fragile.

**Refactoring run.sh in the plan**:

The plan must explain how to change run.sh.
apt -> apk.
service apache2 start -> httpd -DFOREGROUND & (or similar).
One detail: perl:5.38-alpine image usually comes with bash? Yes, it does.

Let's check run.sh for specific Debianisms:

dpkg-reconfigure locales -> Remove.
a2dismod, a2enmod -> cd /etc/apache2/conf-enabled && rm ln -s ... (Alpine apache config structure is different, usually /etc/apache2/conf.d/ or similar, or just httpd.conf includes). I'll assume standard Alpine httpd paths.
koha-create -> Needs to exist.

A "Hybrid" approach for the Dockerfile (installing Debian packages into Alpine) because rewriting koha-create logic in the Dockerfile is too complex for a single prompt, and rewriting run.sh to not use koha-create is a major project. However, I will explicitly state that the "Correct" Alpine way involves compiling Koha from source and bypassing koha-create. Given the user's request "create a plan", I will outline the migration path.

Introduction: Ack perl:5-alpine.
Strategy:
Base: perl:5.38-alpine.
System Packages: Map to apk.
Koha Installation: Use dpkg to force install koha-common (with caveats) OR install from source. I will provide the dpkg method in the YAML as it preserves the run.sh compatibility (mostly), but the Source method is recommended for production.
Scripts: Rewrite run.sh for Alpine (service -> direct execution, apt -> apk).

File content:

Title: Alpine Linux Migration Plan.
Sections: Prerequisites, Package Mapping, Dockerfile Changes, Run.sh Refactoring, Testing.
Code block: The Dockerfile.
Refining the Dockerfile:

I'll use apk add for everything possible.
I'll add the dpkg download section for koha-common.
I'll remove the userdel -r ubuntu (Alpine doesn't have ubuntu user).
I'll add the locales workaround (just export LANG=C.UTF-8).
I'll change `a2*