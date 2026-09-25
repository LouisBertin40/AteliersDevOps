# AteliersDevOps

[![CI](https://github.com/LouisBertin40/AteliersDevOps/actions/workflows/ci.yml/badge.svg)](https://github.com/LouisBertin40/AteliersDevOps/actions/workflows/ci.yml)

Dépôt du groupe pour les ateliers DevOps (ESIEA, S9) : une petite application Flask
(`app.py`) et ses tests (`test_app.py`).

## Workflow Git

- `main` est protégée : pas de push direct, tout passe par une pull request.
- Les checks CI (`lint`, `test (3.10)`, `test (3.11)`, `test (3.12)`) doivent être verts pour merger.
- Une branche par fonctionnalité (`feat/...`, `fix/...`, `ci/...`), fusionnée via PR.

## Pipeline CI/CD (`.github/workflows/ci.yml`)

```
lint ──▶ test (3.10 / 3.11 / 3.12) ──▶ build-and-push ──▶ deploy (environment: production)
         └─ sur toutes les PR et les push sur main ─┘   └── uniquement sur push sur main ──┘
```

- **lint** : flake8. S'il échoue, `test` ne démarre pas (`needs: lint`).
- **test** : pytest + couverture, en matrice sur Python 3.10, 3.11 et 3.12. Cache pip
  (clé = hash de `requirements*.txt`) et rapport de couverture HTML publié en artefact,
  même en cas d'échec (`if: always()`).
- **build-and-push** : construit le `Dockerfile` multi-stage avec `GIT_SHA=<sha du commit>`
  et le pousse sur `ghcr.io/louisbertin40/ateliersdevops` avec deux tags : `<sha>`
  (immuable, identifie exactement la version) et `latest`.
- **deploy** : environnement GitHub `production` avec **approbation humaine obligatoire**
  (required reviewers), puis exécute `deploy/deploy.sh` avec l'image `<sha>` et
  `EXPECTED_SHA=<sha>`. Le runner étant éphémère, chaque exécution repart d'un
  environnement vierge (pas de `.active_color`, pas de conteneur existant).

`main` est protégée : les checks `lint` et `test (3.x)` doivent être verts pour merger.

## Lancer en local

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest -v
flake8 .
```

## Image Docker : naïve vs multi-stage

Mesuré avec `docker images` après reconstruction des deux images (25/09/2026) :

| Image | Dockerfile | Base | Taille |
|---|---|---|---|
| `ateliers-devops:naif` | `Dockerfile.naif` | `python:3.12` (1 stage) | **1,62 Go** |
| `ateliers-devops:multistage` | `Dockerfile` | `python:3.12-slim` (builder + runtime) | **204 Mo** |

Soit environ **-87 %**. L'essentiel du gain vient de l'image de base (`python:3.12` embarque
compilateurs, headers et outils de build) ; le stage `builder` permet de ne copier que le
venv dans l'image finale, sans cache pip.

## Docker

### Construire l'image

```bash
docker build -t ateliers-devops:multistage .
# version naïve (pour comparaison uniquement)
docker build -f Dockerfile.naif -t ateliers-devops:naif .
```

L'image finale tourne sous l'utilisateur `appuser` (non-root, vérifiable avec
`docker compose exec web whoami`), sert l'application avec **gunicorn** et expose un
`HEALTHCHECK` sur `/health` (fait en Python, pas besoin de `curl` dans l'image slim).

### Lancer la stack complète

```bash
cp .env.example .env   # optionnel, les valeurs par défaut conviennent
docker compose up -d --build
docker compose ps       # web et redis passent à "healthy" après quelques secondes
curl http://localhost:5000/visits
```

- `web` : l'application Flask (port 5000).
- `redis` : `redis:7-alpine`, données persistées dans le volume nommé `redis-data`.
- Les deux services partagent le réseau `backend` ; `web` joint Redis par son nom de
  service (`REDIS_HOST=redis`), jamais par `localhost` ni par IP.
- `web` attend que `redis` soit `healthy` (`depends_on.condition: service_healthy`).
- Le compteur `/visits` survit à `docker compose restart web` et à `docker compose down`
  (sans `-v`).

### Image publiée

Registry : **GitHub Container Registry** —
[`ghcr.io/louisbertin40/ateliersdevops`](https://github.com/LouisBertin40/AteliersDevOps/pkgs/container/ateliersdevops)

```bash
docker pull ghcr.io/louisbertin40/ateliersdevops:1.0.0   # version figée
docker pull ghcr.io/louisbertin40/ateliersdevops:latest
```

## Déploiement blue/green (`deploy/`)

- `deploy/docker-compose.yml` : `redis` et `nginx` (port 8080) démarrent toujours ;
  `app-blue` et `app-green` sont derrière les profils Compose `blue` / `green` et
  exposent leur couleur (`DEPLOY_COLOR`) dans `/status`.
- `deploy/nginx/upstream.conf.template` : conf nginx réécrite à chaque bascule vers
  `app-<couleur>`.
- `deploy/deploy.sh` :
  1. lit la couleur active dans `deploy/.active_color` et cible l'autre ;
  2. démarre la nouvelle version dans la couleur inactive ;
  3. attend `/health` (qui vérifie Redis, 503 sinon) avec 20 tentatives espacées ;
  4. smoke test sur `/status` : bonne `deploy_color` **et** `commit == EXPECTED_SHA` ;
  5. succès : réécrit la conf, `nginx -t` puis `nginx -s reload`, enregistre l'état,
     **puis** arrête l'ancienne couleur ;
     échec : supprime la tentative, la couleur active et le trafic ne changent pas.

```bash
APP_IMAGE=ghcr.io/louisbertin40/ateliersdevops:<sha> EXPECTED_SHA=<sha> ./deploy/deploy.sh
curl http://localhost:8080/status
# {"commit":"<sha>","deploy_color":"green","service":"...","version":"1.0"}
```

Vérifications effectuées :

| Scénario | Résultat |
|---|---|
| Déploiement normal | bascule blue → green, puis green → blue |
| Redis injoignable (`REDIS_HOST=introuvable`) | `/health` en 503, rollback, couleur active inchangée |
| SHA volontairement faux (`EXPECTED_SHA=deadbeef`) | smoke test rejeté, trafic inchangé |
| Push réel sur `main` (version 1.0 → 1.1, PR #8) | pipeline complet, `/status` renvoie `1.1` |

### Rollback manuel

Problème découvert après un déploiement réussi : on annule le commit fautif avec
`git revert` (jamais en modifiant l'environnement ou `.active_color` à la main), on relit
le diff, puis on le fait passer par une PR et le pipeline normal.

```bash
git log --oneline
git revert -m 1 <sha du merge fautif>   # -m 1 pour un commit de merge
git diff HEAD~1                         # relire avant de pousser
```

Exemple : PR #9 a annulé la 1.1 (PR #8) ; après le déploiement, `/status` renvoie à
nouveau `1.0`.
