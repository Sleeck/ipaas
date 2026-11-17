#!/usr/bin/env bash
# Génère les secrets manquants (une seule fois) ; les existants sont conservés.
# Affiche "added:<NOM>" pour chaque secret créé.
set -euo pipefail
S=${1:-/root/credentials/.pentagi-secrets.env}
umask 077
touch "$S"; chmod 600 "$S"
rnd() { openssl rand -hex "${1:-24}"; }
add() { grep -q "^$1=" "$S" || { echo "$1=$2" >> "$S"; echo "added:$1"; }; }
add COOKIE_SIGNING_SALT "$(rnd 32)"
add PENTAGI_POSTGRES_PASSWORD "$(rnd)"
add LOCAL_SCRAPER_USERNAME scraper
add LOCAL_SCRAPER_PASSWORD "$(rnd)"
add NEO4J_PASSWORD "$(rnd)"
add PENTAGI_ADMIN_PASSWORD "Pg$(rnd 9)X7-"
add LITELLM_MASTER_KEY "sk-$(rnd)"
