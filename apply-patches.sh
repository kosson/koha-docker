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

  # If reverse-check succeeds, the patch is already applied.
  if git -C "${KOHA_DIR}" apply --reverse --check "${patch}" >/dev/null 2>&1; then
    echo "SKIP  ${patch_name} (already applied)"
    continue
  fi

  git -C "${KOHA_DIR}" apply --check "${patch}"
  git -C "${KOHA_DIR}" apply "${patch}"
  echo "APPLY ${patch_name}"
done

echo "Done. Current Koha changes:"
git -C "${KOHA_DIR}" status --short
