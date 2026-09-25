# AteliersDevOps

[![CI](https://github.com/LouisBertin40/AteliersDevOps/actions/workflows/ci.yml/badge.svg)](https://github.com/LouisBertin40/AteliersDevOps/actions/workflows/ci.yml)

Dépôt du groupe pour les ateliers DevOps (ESIEA, S9) : une petite application Flask
(`app.py`) et ses tests (`test_app.py`).

## Workflow Git

- `main` est protégée : pas de push direct, tout passe par une pull request.
- Les checks CI (`lint`, `test (3.10)`, `test (3.11)`, `test (3.12)`) doivent être verts pour merger.
- Une branche par fonctionnalité (`feat/...`, `fix/...`, `ci/...`), fusionnée via PR.

## Pipeline CI (`.github/workflows/ci.yml`)

Déclenché sur chaque pull request et sur chaque push sur `main`. Le job `lint` (flake8)
s'exécute d'abord ; s'il passe, le job `test` (pytest + couverture) tourne en matrice sur
Python 3.10, 3.11 et 3.12. Les dépendances pip sont mises en cache (clé = hash de
`requirements.txt`) et le rapport de couverture HTML est publié en artefact, même en cas
d'échec des tests.

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
