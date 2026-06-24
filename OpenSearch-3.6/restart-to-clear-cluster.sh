#!/usr/bin/env bash
# Reset OpenSearch-3.6 to a clean bootstrap state.
#
# What it does:
# 1) Stops/removes only this compose project's containers/networks.
# 2) Removes bind-mounted node data (os01-os05).
# 3) Removes generated TLS materials under assets/ssl.
# 4) Removes the local OpenSearch image tag so next run rebuilds from scratch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "[1/4] Bringing down OpenSearch compose project..."
docker compose down --remove-orphans || true

echo "[2/4] Removing bind-mounted OpenSearch node data..."
rm -rf assets/opensearch/data/os0{1,2,3,4,5}data/*

echo "[3/4] Removing generated TLS credentials..."
rm -rf assets/ssl/*

echo "[4/4] Removing local OpenSearch image tag (if present)..."
if [[ -f .env ]]; then
	set -a
	# shellcheck disable=SC1091
	source .env
	set +a
fi

OPEN_SEARCH_VERSION="${OPEN_SEARCH_VERSION:-3.6.0}"
IMAGE_TAG="kosson/opensearch-icu:${OPEN_SEARCH_VERSION}"
docker image rm "${IMAGE_TAG}" >/dev/null 2>&1 || true

echo ""
echo "OpenSearch cluster reset complete."
echo "Next steps:"
echo "  1) ./opensearch_local_certificates_creator.sh"
echo "  2) docker compose build os01"
echo "  3) docker compose up -d os01 os02 os03 os04 os05"