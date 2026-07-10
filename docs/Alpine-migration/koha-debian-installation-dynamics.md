<!-- markdownlint-disable MD032 MD013 -->

# Koha Debian Installation Dynamics

## Scope

This report explains how Koha is installed and activated on a Debian system from the contents of `koha/debian/`. It walks through the sequence of events in installation order, explains what each step changes on the host, and ends with a comparison against the `koha-misc4dev` runtime bootstrap flow used in the container entrypoint.

The main files examined here are:

- `koha/debian/koha-common.install`
- `koha/debian/koha-common.preinst`
- `koha/debian/koha-common.config`
- `koha/debian/koha-common.postinst`
- `koha/debian/scripts/koha-create`
- `koha/debian/scripts/koha-create-dirs`
- `koha/debian/scripts/koha-enable`
- `koha/debian/scripts/koha-plack`
- `koha/debian/scripts/koha-sip`
- `koha/debian/scripts/koha-rebuild-zebra`

The package metadata in `koha/debian/control` matters too, because it shows Koha is split into Debian packages and that `koha-common` carries the runtime tooling and shared configuration while the `koha` package depends on it.

## Big Picture

Koha on Debian is not a single install script. It is a package lifecycle:

1. Debian package metadata defines what gets installed.
2. `preinst` clears out old filesystem obstacles before unpacking.
3. The `.install` manifest copies application code, helper scripts, templates, docs, and default config material into the system.
4. `config` asks debconf questions and persists upgrade preferences.
5. `postinst` upgrades databases, updates config, migrates Apache files, patches logging, repairs Zebra paths, and restarts services.
6. Later instance-oriented commands such as `koha-create`, `koha-enable`, `koha-plack`, `koha-sip`, and `koha-rebuild-zebra` turn the package into a live Koha site.

That split is the key difference from the container bootstrap approach: Debian installation spreads side effects across package scripts and instance commands, while the container entrypoint uses `koha-misc4dev` to collapse most of the same outcomes into one startup path.

## 1) What the Debian packages lay down

`koha/debian/koha-common.install` is the manifest that tells the Debian build what files belong in the package payload.

The manifest installs three broad classes of content:

1. Runtime tree and helper binaries.
   - Files from `debian/tmp/usr/*` land under `/usr`.
   - `/usr/sbin` receives Koha admin commands such as `koha-create`, `koha-enable`, `koha-plack`, `koha-sip`, `koha-rebuild-zebra`, `koha-shell`, `koha-mysql`, and others.
   - `/usr/share/koha/bin/koha-functions.sh` is installed as the shared shell helper library used by most Koha wrapper scripts.

2. Default Koha configuration and instance templates.
   - `debian/templates/*` is copied into `/etc/koha`.
   - These templates are the source material for Apache vhosts, Koha site config, Plack config, SIP config, Zebra config, logging config, and other instance-specific files.

3. Package-owned system glue.
   - `/etc/koha/zebradb/*` and `/etc/koha/z3950` are seeded.
   - `/usr/share/man/man8` gets generated manpages.
   - `/etc/init.d/koha-common`, `/etc/default/koha-common`, cron entries, bash-completion, and logrotate config are installed.

Practical effect:

- The package does not just install code. It establishes the control plane needed to run Koha like a Debian service: startup scripts, config templates, shell helpers, logging, cron jobs, and manpages.

## 2) Installation sequence in order

### Step 1. `preinst` removes old symlink blockers

`koha-common.preinst` is intentionally small and defensive. It removes two legacy symlinks if they exist:
`koha-misc4dev` is about repeatable container bootstrap.

- `/usr/share/koha/opac/htdocs/opac-tmpl/lib/yui`
- `/usr/share/koha/intranet/htdocs/intranet-tmpl/lib/tiny_mce`

Why this matters:

- These symlinks can block upgrades if the package wants to replace them with real files or different paths.
- Debian runs `preinst` before unpacking the new package, so this is a preflight cleanup step to keep upgrades from failing on filesystem conflicts.

### Step 2. Debian unpacks the package payload

The package manager then unpacks the files listed in the `.install` manifest.

The visible effect on the host is immediate:

- `/usr/sbin` gains the Koha management commands.
- `/usr/share/koha/bin` gains shared shell functions.
- `/etc/koha` gains default templates and shared config fragments.
- `/usr/share/man/man8` gains Koha manpages.
- `/etc/koha/zebradb` and `/etc/koha/z3950` are populated.

This is the stage where the system first acquires the Debian-native Koha toolchain.

### Step 3. `config` captures upgrade choices in debconf

`koha-common.config` and `koha-core.config` ask debconf questions and use `/etc/koha/koha-common.conf` as a local state file.

The important behaviors are:

- `AUTOMATIC_TRANSLATIONS_UPDATE` is mirrored into debconf state.
- Upgrade notices are shown for old package transitions.
- If existing Apache vhost files appear to use the old naming scheme, debconf can prompt whether they should be renamed.

Why this matters:

- Debian package configuration is treated as state, not just one-time output.
- The package remembers whether translations should be updated automatically and whether Apache vhost migration should occur.

### Step 4. `postinst` performs the actual system mutation

`koha-common.postinst` is where the package becomes a live Koha system.

Its sequence is roughly:

1. Read `/etc/koha/koha-common.conf` if it exists.
2. Ensure `/etc/mysql/koha-common.cnf` exists as a symlink to the Debian MySQL credentials file if needed.
3. Run `koha-upgrade-schema $(koha-list)`.
4. Create `/etc/koha/koha-common.conf` if it does not already exist.
5. Persist the debconf choice for automatic translation updates.
6. Update template translations if the setting says to do so.
7. Detect old-style Apache vhost file names and optionally rename them to `*.conf`.
8. Append missing Log4perl appenders to each instance's `log4perl.conf`.
9. Fix ownership of log directories.
10. Patch Zebra config module paths for multiarch systems.
11. Stop the database service, enable RabbitMQ STOMP, restart RabbitMQ and Memcached, and refresh `koha-common` startup ordering with `update-rc.d`.

The important side effects are described below.

## 3) What `postinst` changes on disk and in services

### Database and schema side effects

`koha-upgrade-schema $(koha-list)` is the main database action.

What it changes:

- Existing Koha instances have their schema upgraded to the package version.
- If there are no instances, the call is effectively inert.

This is different from a fresh bootstrap: it is an upgrade mechanism, not a data loader.

### Configuration side effects

If `/etc/koha/koha-common.conf` does not exist, `postinst` creates it with the default translation-update setting.

It also normalizes the value from debconf into that file, so the package can remember the operator's preference across upgrades.

### Apache migration side effects

If any vhost is still named without the `.conf` suffix, `postinst` can rename:

- `/etc/apache2/sites-available/<instance>` -> `/etc/apache2/sites-available/<instance>.conf`

It also disables and re-enables the site where needed.

Why this matters:

- The package is not just shipping Apache config. It is maintaining compatibility with Apache's naming conventions and preserving enabled/disabled state.

### Logging side effects

`postinst` appends Log4perl sections to each instance's `log4perl.conf` if they are missing.

It adds logging for:

- Z39.50
- API
- SIP
- Plack OPAC
- Plack API
- Plack intranet
- worker
- edi

This means the package actively extends runtime observability, not just application behavior.

### Zebra and multiarch side effects

The package patches Zebra config files so `modulePath` includes architecture-specific directories.

That change keeps Zebra working on systems where the module libraries do not live only in one hard-coded path.

### Service side effects

`postinst` restarts or reorders core services:

- RabbitMQ is restarted after enabling the STOMP plugin.
- Memcached is restarted.
- `koha-common` is disabled and enabled again in `update-rc.d` to correct startup ordering.

This is important because Koha depends on these background services at runtime.

## 4) The instance creation phase

Package installation alone does not create a working Koha instance. That job is handled by `koha-create` and its helper scripts.

### `koha-create`

`koha-create` is the main instance bootstrap command installed by the package.

It can create a new instance in several modes, but the important runtime behavior is that it generates instance-specific config from templates and wires the instance into Apache, the database, Memcached, RabbitMQ, and Koha's runtime paths.

Key effects:

- Reads `/etc/default/koha-common` if present.
- Sources `/usr/share/koha/bin/koha-functions.sh`.
- Generates `/etc/koha/sites/<instance>/koha-conf.xml` and related files from `/etc/koha/*.in` templates.
- Checks Apache modules such as `mpm_itk`, `mod_rewrite`, `cgi`, and optionally `ssl`.
- Uses instance/user/database settings to produce a runnable site.

### `koha-create-dirs`

This helper creates the filesystem tree that Koha needs for one instance.

It creates directories under:

- `/var/spool/koha/<instance>`
- `/etc/koha/sites/<instance>`
- `/var/cache/koha/<instance>` and `/var/cache/koha/<instance>/templates`
- `/var/lib/koha/<instance>` and its authorities/biblios/plugins/uploads/tmp subtrees
- `/var/lock/koha/<instance>` and its children
- `/var/run/koha/<instance>` and its children

The directories are created with ownership set to the instance user and group.

Practical effect:

- This is the persistent runtime workspace for the instance. It is where caches, locks, PID files, plugins, uploads, and generated artifacts live.

### `koha-enable`

`koha-enable` turns a Koha instance on at the Apache layer.

What it changes:
`koha-misc4dev` is about repeatable container bootstrap.

- It edits `/etc/apache2/sites-available/<instance>.conf`.
- It uncomments the include of `apache-shared-disable.conf` so the site becomes active.
- It restarts Apache if a site changed.

Practical effect:

- The instance becomes reachable through Apache once enabled.

### `koha-plack`

`koha-plack` manages the Plack daemon for an instance.

Typical effects when starting Plack:

- Uses `/etc/koha/sites/<instance>/plack.psgi` if present, otherwise the default `/etc/koha/plack.psgi`.
- Writes the PID file to `/var/run/koha/<instance>/plack.pid`.
- Writes the socket to `/var/run/koha/<instance>/plack.sock`.
- Writes access and error logs under `/var/log/koha/<instance>/`.
- Runs under the instance user and group.

Practical effect:

- This is what makes the Koha web application process start serving requests.

### `koha-sip`

`koha-sip` manages SIP2 for the instance.

Typical effects:

- Copies `/etc/koha/SIPconfig.xml` to `/etc/koha/sites/<instance>/SIPconfig.xml` when enabling SIP.
- Creates `/var/lib/koha/<instance>/sip.enabled` as the enablement flag.
- Starts a daemon that reads the instance's SIP config.
- Writes SIP logs under `/var/log/koha/<instance>/`.

Practical effect:

- The instance can accept SIP traffic from library hardware or external systems.

### `koha-rebuild-zebra`

`koha-rebuild-zebra` rebuilds Zebra indexes for one or more instances.

What it does:

- Runs the underlying `rebuild_zebra.pl` as the instance user.
- Uses `/etc/koha/sites/<instance>/koha-conf.xml` to locate the instance config.
- Can rebuild biblios, authorities, or both.

Practical effect:`koha-misc4dev` is about repeatable container bootstrap.


- Search indexes are regenerated, which affects catalog search availability and freshness.

## 5) What Debian installation affects on the host

The Debian flow touches several classes of system state:

### Files under `/usr`

- Koha management commands are installed into `/usr/sbin`.
- Shared helper shell functions are installed into `/usr/share/koha/bin`.
- Manpages are installed into `/usr/share/man/man8`.

### Files under `/etc`

- Shared Koha defaults live in `/etc/koha`.
- Instance config lives in `/etc/koha/sites/<instance>`.
- Apache vhost definitions live in `/etc/apache2/sites-available` and `/etc/apache2/sites-enabled`.
- Cron, init, logrotate, and MySQL configuration are all touched.

### Files under `/var`

- Instance caches, uploads, locks, run directories, and logs are created under `/var/cache`, `/var/lib`, `/var/lock`, `/var/run`, and `/var/log`.

### Services

- Apache is renamed, enabled, disabled, and restarted.
- RabbitMQ is configured for STOMP and restarted.
- Memcached is restarted.
- Zebra indexing is rebuilt.

### Database

- Existing instances are upgraded by `koha-upgrade-schema`.
- Instance-level data is not created by package install alone; it is created by `koha-create` and subsequent instance bootstrap commands.

## 6) Sequence summary in plain language

Here is the Debian installation story in one line per phase:

1. Debian removes old symlink conflicts.
2. Debian copies Koha commands, templates, docs, and defaults into the system.
3. Debconf records upgrade preferences and Apache migration choices.
4. `postinst` upgrades databases, updates config, patches logs, repairs Zebra paths, and restarts core services.
5. `koha-create` turns the package into a concrete instance by generating site-specific config and directory trees.
6. `koha-enable`, `koha-plack`, `koha-sip`, and `koha-rebuild-zebra` activate the web app, SIP, and search/indexing parts of the runtime.

That is the Debian version of "Koha is installed and running." It is distributed across package scripts and instance commands instead of being concentrated in one startup script.

## 7) Comparison with `koha-misc4dev`

The `koha-misc4dev` runtime flow described in [koha-misc4dev-runtime-map.md](koha-misc4dev-runtime-map.md) is the container-oriented counterpart to the Debian packaging flow.

### What they have in common

- Both paths end up copying Debian-style Koha files into place.
- Both paths create instance-level config under `/etc/koha/sites/<instance>`.
- Both paths create database state, seed sample data, and prepare search indexing.
- Both paths depend on the same underlying Koha source tree and the same family of helper scripts.

### What is different

| Aspect | Debian package flow | `koha-misc4dev` flow |
| --- | --- | --- |
| Control model | `dpkg` lifecycle scripts and debconf | One container startup script (`run.sh`) |
| Main goal | Install and maintain a Koha system on the host | Bootstrap a runnable Koha container from source |
| File creation style | Package manager unpacks payload, then postinst mutates system state | Scripts copy, generate, or rewrite files directly at runtime |
| Database flow | `postinst` upgrades existing instances; `koha-create` creates new instances | `do_all_you_can_do.pl` usually creates or reuses the instance database during startup |
| User interaction | Debconf prompts and package upgrade decisions | Environment-variable driven automation |
| Service activation | Apache, RabbitMQ, Memcached, Zebra, SIP are enabled through package commands | The container path activates the same concepts through orchestrated startup calls |

### The important runtime difference

Debian installation is about establishing persistent host state.

- It lays down system files in `/usr`, `/etc`, and `/var`.
- It stores upgrade preferences in debconf and `koha-common.conf`.
- It relies on separate commands such as `koha-create`, `koha-enable`, and `koha-plack` to finish the runtime setup.

`koha-misc4dev` is about repeatable container bootstrap.

- It does not depend on package installation flow being run on the host.
- It directly invokes the same helper family from one startup path.
- It is willing to rewrite scripts such as `insert_data.pl` or patch `do_all_you_can_do.pl` at runtime to make the container start successfully.

So the relationship is:

- Debian packaging defines the durable operating model of Koha on a host.
- `koha-misc4dev` compresses that model into a reproducible container startup sequence.

## 8) What this means for Alpine migration

If the goal is to replace Debian-based behavior with a Bash-only Alpine flow, the things that must be preserved are not just the visible files. The migration has to reproduce the runtime effects:

1. Copy the same Koha runtime payload into the right places.
2. Generate instance configuration from templates.
3. Create the same directory structure and ownership model.
4. Upgrade or initialize the database in the same order.
5. Enable Apache, Plack, SIP, RabbitMQ, Memcached, and Zebra in the same sequence.
6. Preserve the translation, logging, and vhost migration behaviors that Debian currently does automatically.

If any of those steps are omitted, the system may still look installed, but its runtime behavior will diverge from the Debian baseline.
