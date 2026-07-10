<!-- markdownlint-disable MD032 MD013 -->

# Koha-misc4dev Runtime Map for `run.sh`

## Scope

This report documents the `koha-misc4dev` scripts that are reached from `files/run.sh`, the files they copy or create, and the database state they seed during startup.

Important context:

- `files/run.sh` is the container entrypoint, but it is baked into the image at build time and executed later when the container starts.
- `koha-misc4dev` is cloned into the image at build time and may be replaced at runtime if `DEBUG_GIT_REPO_MISC4DEV=yes`.
- The real startup path is therefore: image build -> container start -> `run.sh` -> `koha-misc4dev` helpers.

## Direct `run.sh` invocations into `koha-misc4dev`

`run.sh` directly executes only two scripts from `koha-misc4dev`:

1. `cp_debian_files.pl`
2. `do_all_you_can_do.pl`

Everything else in this report is either a transitive call from `do_all_you_can_do.pl` or a runtime mutation that changes how those scripts behave.

## Startup mutations that affect `koha-misc4dev`

Before the direct script calls happen, `run.sh` can alter the checkout in two ways:

- If `DEBUG_GIT_REPO_MISC4DEV=yes`, it deletes `/kohadevbox/misc4dev` and clones a fresh repository into that path.
- If `LOAD_DEMO_DATA=no`, it overwrites `/kohadevbox/misc4dev/insert_data.pl` with a tiny Perl no-op and marks it executable.

That second branch is important: `do_all_you_can_do.pl` still runs `insert_data.pl`, but the file has been replaced with a stub so sample records are skipped while the rest of the installation continues normally.

## 1) `cp_debian_files.pl`

### Where it runs

`run.sh` calls:

- `perl /kohadevbox/misc4dev/cp_debian_files.pl --instance ... --koha_dir ... --gitify_dir ...`

### What it does

`cp_debian_files.pl` is the script that stages the Debian/Koha runtime layout inside the container. It reads `koha/debian/koha-common.install` from the mounted Koha source tree and copies the listed files into their package-style destinations.

The contents of the `koha-common.install` is:

```text
debian/tmp/usr/*                            usr
debian/tmp/etc/koha/zebradb/[!z]*
debian/tmp/etc/koha/z3950
debian/templates/* etc/koha
debian/koha-post-install-setup              usr/sbin
debian/unavailable.html                     usr/share/koha/intranet/htdocs
debian/unavailable.html                     usr/share/koha/opac/htdocs
debian/templates/*                          etc/koha
debian/scripts/koha-functions.sh            usr/share/koha/bin
debian/scripts/koha-create                  usr/sbin
debian/scripts/koha-create-dirs             usr/sbin
debian/scripts/koha-disable                 usr/sbin
debian/scripts/koha-dump                    usr/sbin
debian/scripts/koha-dump-defaults           usr/sbin
debian/scripts/koha-elasticsearch           usr/sbin
debian/scripts/koha-email-disable           usr/sbin
debian/scripts/koha-email-enable            usr/sbin
debian/scripts/koha-enable                  usr/sbin
debian/scripts/koha-es-indexer              usr/sbin
debian/scripts/koha-foreach                 usr/sbin
debian/scripts/koha-indexer                 usr/sbin
debian/scripts/koha-list                    usr/sbin
debian/scripts/koha-mysql                   usr/sbin
debian/scripts/koha-passwd                  usr/sbin
debian/scripts/koha-plack                   usr/sbin
debian/scripts/koha-rebuild-zebra           usr/sbin
debian/scripts/koha-remove                  usr/sbin
debian/scripts/koha-reset-passwd            usr/sbin
debian/scripts/koha-restore                 usr/sbin
debian/scripts/koha-run-backups             usr/sbin
debian/scripts/koha-shell                   usr/sbin
debian/scripts/koha-sip                     usr/sbin
debian/scripts/koha-sitemap                 usr/sbin
debian/scripts/koha-translate               usr/sbin
debian/scripts/koha-upgrade-schema          usr/sbin
debian/scripts/koha-upgrade-to-3.4          usr/sbin
debian/scripts/koha-worker                  usr/sbin
debian/scripts/koha-z3950-responder         usr/sbin
debian/scripts/koha-zebra                   usr/sbin
debian/tmp_docbook/*.8                      usr/share/man/man8
```

### Files it copies or creates

The script has three main output patterns:

1. Package payload copy from the install manifest.
   - Copies files from `koha/debian/koha-common.install` entries such as:
     - `debian/tmp/usr/*` -> `/usr`
     - `debian/tmp/etc/koha/zebradb/[!z]*` -> `/etc/koha/zebradb/...`
     - `debian/tmp/etc/koha/z3950` -> `/etc/koha/z3950`
     - `debian/templates/*` -> `/etc/koha`
     - `debian/koha-post-install-setup` -> `/usr/sbin`
     - `debian/unavailable.html` -> both `/usr/share/koha/intranet/htdocs` and `/usr/share/koha/opac/htdocs`
     - `debian/scripts/*` -> `/usr/sbin` or `/usr/share/koha/bin`
     - `debian/tmp_docbook/*.8` -> `/usr/share/man/man8`

2. Debian system file refresh.
   - Copies specific files to fixed system locations:
     - `debian/koha-common.bash-completion` -> `/etc/bash_completion.d/koha-common`
     - `debian/koha-common.cron.d` -> `/etc/cron.d/koha-common`
     - `debian/koha-common.cron.daily` -> `/etc/cron.daily/koha-common`
     - `debian/koha-common.cron.hourly` -> `/etc/cron.hourly/koha-common`
     - `debian/koha-common.cron.monthly` -> `/etc/cron.monthly/koha-common`
     - `debian/koha-common.default` -> `/etc/default/koha-common`
     - `debian/koha-common.init` -> `/etc/init.d/koha-common`
     - `debian/koha-common.logrotate` -> `/etc/logrotate.d/koha-common`

3. Manpage generation and Koha site refresh.
   - Runs `xsltproc` to generate manpages into `/usr/share/man/man8/`.
   - Deletes stale `koha-*.8.gz` files and recompresses the generated manpages.
   - Copies `debian/templates/apache-shared*.conf` into `/etc/koha/`.
   - Removes `/etc/koha/apache-shared-opac-git.conf` and `/etc/koha/apache-shared-intranet-git.conf`.
   - Runs `koha-gitify` from `gitify/` to refresh the instance site configuration under `/etc/koha/sites/$instance`.
   - Chowns `/etc/koha/sites/$instance` back to the instance user.

### Runtime effect in the container

This script is the main reason the container gets a Debian-like runtime filesystem even though it is being driven by a checkout and not by a package manager.

In practice, it:

- populates `/usr/sbin`, `/usr/share/koha/bin`, `/etc/koha`, `/etc/init.d`, `/etc/default`, and `/usr/share/man/man8`
- refreshes Apache shared configuration files under `/etc/koha`
- prepares the instance-specific Koha site layout through `koha-gitify`

## 2) `do_all_you_can_do.pl`

### Where it runs

`run.sh` calls:

- `perl /kohadevbox/misc4dev/do_all_you_can_do.pl --instance ... --userid ... --password ... --marcflavour ... --koha_dir ... --opac-base-url ... --intranet-base-url ... --gitify_dir ...`

It may also pass:

- `--elasticsearch`
- `--use-existing-db`

depending on `KOHA_ELASTICSEARCH` and the database probe in `run.sh`.

### What it does

This is the main orchestrator. It decides whether the database is fresh or already populated, then applies the rest of the startup pipeline.

### Database behavior

At startup it checks `systempreferences` and `borrowers`:

- If the database already has data and `--use-existing-db` was not passed, it dies with `Database is not empty!`.
- If the database is empty, it proceeds with a fresh install.
- If `--use-existing-db` is passed, it reuses the existing schema and data.

### Transitive scripts it runs and their effects

#### `populate_db.pl`

Called only on a fresh database.

What it does:

- Loads the Koha schema into the database via `C4::Installer->load_db_schema`.
- Inserts the core sample SQL/YAML data files from `installer/data/mysql`.
- Inserts MARC sample records based on the selected MARC flavour.
- Creates base system preferences such as `marcflavour` and `Version`.
- Resets Elasticsearch mappings.

Filesystem side effects:

- No new persistent files are created in the container filesystem by this script itself.
- It reads data files from the mounted Koha source tree and writes database state only.

Database side effects:

- Creates the full Koha schema.
- Seeds configuration tables, sample notices, permissions, keyboard shortcuts, account types, and sample language-specific records.

#### `create_superlibrarian.pl`

Called only on a fresh database.

What it does:

- Finds a usable branch and patron category from the seeded database.
- Creates the superlibrarian patron record.
- Hashes and stores the configured password.

Filesystem side effects:

- None.

Database side effects:

- Inserts one patron with `flags = 1` and the configured userid/password.

#### `insert_data.pl`

Called only on a fresh database.

What it does:

- Loads the sample bibliographic, authority, item, and language data files under `installer/data/mysql`.
- Chooses the file sets based on Koha version and MARC flavour.
- Sets `PatronSelfRegistration`, `WebBasedSelfCheck`, and related defaults.
- Adds the self-registration category row.
- Inserts sample records and optional language data.

Filesystem side effects:

- None directly; it reads the SQL/YAML seed files from the Koha source tree.

Database side effects:

- Populates sample bibliographic and authority data.
- Adds sample item and configuration records.
- Sets `systempreferences` rows for `marcflavour` and `Version`.
- Reinitializes Elasticsearch mappings.

#### `cp_debian_files.pl`

Called again from inside `do_all_you_can_do.pl`.

What it does:

- Repeats the Debian-file staging step so the instance gets the correct package layout after the database is created.

Filesystem side effects:

- Same as the direct `run.sh` invocation: copies Debian package payload files, regenerates manpages, refreshes `/etc/koha`, and chowns the instance site directory.

#### `cp_zebra_files.pl`

Called from inside `do_all_you_can_do.pl`.

What it does:

- Copies the Zebra MARC definition files from `koha/etc/zebradb/marc_defs/` into `/etc/koha/zebradb/marc_defs/`.

Filesystem side effects:

- Refreshes the Zebra definition directory inside the container.

Database side effects:

- None.

#### `setup_sip.pl`

Called from inside `do_all_you_can_do.pl`.

What it does:

- Copies `/etc/koha/SIPconfig.xml` to `/etc/koha/sites/$instance/SIPconfig.xml`.
- Creates a SIP user in Koha with the configured credentials.
- Starts or restarts the SIP service for the instance.

Filesystem side effects:

- Creates or refreshes `/etc/koha/sites/$instance/SIPconfig.xml`.

Database side effects:

- Adds the SIP patron row used by the instance.

#### `reset_plack.pl`

Called from inside `do_all_you_can_do.pl`.

What it does:

- Copies `debian/templates/plack.psgi` to `/etc/koha/sites/$instance/plack.psgi`.
- Rewrites paths inside that file so they point at the mounted Koha checkout.
- Restarts Plack.

Filesystem side effects:

- Creates or refreshes `/etc/koha/sites/$instance/plack.psgi`.

Database side effects:

- None.

### What `do_all_you_can_do.pl` itself does after those script calls

After the fresh-install scripts, it continues with non-`koha-misc4dev` runtime work:

- enables or reuses the search backend choice in `systempreferences`
- runs `koha-rebuild-zebra`
- optionally rebuilds Elasticsearch/OpenSearch indexes
- restarts Apache
- optionally runs `yarn build` or `yarn build_js`
- optionally installs plugins

Those steps matter for the full container startup sequence, but they are outside `koha-misc4dev`.

## 3) Runtime output map by script

### Filesystem outputs

- `/etc/koha/` is populated by `cp_debian_files.pl` and later refreshed by `reset_plack.pl` and `setup_sip.pl`.
- `/etc/koha/sites/$instance/` is populated by `koha-gitify`, `reset_plack.pl`, and `setup_sip.pl`.
- `/etc/koha/zebradb/marc_defs/` is refreshed by `cp_zebra_files.pl`.
- `/usr/share/man/man8/koha-*.8.gz` is generated by `cp_debian_files.pl`.
- `/usr/sbin/*` and `/usr/share/koha/bin/*` are staged by `cp_debian_files.pl` from the Koha Debian manifest.

### Database outputs

- `populate_db.pl` creates the Koha schema and base configuration.
- `create_superlibrarian.pl` inserts the admin user.
- `insert_data.pl` seeds the sample catalog, authorities, and demo config.
- `setup_sip.pl` inserts the SIP user.

## 4) What matters for the Alpine migration

If the goal is to drop `koha-misc4dev` and replace it with Bash, the behavior that must be reimplemented is not just the direct `run.sh` calls. The full equivalent needs to cover:

1. Debian-file staging from `cp_debian_files.pl`.
2. Koha schema and sample-data bootstrap from `populate_db.pl` and `insert_data.pl`.
3. Superlibrarian creation from `create_superlibrarian.pl`.
4. Zebra definition copy from `cp_zebra_files.pl`.
5. SIP config copy and SIP user creation from `setup_sip.pl`.
6. Plack PSGI generation from `reset_plack.pl`.
7. The `LOAD_DEMO_DATA=no` no-op override for `insert_data.pl`.
8. The `KOHA_ELASTICSEARCH=yes` runtime patching of `do_all_you_can_do.pl` that suppresses Zebra failure and makes Elasticsearch rebuild non-fatal.

That list is the practical migration boundary: if a Bash replacement does not reproduce those outputs, the container startup behavior will diverge from the current Debian-based flow.
