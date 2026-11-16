#!/usr/bin/env bash
# Valide la configuration de l'agent Prometheus avec promtool.
# Usage : k8s/kind/check-agent-config.sh <kind|aws>
set -euo pipefail
OVERLAY="${1:?overlay attendu : kind ou aws}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROM_IMAGE="prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e"

# Reproduit l'arborescence du pod : prometheus.yml + scrape/scrape.yml.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scrape"
cp "$ROOT/monitoring/overlays/$OVERLAY/prometheus.yml" "$TMP/prometheus.yml"
cp "$ROOT/monitoring/base/scrape.yml" "$TMP/scrape/scrape.yml"
# promtool verifie l'existence du fichier de jeton du ServiceAccount (absent hors cluster).
echo "jeton-factice" > "$TMP/token"
# scrape_config_files pointe vers le chemin absolu du pod : on monte au meme endroit.
docker run --rm --entrypoint promtool -v "$TMP":/etc/prometheus:ro \
  -v "$TMP/token":/var/run/secrets/kubernetes.io/serviceaccount/token:ro "$PROM_IMAGE" \
  check config /etc/prometheus/prometheus.yml
