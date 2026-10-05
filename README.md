# Cyberlab Infra

Déploiement des backends du cyberlab sur le NAS : `sherlock`, `dns_analyzer`, `audit_orchestrator` et leurs trois tunnels `cloudflared`. Ce dépôt est séparé de [HomeServer-monitoring](https://github.com/NAS-HomeServer/HomeServer-monitoring) (sondes, alertes et dashboard Grafana du cyberlab) : un déploiement de l'un ne redémarre jamais l'autre.

## Contenu

```
├── cyberlab/docker-compose.yml          # Les 6 conteneurs (images GHCR épinglées par digest)
├── ansible/
│   ├── inventory/hosts.ini              # Inventaire (localhost)
│   └── playbooks/deploy-cyberlab.yml    # Vérification Cosign + déploiement du compose
├── ci/Dockerfile.ansible-runner         # Image Ansible utilisée par la CI
├── .github/workflows/cyberlab-infra.yml
├── renovate.json · .yamllint.yml · .trivyignore
```

## Pipeline CI/CD

[`cyberlab-infra.yml`](.github/workflows/cyberlab-infra.yml) se déclenche sur un push sur `main` qui modifie `cyberlab/**`, le playbook ou le workflow, ou manuellement (`workflow_dispatch`). Runner `self-hosted` sur le NAS.

| Job | Contenu |
|---|---|
| ① Lint | `yamllint --strict`, `ansible-lint --profile=production` |
| ② Sécurité | Cosign (image Trivy, puis signature des images backends GHCR), Gitleaks, Trivy `config` (HIGH/CRITICAL bloquants) |
| ③ Build | Build de l'image Ansible (`ansible-runner-cyberlab:<sha>`) |
| ④ Deploy | Playbook `deploy-cyberlab.yml` depuis cette image, gate `environment: production` |

- Workspace `/volume2/docker/workspace_cyberlab`, un sous-dossier par job.
- Images d'outillage épinglées par digest ; le token GitHub est passé à `curl` via un fichier de config.
- Le playbook revérifie les signatures Cosign (identité : workflow `ci.yml` sur `main` du dépôt de chaque backend) avant de copier le compose vers `/volume2/docker/cyberlab/` et de lancer `docker_compose_v2` (projet `cyberlab`, `pull: missing`, `remove_orphans: false`).

## Mise à jour d'un backend

La CI de chaque dépôt backend publie et signe l'image sur GHCR, puis ouvre une PR (`bump/cyberlab_*`) **sur ce dépôt** qui reporte le nouveau digest dans `cyberlab/docker-compose.yml`. Le merge déclenche le déploiement.

## Healthchecks

Chaque backend déclare un healthcheck (Dockerfile du dépôt backend) appelé toutes les 30 s. Deux règles, apprises sur Sherlock :

- **Rester léger.** Le process du healthcheck est comptabilisé dans le cgroup du conteneur (visible dans cAdvisor / Grafana, invisible dans `ps` ou `docker top`). Un `python -c "import urllib.request ..."` coûtait ~0,57 s de CPU par passage, soit ~2 % de CPU permanent. Préférer le `wget` BusyBox des images Alpine.
- **Cibler `127.0.0.1`, pas `localhost`.** `wget` BusyBox résout `localhost` en `::1` sans repli IPv4, alors que gunicorn n'écoute qu'en IPv4 : le check échoue dès que l'IPv6 est actif (c'est le cas en CI, pas sur le NAS).

Le service `sherlock` surcharge le healthcheck dans le compose avec cet appel `wget`. Cet override est redondant depuis que l'image embarque le même check (digest `c5ea346` et suivants) ; il peut être retiré.

## Prérequis

- Secret `MY_GITHUB_TOKEN` (téléchargement du tarball du repo) ; environnement GitHub `production` avec approbation.
- Runner self-hosted disponible pour ce dépôt, avec accès au démon Docker du NAS.
- Les `.env` (`sherlock/`, `dns_analyzer/`, `audit_orchestrator/`) restent **uniquement** sur le NAS, sous `/volume2/docker/cyberlab/`, jamais versionnés.
- Le réseau Docker `cyberlab` (nom fixe) est créé par ce compose ; la stack monitoring le rejoint en `external: true`. Ce pipeline doit donc avoir tourné au moins une fois avant le premier déploiement du monitoring.

## Dette technique

Image `cloudflared` épinglée par digest mais version non suivie automatiquement.
