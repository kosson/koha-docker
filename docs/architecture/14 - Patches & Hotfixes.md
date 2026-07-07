---
title: "Patches & Hotfixes"
tags: [patches, hotfixes, git-bz, sql-mode, only-full-group-by, apply-patches.sh, patch-management, koha-patches, auth-tag-structure]
---
# Patches & Hotfixes

How patches are managed in the Koha source tree.

## Patch Directory

Location: `~/Documents/koha-docker/patches/`

Contains `.patch` files applied to the Koha source tree.

## Active Patches

### 0001-auth-tag-structure-only-full-group-by.patch

**Purpose**: Fixes authority-type editor for `ONLY_FULL_GROUP_BY` SQL mode in MariaDB 10.x.

**File affected**: `koha/admin/auth_tag_structure.pl`

**Problem**: Koha's auth tag structure editor uses GROUP BY without ORDER BY, which violates MariaDB's `ONLY_FULL_GROUP_BY` SQL mode. This causes SQL errors when saving authority type changes.

**Fix**: Adds `ORDER BY` to the GROUP BY clause, satisfying the SQL mode requirement.

**How to apply**:
```bash
./apply-patches.sh
```

**How to check status**:
```bash
git -C ~/Documents/koha status --short
# Look for: M koha/admin/auth_tag_structure.pl
```

## Patch Management Script

### `apply-patches.sh`

Location: `~/Documents/koha-docker/apply-patches.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
KOHA_DIR="${ROOT_DIR}/koha"
PATCH_GLOB=("${ROOT_DIR}"/patches/*.patch)

if [[ ! -d "${KOHA_DIR}" ]]; then
  echo "ERROR: koha source directory not found: ${KOHA_DIR}" >&2
  exit 1
fi

if [[ ! -e "${PATCH_GLOB[0]}" ]]; then
  echo "No patch files found in ${ROOT_DIR}/patches" >&2
  exit 0
fi

for patch in "${PATCH_GLOB[@]}"; do
  patch_name="$(basename "${patch}")"

  # Skip if already applied (reverse check)
  if git -C "${KOHA_DIR}" apply --reverse --check "${patch}" >/dev/null 2>&1; then
    echo "SKIP  ${patch_name} (already applied)"
    continue
  fi

  # Validate patch, then apply
  git -C "${KOHA_DIR}" apply --check "${patch}"
  git -C "${KOHA_DIR}" apply "${patch}"
  echo "APPLY ${patch_name}"
done

echo "Done. Current Koha changes:"
git -C "${KOHA_DIR}" status --short
```

### How It Works

1. Finds all `*.patch` files in the patches directory
2. For each patch, checks if it's already applied using `git apply --reverse --check`
3. If not applied: validates the patch (`--check`), then applies it
4. Skips already-applied patches (idempotent)
5. Reports final git status

### Adding a New Patch

```bash
# 1. Create the patch from Koha source
cd ~/Documents/koha
git diff > ../koha-docker/patches/0002-my-fix.patch

# 2. Or create manually
cat > ~/Documents/koha-docker/patches/0002-my-fix.patch <<'EOF'
--- a/koha/admin/some_file.pl
+++ b/koha/admin/some_file.pl
@@ -line,start @@
-old code
+new code
EOF

# 3. Apply the patch
cd ~/Documents/koha-docker
./apply-patches.sh
```

### Removing a Patch

```bash
# Option 1: Remove the patch file
rm ~/Documents/koha-docker/patches/0001-auth-tag-structure-only-full-group-by.patch

# Option 2: Reverse apply (keep the file, undo the change)
git -C ~/Documents/koha apply --reverse ~/Documents/koha-docker/patches/0001-auth-tag-structure-only-full-group-by.patch
```

### Reapplying All Patches

If the Koha source is reset (e.g., after a git reset), patches need to be re-applied:

```bash
cd ~/Documents/koha-docker
./apply-patches.sh
```

## Patch Naming Convention

Format: `NNNN-short-description.patch`

- `NNNN`: Sequential number (zero-padded)
- `short-description`: Underscore-separated description
- Example: `0001-auth-tag-structure-only-full-group-by.patch`

Patches are applied in filename order. If patches have dependencies, order matters.

## Troubleshooting

### Patch Fails to Apply

```bash
# Check what's wrong
git -C ~/Documents/koha apply --check ~/Documents/koha-docker/patches/0001-my-fix.patch

# Output will show the conflict
# Fix by updating the patch to match the current Koha source
```

### Patch Already Applied

```bash
# The script skips already-applied patches
# Check if the patch is applied:
git -C ~/Documents/koha apply --reverse --check ~/Documents/koha-docker/patches/0001-my-fix.patch
# Exit code 0 = already applied, 1 = not applied
```

### Patch Doesn't Match After Koha Update

When Koha source is updated (e.g., `git pull`), patches may fail because the line numbers don't match.

**Fix**:
1. Re-apply the patch against the new Koha source:
   ```bash
   cd ~/Documents/koha
   git diff > ../koha-docker/patches/0001-new-version.patch
   ```
2. Replace the old patch file
