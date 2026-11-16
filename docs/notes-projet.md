# Notes de projet — migration du cyberlab vers AWS

Journal des décisions, des alternatives écartées et des difficultés rencontrées.
Il sert de matière première pour le dossier de projet et la situation de
recherche du titre RNCP. Une section par étape ; on ajoute, on ne réécrit pas.

## Contexte et périmètre

- Point de départ : 3 backends (`sherlock`, `dns-analyzer`, `audit-orchestrator`),
  chacun derrière un tunnel `cloudflared`, sur un NAS Synology (Docker Compose,
  Ansible, runner GitHub auto-hébergé). Images publiques sur GHCR, épinglées par
  digest, signées Cosign.
- Objectif de l'étape A : le même service sur AWS (Terraform → EC2 K3s → Ansible
  → ArgoCD → manifestes Kubernetes), deux environnements, supervision par le
  Prometheus du NAS via un Prometheus Agent. Le NAS reste la production tant que
  la bascule n'est pas décidée.

## Étape 1 — Manifestes Kubernetes (Kustomize), testés sur kind

### Constats sur les backends (état des lieux avant de migrer)

| | sherlock | dns-analyzer | audit-orchestrator |
|---|---|---|---|
| Données durables | aucune | aucune (fichier temporaire dans `/tmp`, supprimé après lecture) | aucune (jobs en mémoire, purgés après 1 h) |
| Tests unitaires en CI | non | non | non |
| Contrôles avant publication | ruff, build, smoke test sous durcissement prod, Trivy | eslint, smoke test, Trivy | eslint, smoke test, Trivy |
| `/metrics` Prometheus | non | non | non |
| `/health` | oui | oui | oui |

Conséquences :
- **Pas de volume EBS ni de bucket S3 pour les données** : les backends sont sans
  état durable. À noter dans le README (compétence « gérer le stockage de données » :
  la réponse est une décision argumentée, pas un volume inutile). Le seul stockage
  durable du projet est l'état Terraform (bucket S3 créé à part).
- **Un seul réplica par backend** : les jobs vivent dans la mémoire du process, le
  suivi d'un job doit retomber sur le même pod.
- **Tests avant mise en production** : aucun test unitaire dans les backends. Ce qui
  existe : lint + smoke test en CI. On le complète côté infra par la validation des
  manifestes (kubeconform, trivy, promtool), un test de bout en bout sur kind, et
  staging comme étape obligatoire avant la production.
- **Pas de `/metrics` côté backends** : on n'a pas modifié les backends pour l'étape A.
  Leur santé vient de kube-state-metrics (réplicas disponibles, redémarrages) et
  cAdvisor (CPU, mémoire). Les tunnels, eux, exposent `/metrics` grâce à `--metrics`.
  *Alternative écartée* : ajouter `prom-client` aux backends (touche 3 dépôts, hors périmètre).

### Décisions

- **Un seul EC2, un seul cluster K3s, deux namespaces** (`cyberlab-staging`,
  `cyberlab-production`) plutôt que deux instances : coût minimal, et ce qu'on
  démontre (Terraform, K8s, GitOps, promotion) ne dépend pas du nombre de machines.
  Limite assumée : staging et production partagent le même point de défaillance.
  *Alternative écartée* : un cluster par environnement (plus propre, deux fois plus cher).
- **Conséquence sur l'agent Prometheus** : un seul agent (namespace `monitoring`).
  Deux agents sur le même nœud dupliqueraient les métriques de l'hôte. Le label
  `env` n'est donc pas un `external_label` : il est déduit du namespace par
  relabeling (`cyberlab-staging` → `env=staging`), et vaut `shared` pour l'hôte et le
  cluster. `cluster=aws-k3s` reste un `external_label` (porté par l'overlay).
- **Structure** : `k8s/cyberlab/{base,overlays}` et `k8s/monitoring/{base,overlays}`.
  Deux ensembles indépendants car le monitoring est unique par cluster alors que
  `cyberlab` existe une fois par environnement. Les overlays `kind` servent au test
  local (secrets factices, faux NAS) ; `staging` et `production` à AWS.
- **Config de l'agent en deux fichiers** : `scrape.yml` (quoi collecter, dans la base,
  commun) et `prometheus.yml` (où envoyer, quels labels : un par overlay), reliés par
  `scrape_config_files`. Ainsi l'overlay ne répète pas les scrapes.
- **Digests** : toutes les images sont épinglées par digest (backends via
  `images:`/`digest:` dans les overlays pour pouvoir promouvoir staging → production ;
  cloudflared, Prometheus, node-exporter, kube-state-metrics directement dans les
  manifestes, suivis par Renovate via le gestionnaire `kubernetes`).
- **Reprise du durcissement du compose** : `read_only` → `readOnlyRootFilesystem`,
  `cap_drop ALL` → `capabilities.drop: [ALL]`, `no-new-privileges` →
  `allowPrivilegeEscalation: false`, `tmpfs /tmp` → `emptyDir` en mémoire (64 Mi),
  `mem_limit` → `resources.limits.memory`, healthchecks → probes (startup, readiness,
  liveness). Ajouts : `runAsNonRoot`, profil seccomp `RuntimeDefault`, jeton de
  ServiceAccount non monté, NetworkPolicies (ingress refusé par défaut), namespaces en
  Pod Security `restricted`.
- **Secrets séparés** : dans le compose, chaque tunnel reçoit tout le `.env` de son
  backend (clé Gemini, jetons internes). Ici le tunnel ne reçoit que son
  `TUNNEL_TOKEN` (Secret dédié) : moindre privilège.
- **Tunnels : un jeu par environnement, nouveaux tokens.** Réutiliser les tokens du NAS
  ferait répartir le trafic réel entre le NAS et AWS. Le NAS reste donc la production
  jusqu'à bascule explicite.
- **node-exporter** : seul composant qui exige `hostNetwork` + `hostPath` (lecture de
  `/proc`, `/sys`, `/`). Le namespace `monitoring` est donc en Pod Security `privileged`,
  et trois règles Trivy sont ignorées avec justification (`.trivyignore`).
  *Alternative écartée* : ne pas superviser l'hôte (perd CPU/mémoire/disque de l'EC2).
- **Pas de Helm ni d'Operator** : manifestes simples, lisibles en soutenance.
- **WAL de l'agent** : `emptyDir` plafonné (512 Mi), rétention max 4 h. Il survit à un
  redémarrage du conteneur, pas à l'arrêt de l'instance (rien à rattraper dans ce cas).
  Un `stop` du soir coupe aussi les métriques : c'est voulu.

### Difficultés rencontrées

- **Images backends en amd64 seulement, poste en arm64** : elles tournent quand même
  sous kind via l'émulation de Docker Desktop (pas de rebuild nécessaire). Sur AWS on
  prend des instances x86 (`t3`), pas `t4g`.
- **Liste YAML en ligne qui découpe sur la virgule** : `args: [--resources=a,b, --port=8080]`
  était lu comme trois arguments, d'où un `unknown command "pods"` et un CrashLoopBackOff
  de kube-state-metrics. Résolution : liste en bloc.
- **`name` non réécrit par Kustomize** : les ConfigMaps générées (avec suffixe de hash)
  n'étaient pas référencées par le Deployment tant que le `namespace` n'était pas fixé
  dans le `kustomization.yaml` (générateur et Deployment dans des namespaces différents
  pour Kustomize). Résolution : `namespace: monitoring` dans la base et les overlays.
- **Tunnels avec un faux token** : ils se connectent au réseau Cloudflare, échouent à
  l'enregistrement, et la liveness probe (sur `/ready`) les redémarrait en boucle. Sur
  kind uniquement, la liveness est retirée par un patch. Effet utile : les tunnels
  exposent bien `/metrics` et kube-state-metrics les voit à 0 réplica disponible.
- **Échantillons « out-of-order » de cAdvisor** : cAdvisor horodate ses échantillons.
  Résolution : `honor_timestamps: false` sur ce job.
- **`up` n'est pas touché par `metric_relabel_configs`** : pour que `up` porte `env`,
  le label est posé dans `relabel_configs` (cibles) pour les jobs par pod.
- **Piège de test** : `query_range` masque les trous (fenêtre de staleness de 5 min).
  Le test de résilience lit les échantillons bruts (`up[...]`).

### Validation (tout en local, aucun appel AWS)

- `kubeconform -strict` : 5 overlays valides. `trivy config` : 0 finding HIGH/CRITICAL
  (hors les 2 règles node-exporter ignorées avec justification).
- `promtool check config` sur la config de l'agent (overlays kind et aws).
- `k8s/kind/test.sh` : backends joignables sur `/health`, tunnels exposant `/metrics`,
  séries de l'agent reçues par un faux NAS avec `cluster` et `env` corrects.
- Scan Sherlock réel (nom d'utilisateur fictif) sous `readOnlyRootFilesystem` : fonctionne,
  le doute sur une écriture de `<user>.txt` est levé.
- `k8s/kind/test-resilience.sh` : liaison coupée 90 s puis rétablie, aucun trou
  (écart max entre échantillons bruts = intervalle de scrape).

### Questions repoussées aux étapes suivantes

- Transport vers le NAS (Tailscale recommandé) : étape 7, l'URL `remote_write` de
  l'overlay `aws` est un **placeholder** (`100.64.0.1`).
- Mise à jour des digests : les PR `bump/*` des backends ne touchent que le compose.
  À traiter (sed supplémentaire côté backends, ou workflow de synchronisation ici).
- Secrets réels (SOPS + age + KSOPS) : étape 4 ; les overlays staging/production n'ont
  pas encore leurs Secrets.
