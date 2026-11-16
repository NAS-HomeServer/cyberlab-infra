#!/usr/bin/env bash
# Test de resilience du remote_write : on coupe la liaison avec le faux NAS
# (le Service n'a plus de pod derriere), on la retablit, puis on verifie que
# l'agent a rattrape son retard depuis le WAL (aucun trou dans les series).
# Prerequis : le cluster cree par k8s/kind/test.sh. Usage : test-resilience.sh [secondes de coupure]
set -euo pipefail
CTX="kind-cyberlab-test"; K="kubectl --context $CTX"
CUT="${1:-120}"
q() { $K get --raw "/api/v1/namespaces/nas-sim/services/fake-nas:http/proxy/api/v1/$1"; }

START=$(date +%s)
echo "== Coupure de la liaison pendant ${CUT}s"
$K -n nas-sim patch svc fake-nas -p '{"spec":{"selector":{"app":"coupe"}}}'
sleep "$CUT"
echo "== Retablissement"
$K -n nas-sim patch svc fake-nas -p '{"spec":{"selector":{"app":"fake-nas"}}}'
sleep 90
END=$(date +%s)

# Echantillons BRUTS (selecteur de plage) : query_range masquerait les trous
# a cause de la fenetre de "staleness" de 5 minutes.
WINDOW=$((END - START + 15))
echo "== Plus grand ecart entre deux echantillons bruts de up{job=\"aws-node\"} depuis la coupure"
q "query?time=$END&query=up%7Bjob%3D%22aws-node%22%7D%5B${WINDOW}s%5D" | python3 -c '
import sys, json
r = json.load(sys.stdin)["data"]["result"][0]["values"]
ts = [float(t) for t, _ in r]
gaps = [b - a for a, b in zip(ts, ts[1:])]
print(f"{len(ts)} echantillons, ecart max = {max(gaps):.0f}s (intervalle de scrape = 15s)")
sys.exit(0 if max(gaps) <= 30 else 1)'
echo "RESILIENCE OK : l'agent a rattrape les donnees de la coupure"
