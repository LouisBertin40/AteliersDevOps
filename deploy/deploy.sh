#!/usr/bin/env bash
# Déploiement blue/green avec rollback automatique.
#
# Usage : APP_IMAGE=ghcr.io/louisbertin40/ateliersdevops:<sha> EXPECTED_SHA=<sha> ./deploy/deploy.sh
#
# 1. lit la couleur active dans .active_color et choisit la couleur inactive
# 2. démarre la nouvelle version dans la couleur inactive
# 3. attend qu'elle soit prête (/health, tentatives espacées) puis smoke test (/status :
#    bonne couleur ET bon SHA de commit si EXPECTED_SHA est fourni)
# 4. succès : bascule nginx (reload), enregistre l'état, arrête l'ancienne couleur
#    échec  : supprime la tentative, la couleur active ne change pas
set -euo pipefail

cd "$(dirname "$0")"

STATE_FILE=".active_color"
CONF_FILE="nginx/conf.d/active.conf"
TEMPLATE="nginx/upstream.conf.template"
RETRIES="${RETRIES:-20}"
DELAY="${DELAY:-3}"
export APP_IMAGE="${APP_IMAGE:-ghcr.io/louisbertin40/ateliersdevops:latest}"
EXPECTED_SHA="${EXPECTED_SHA:-}"

log() { echo "[deploy] $*"; }

render_conf() { sed "s/__COLOR__/$1/g" "$TEMPLATE" > "$CONF_FILE"; }

active="$(cat "$STATE_FILE" 2>/dev/null || echo none)"
if [ "$active" = "blue" ]; then target="green"; else target="blue"; fi
log "couleur active : $active -> déploiement dans : $target ($APP_IMAGE)"

rollback() {
  log "ÉCHEC : $1"
  log "rollback : suppression de app-$target, '$active' reste la couleur active"
  docker compose --profile "$target" rm -sf "app-$target" >/dev/null 2>&1 || true
  exit 1
}

# Aucune version active (premier déploiement) : nginx a besoin d'une conf valide
[ -f "$CONF_FILE" ] || render_conf "$target"

docker compose up -d redis nginx
docker compose --profile "$target" up -d --no-deps --force-recreate "app-$target"

# Interroge l'app depuis son propre conteneur (pas de port publié, pas besoin de curl)
probe() {
  docker compose --profile "$target" exec -T "app-$target" python - <<'PY'
import json
import urllib.request

urllib.request.urlopen("http://127.0.0.1:5000/health", timeout=2)
status = json.load(urllib.request.urlopen("http://127.0.0.1:5000/status", timeout=2))
print(status.get("deploy_color", ""), status.get("commit", ""))
PY
}

result=""
for i in $(seq 1 "$RETRIES"); do
  if result="$(probe 2>/dev/null)"; then
    break
  fi
  result=""
  log "tentative $i/$RETRIES : app-$target pas encore prête"
  sleep "$DELAY"
done

[ -n "$result" ] || rollback "healthcheck KO après $RETRIES tentatives"

read -r color commit <<< "$result"
[ "$color" = "$target" ] || rollback "smoke test : deploy_color='$color', attendu '$target'"
if [ -n "$EXPECTED_SHA" ] && [ "$commit" != "$EXPECTED_SHA" ]; then
  rollback "smoke test : commit='$commit', attendu '$EXPECTED_SHA'"
fi
log "smoke test OK (deploy_color=$color, commit=$commit)"

# Bascule : nouvelle conf, validation, reload de nginx AVANT d'arrêter l'ancienne couleur
previous_conf="$(cat "$CONF_FILE")"
render_conf "$target"
if ! docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
  printf '%s\n' "$previous_conf" > "$CONF_FILE"
  rollback "configuration nginx invalide"
fi
docker compose exec -T nginx nginx -s reload
echo "$target" > "$STATE_FILE"
log "trafic basculé sur $target"

if [ "$active" != "none" ]; then
  docker compose --profile "$active" stop "app-$active"
  docker compose --profile "$active" rm -f "app-$active" >/dev/null
  log "ancienne couleur $active arrêtée"
fi

log "déploiement terminé : $target actif"
