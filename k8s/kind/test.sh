#!/usr/bin/env bash
# Test local complet sur kind, sans aucun appel a AWS :
#   1. deploie le faux NAS, l'agent Prometheus (overlay kind) et les backends (overlay kind) ;
#   2. verifie que les backends repondent sur /health et que les tunnels exposent /metrics ;
#   3. verifie que les series de l'agent arrivent sur le faux NAS avec les bons labels.
# Usage : k8s/kind/test.sh            (cree le cluster "cyberlab-test" s'il n'existe pas)
#         k8s/kind/test.sh --cleanup  (supprime le cluster)
set -euo pipefail
CLUSTER=cyberlab-test
CTX="kind-$CLUSTER"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="kubectl --context $CTX"

if [ "${1:-}" = "--cleanup" ]; then kind delete cluster --name "$CLUSTER"; exit 0; fi

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --config "$ROOT/kind/kind-config.yaml"

echo "== Deploiement"
$K apply -f "$ROOT/kind/fake-nas/fake-nas.yaml"
$K apply -k "$ROOT/monitoring/overlays/kind"
$K apply -k "$ROOT/cyberlab/overlays/kind"

echo "== Attente des deployments"
$K -n nas-sim rollout status deploy/fake-nas --timeout=180s
$K -n monitoring rollout status deploy/prometheus-agent deploy/kube-state-metrics --timeout=180s
$K -n monitoring rollout status ds/node-exporter --timeout=180s
$K -n cyberlab-kind wait --for=condition=Available deploy/sherlock deploy/dns-analyzer deploy/audit-orchestrator --timeout=300s

echo "== /health des backends (via le proxy de l'API server)"
for b in sherlock:7100 dns-analyzer:4002 audit-orchestrator:4003; do
  svc="${b%%:*}"
  $K get --raw "/api/v1/namespaces/cyberlab-kind/services/$svc:http/proxy/health" >/dev/null
  echo "OK $svc"
done

echo "== /metrics des tunnels cloudflared"
for p in $($K -n cyberlab-kind get pods -l app.kubernetes.io/name=cloudflared -o name); do
  $K get --raw "/api/v1/namespaces/cyberlab-kind/pods/${p#pod/}:2000/proxy/metrics" | grep -q cloudflared_tunnel
  echo "OK $p"
done

echo "== Series recues par le faux NAS (attente max 3 min)"
q() { $K get --raw "/api/v1/namespaces/nas-sim/services/fake-nas:http/proxy/api/v1/query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"; }
for i in $(seq 1 18); do
  out=$(q 'count by (job) (up{cluster="kind"})' || true)
  n=$(printf '%s' "$out" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]["result"]))' 2>/dev/null || echo 0)
  [ "$n" -ge 6 ] && break
  sleep 10
done
printf '%s\n' "$out" | python3 -m json.tool | grep -E '"job"|"value"' || true
[ "$n" -ge 6 ] || { echo "ECHEC : moins de 6 jobs recus"; exit 1; }
echo "-- Labels env/cluster sur l'etat des deployments (kube-state-metrics)"
for i in $(seq 1 12); do
  out=$(q 'kube_deployment_status_replicas_available{env="kind",cluster="kind",deployment="sherlock"}' || true)
  printf '%s' "$out" | grep -q '"deployment":"sherlock"' && break
  sleep 10
done
printf '%s' "$out" | grep -q '"deployment":"sherlock"' || { echo "ECHEC : serie kube_deployment_* sans les labels env/cluster attendus"; exit 1; }
echo "TEST OK"
