# Cyberlab Infra

Déploiement des backends du cyberlab sur le NAS : `sherlock`, `dns_analyzer`, `audit_orchestrator` et leurs trois tunnels `cloudflared`. Ce dépôt est séparé de [HomeServer-monitoring](https://github.com/NAS-HomeServer/HomeServer-monitoring) (sondes, alertes et dashboard Grafana du cyberlab) : un déploiement de l'un ne redémarre jamais l'autre.

## Contenu

```
├── cyberlab/docker-compose.yml          # Les 6 conteneurs (backends GHCR et cloudflared épinglés par digest)
├── ansible/
│   ├── inventory/hosts.ini              # Inventaire (localhost)
│   └── playbooks/deploy-cyberlab.yml    # Vérification Cosign + déploiement du compose
├── k8s/                                 # Migration AWS (K3s) : manifestes Kustomize, voir ci-dessous
├── docs/notes-projet.md                 # Décisions, alternatives écartées, difficultés
├── ci/Dockerfile.ansible-runner         # Image Ansible utilisée par la CI
├── .github/workflows/cyberlab-infra.yml
├── renovate.json · .yamllint.yml · .trivyignore
```

## Pipeline CI/CD

[`cyberlab-infra.yml`](.github/workflows/cyberlab-infra.yml) se déclenche sur une pull request ou un push sur `main` qui modifie `cyberlab/**`, le playbook ou le workflow, ou manuellement (`workflow_dispatch`). Runner `self-hosted` sur le NAS.

| Job | Contenu |
|---|---|
| ① Code Quality | `yamllint --strict`, `ansible-lint --profile=production` |
| ② Security | Cosign (image Trivy, puis signature des images backends GHCR), Gitleaks, Trivy `config` (HIGH/CRITICAL bloquants) |
| ③ Build & Scan | Build de l'image Ansible (`ansible-runner-cyberlab:<sha>`), Trivy `image` (HIGH/CRITICAL, rapport SARIF en artefact), sauvegarde de l'image scannée |
| ④ Deploy | Gate `environment: production`, rechargement de l'image scannée si elle a disparu du démon, puis playbook `deploy-cyberlab.yml` depuis cette image |

Sur une pull request, ①, ② et ③ tournent (PR de forks ignorées) ; ④ est réservé à `main` et au déclenchement manuel.

- Workspace `/volume2/docker/workspace_cyberlab`, un sous-dossier par job.
- Images d'outillage épinglées par digest ; le token GitHub est passé à `curl` via un fichier de config.
- Le playbook revérifie les signatures Cosign (identité : workflow `ci.yml` sur `main` du dépôt de chaque backend) avant de copier le compose vers `/volume2/docker/cyberlab/` et de lancer `docker_compose_v2` (projet `cyberlab`, `pull: missing`, `remove_orphans: false`).

## Kubernetes (migration AWS, en cours)

Le NAS reste la production tant que la bascule n'est pas décidée. En parallèle, `k8s/` décrit le même service pour un cluster K3s sur AWS (voir [docs/notes-projet.md](docs/notes-projet.md)).

```
k8s/
├── cyberlab/{base,overlays/{kind,staging,production}}   # 3 backends + 3 tunnels cloudflared
├── monitoring/{base,overlays/{kind,aws}}                # Prometheus Agent, node-exporter, kube-state-metrics
└── kind/                                                # faux NAS et scripts de test local
```

Les trois backends ne gardent aucune donnée durable (jobs en mémoire, fichiers temporaires dans `/tmp`) : aucun volume n'est nécessaire.

Tester en local (Docker et [kind](https://kind.sigs.k8s.io/) requis, aucun appel à AWS) :

```bash
k8s/kind/check-agent-config.sh kind   # promtool sur la config de l'agent
k8s/kind/test.sh                      # déploiement complet + séries reçues par un faux NAS
k8s/kind/test-resilience.sh           # coupe puis rétablit la liaison remote_write
k8s/kind/test.sh --cleanup            # supprime le cluster de test
```

## Mise à jour d'un backend

La CI de chaque dépôt backend publie et signe l'image sur GHCR, puis ouvre une PR (`bump/cyberlab_*`) **sur ce dépôt** qui reporte le nouveau digest dans `cyberlab/docker-compose.yml`. Le merge déclenche le déploiement.

## Mise à jour de cloudflared

Les trois tunnels utilisent `cloudflare/cloudflared:<version>@sha256:<digest>`. Renovate suit la version (PR hebdomadaire, le lundi matin) et met à jour tag et digest ensemble ; la review est manuelle (pas d'automerge sur les changements de version).

Renovate ignore volontairement les images backends `ghcr.io/ag69075/**` (référencées par digest seul, sans tag à suivre : Renovate ne peut pas déterminer le nouveau digest) : leurs mises à jour passent uniquement par les PR `bump/cyberlab_*` décrites ci-dessus.

## Healthchecks

Chaque backend déclare un healthcheck (Dockerfile du dépôt backend) appelé toutes les 30 s. Deux règles, apprises sur Sherlock :

- **Rester léger.** Le process du healthcheck est comptabilisé dans le cgroup du conteneur (visible dans cAdvisor / Grafana, invisible dans `ps` ou `docker top`). Un `python -c "import urllib.request ..."` coûtait ~0,57 s de CPU par passage, soit ~2 % de CPU permanent. Préférer le `wget` BusyBox des images Alpine.
- **Cibler `127.0.0.1`, pas `localhost`.** `wget` BusyBox résout `localhost` en `::1` sans repli IPv4, alors que gunicorn n'écoute qu'en IPv4 : le check échoue dès que l'IPv6 est actif (c'est le cas en CI, pas sur le NAS).

## Prérequis

- Secret `MY_GITHUB_TOKEN` (téléchargement du tarball du repo) ; environnement GitHub `production` avec approbation.
- Runner self-hosted disponible pour ce dépôt, avec accès au démon Docker du NAS.
- Les `.env` (`sherlock/`, `dns_analyzer/`, `audit_orchestrator/`) restent **uniquement** sur le NAS, sous `/volume2/docker/cyberlab/`, jamais versionnés.
- Le réseau Docker `cyberlab` (nom fixe) est créé par ce compose ; la stack monitoring le rejoint en `external: true`. Ce pipeline doit donc avoir tourné au moins une fois avant le premier déploiement du monitoring.
