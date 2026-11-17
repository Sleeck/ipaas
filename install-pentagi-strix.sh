#!/usr/bin/env bash
# =============================================================================
#  Installation 100% automatique : PentAGI + Strix + Hermes Agent + LiteLLM (Claude)
#  Ubuntu 24.04 uniquement (Python 3.12), à lancer en root, 4 Go de RAM minimum.
#
#  Usage :   bash install-pentagi-strix.sh
#
#  Architecture :
#     Hermes Agent ──┬─ pentagi-cli ──> PentAGI ──┐
#                    ├─ strix-scan ───> Strix ────┤
#                    │                            ▼
#                    └──────────────────> LiteLLM (127.0.0.1:4000) ──> API Anthropic (Claude)
#
#  Seule clé à fournir : ANTHROPIC_API_KEY (clé API de console.anthropic.com),
#  soit exportée avant de lancer le script, soit écrite dans
#  /root/credentials/llm.env, puis relancer le script.
#
#  Tous les identifiants générés sont dans /root/credentials/
#  Le script est idempotent : on peut le relancer sans rien casser
#  (les mots de passe déjà générés sont conservés).
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

CRED_DIR=/root/credentials
PENTAGI_DIR=/opt/pentagi
LITELLM_DIR=/opt/litellm
LITELLM_IMAGE=ghcr.io/berriai/litellm:main-stable
LOG=/var/log/install-pentagi-strix.log
RAW=https://raw.githubusercontent.com/vxcontrol/pentagi/master

# --- Vérifications préalables (avant toute modification du système) ----------
fail() { echo -e "\033[1;31mERREUR : $*\033[0m" >&2; exit 1; }
warn() { echo -e "\033[1;33mATTENTION : $*\033[0m" >&2; }
[ "$(id -u)" -eq 0 ] || fail "lancer ce script en root."
if [ "${SKIP_OS_CHECK:-0}" != 1 ]; then
  OS_ID=$(. /etc/os-release 2>/dev/null && echo "${ID:-}")
  OS_VER=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")
  OS_NAME=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-inconnu}")
  [ "$OS_ID" = ubuntu ] && [ "$OS_VER" = 24.04 ] || fail "Ubuntu 24.04 requis (système détecté : ${OS_NAME:-inconnu}).
  Strix exige Python >= 3.12 et Hermes Agent Python < 3.14 : seul Ubuntu 24.04 (Python 3.12) convient.
  Pour forcer quand même : SKIP_OS_CHECK=1 bash $0"
  PYV=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo absent)
  case "$PYV" in 3.12|3.13) ;; *) fail "Python 3.12 ou 3.13 requis (trouvé : $PYV)." ;; esac
fi
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$MEM_MB" -ge 3500 ] || warn "seulement ${MEM_MB} Mo de RAM : 4 Go minimum recommandés."
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "$DISK_GB" -ge 20 ] || warn "seulement ${DISK_GB} Go libres sur / : 20 Go minimum recommandés."

exec > >(tee -a "$LOG") 2>&1
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }
rnd() { openssl rand -hex "${1:-24}"; }

mkdir -p "$CRED_DIR" && chmod 700 "$CRED_DIR"
umask 077

# --- Clés fournies par l'utilisateur -----------------------------------------
LLM_ENV="$CRED_DIR/llm.env"
LLM_KEYS="ANTHROPIC_API_KEY CLAUDE_MODEL EMBEDDING_PROVIDER EMBEDDING_MODEL EMBEDDING_URL EMBEDDING_KEY STRIX_LLM"
if ! grep -q '^# llm.env v2' "$LLM_ENV" 2>/dev/null; then
  OLD_ANTHROPIC=$(grep -s '^ANTHROPIC_API_KEY=' "$LLM_ENV" | cut -d= -f2- || true)
  [ -f "$LLM_ENV" ] && mv "$LLM_ENV" "$LLM_ENV.bak"
  cat > "$LLM_ENV" <<EOF
# llm.env v2 - remplir puis relancer : bash install-pentagi-strix.sh
#
# Clé API Anthropic (https://console.anthropic.com > API Keys).
# Elle est donnée UNIQUEMENT à LiteLLM ; PentAGI et Strix passent par LiteLLM.
ANTHROPIC_API_KEY=$OLD_ANTHROPIC

# Modèle Claude utilisé par tous les agents (claude-opus-5-5, claude-sonnet-5-5, claude-haiku-5-5)
CLAUDE_MODEL=claude-opus-5-5

# Optionnel : embeddings pour la mémoire vectorielle de PentAGI.
# Anthropic ne fournit pas d'embeddings ; ex. Voyage AI :
#   EMBEDDING_PROVIDER=voyageai  EMBEDDING_MODEL=voyage-3.5  EMBEDDING_KEY=pa-...
EMBEDDING_PROVIDER=
EMBEDDING_MODEL=
EMBEDDING_URL=
EMBEDDING_KEY=

# Optionnel : modèle Strix (vide = openai/<CLAUDE_MODEL> via LiteLLM)
STRIX_LLM=
EOF
fi
# Les variables exportées dans l'environnement priment sur le fichier
for k in $LLM_KEYS; do
  if [ -n "${!k:-}" ]; then
    sed -i "/^$k=/d" "$LLM_ENV"; echo "$k=${!k}" >> "$LLM_ENV"
  fi
done
set -a; . "$LLM_ENV"; set +a
CLAUDE_MODEL=${CLAUDE_MODEL:-claude-opus-5-5}

# --- Paquets système + Docker ------------------------------------------------
log "Installation des paquets système et de Docker"
apt-get update -y
apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  ca-certificates curl wget unzip openssl jq git pipx python3-venv \
  docker.io docker-compose-v2
systemctl enable --now docker

# --- IP principale -------------------------------------------------------------
detect_ip() { ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}'; }
SERVER_IP=$(detect_ip)
log "IP principale détectée : $SERVER_IP"

# --- Secrets (générés une seule fois, complétés si besoin) --------------------
SECRETS="$CRED_DIR/.pentagi-secrets.env"
touch "$SECRETS"
add_secret() { grep -q "^$1=" "$SECRETS" || echo "$1=$2" >> "$SECRETS"; }
add_secret COOKIE_SIGNING_SALT "$(rnd 32)"
add_secret PENTAGI_POSTGRES_PASSWORD "$(rnd)"
add_secret LOCAL_SCRAPER_USERNAME scraper
add_secret LOCAL_SCRAPER_PASSWORD "$(rnd)"
add_secret NEO4J_PASSWORD "$(rnd)"
add_secret PENTAGI_ADMIN_PASSWORD "Pg$(rnd 9)X7-"
add_secret LITELLM_MASTER_KEY "sk-$(rnd)"
. "$SECRETS"

# --- Configuration des agents PentAGI (tous sur Claude via LiteLLM) ----------
case "$CLAUDE_MODEL" in
  claude-opus-5-5)   P_IN=4.00; P_OUT=20.00; P_CR=0.20 ;;
  claude-sonnet-5-5) P_IN=2.00; P_OUT=10.00; P_CR=0.10 ;;
  claude-haiku-5-5)  P_IN=0.10; P_OUT=0.50;  P_CR=0.01 ;;
  *)                 P_IN=0;    P_OUT=0;     P_CR=0 ;;
esac
mkdir -p "$PENTAGI_DIR"
{
  echo "# Généré par install-pentagi-strix.sh - tous les agents sur $CLAUDE_MODEL via LiteLLM."
  echo "# Pas de temperature/top_p/reasoning : les modèles Claude 5.5 les refusent."
  for a in simple:4096 simple_json:4096 primary_agent:16000 assistant:16000 generator:16000 \
           refiner:16000 adviser:8192 reflector:8192 searcher:8192 enricher:8192 \
           coder:16000 installer:8192 pentester:16000; do
    cat <<EOF

${a%%:*}:
  model: "$CLAUDE_MODEL"
  n: 1
  max_tokens: ${a##*:}
  price:
    input: $P_IN
    output: $P_OUT
    cache_read: $P_CR
EOF
  done
} > "$PENTAGI_DIR/claude-litellm.provider.yml"
chmod 644 "$PENTAGI_DIR/claude-litellm.provider.yml"

# --- PentAGI -------------------------------------------------------------------
log "Préparation de PentAGI dans $PENTAGI_DIR"
cd "$PENTAGI_DIR"
curl -fsSL -o docker-compose.yml "$RAW/docker-compose.yml"
[ -f .env ] || curl -fsSL -o .env "$RAW/.env.example"
for f in "custom.provider.yml:custom-openai.provider.yml" \
         "ollama.provider.yml:ollama-llama318b.provider.yml" \
         "bedrock.provider.yml:bedrock.provider.yml"; do
  dst="example.${f%%:*}"; src="${f##*:}"
  [ -f "$dst" ] || curl -fsSL -o "$dst" "$RAW/examples/configs/$src" || touch "$dst"
done

set_env() { sed -i "/^$1=/d" .env; printf '%s=%s\n' "$1" "$2" >> .env; }

set_env PENTAGI_LISTEN_IP 0.0.0.0
set_env PENTAGI_LISTEN_PORT 8443
set_env PUBLIC_URL "https://$SERVER_IP:8443"
set_env CORS_ORIGINS "https://localhost:8443,https://$SERVER_IP:8443"
set_env COOKIE_SIGNING_SALT "$COOKIE_SIGNING_SALT"
set_env PENTAGI_POSTGRES_USER postgres
set_env PENTAGI_POSTGRES_PASSWORD "$PENTAGI_POSTGRES_PASSWORD"
set_env LOCAL_SCRAPER_USERNAME "$LOCAL_SCRAPER_USERNAME"
set_env LOCAL_SCRAPER_PASSWORD "$LOCAL_SCRAPER_PASSWORD"
set_env SCRAPER_PRIVATE_URL "https://$LOCAL_SCRAPER_USERNAME:$LOCAL_SCRAPER_PASSWORD@scraper/"
set_env NEO4J_PASSWORD "$NEO4J_PASSWORD"
set_env DOCKER_PUBLIC_IP "$SERVER_IP"
set_env ASK_USER false
set_env DUCKDUCKGO_ENABLED true
set_env SPLOITUS_ENABLED true
# LLM : uniquement LiteLLM (fournisseur "custom" de PentAGI)
set_env LLM_SERVER_URL "http://litellm:4000/v1"
set_env LLM_SERVER_KEY "$LITELLM_MASTER_KEY"
set_env LLM_SERVER_MODEL "$CLAUDE_MODEL"
set_env LLM_SERVER_PROVIDER ""
set_env LLM_SERVER_CONFIG_PATH /opt/pentagi/conf/custom.provider.yml
set_env PENTAGI_LLM_SERVER_CONFIG_PATH "$PENTAGI_DIR/claude-litellm.provider.yml"
for k in OPEN_AI_KEY ANTHROPIC_API_KEY GEMINI_API_KEY DEEPSEEK_API_KEY MISTRAL_API_KEY XAI_API_KEY OLLAMA_SERVER_URL; do
  set_env "$k" ""          # pas d'accès direct : tout passe par LiteLLM
done
for k in EMBEDDING_PROVIDER EMBEDDING_MODEL EMBEDDING_URL EMBEDDING_KEY; do
  set_env "$k" "${!k:-}"
done
chmod 600 .env

log "Téléchargement des images et démarrage de PentAGI"
docker compose pull -q
docker compose up -d --remove-orphans

# --- LiteLLM -------------------------------------------------------------------
log "Installation de LiteLLM dans $LITELLM_DIR"
mkdir -p "$LITELLM_DIR"
cat > "$LITELLM_DIR/.env" <<EOF
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY
EOF
chmod 600 "$LITELLM_DIR/.env"
{
  echo "# Généré par install-pentagi-strix.sh"
  echo "model_list:"
  for m in claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5; do
    cat <<EOF
  - model_name: $m
    litellm_params:
      model: anthropic/$m
      api_key: os.environ/ANTHROPIC_API_KEY
      # Les modèles Claude 5.5 renvoient une erreur 400 sur ces paramètres.
      # response_format : LiteLLM le traduit en "output_format", obsolète côté
      # Anthropic ; PentAGI exige déjà du JSON pur dans son prompt système.
      additional_drop_params: ["temperature", "top_p", "top_k", "reasoning_effort", "response_format"]
EOF
  done
  cat <<'EOF'

litellm_settings:
  drop_params: true

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
} > "$LITELLM_DIR/config.yaml"
chmod 644 "$LITELLM_DIR/config.yaml"
cat > "$LITELLM_DIR/docker-compose.yml" <<EOF
services:
  litellm:
    image: $LITELLM_IMAGE
    container_name: litellm
    hostname: litellm
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    ports:
      - 127.0.0.1:4000:4000
    networks:
      - pentagi-network
networks:
  pentagi-network:
    external: true
EOF
cd "$LITELLM_DIR"
docker compose pull -q
docker compose up -d --force-recreate
log "Attente de LiteLLM"
for i in $(seq 1 60); do
  curl -sf http://127.0.0.1:4000/health/liveliness >/dev/null && break
  sleep 3
done
curl -sf http://127.0.0.1:4000/health/liveliness >/dev/null && LITELLM_STATE=ok || LITELLM_STATE="ne répond pas (docker logs litellm)"

# --- Attente de PentAGI + mot de passe admin ----------------------------------
cd "$PENTAGI_DIR"
log "Attente du démarrage de l'interface web PentAGI"
for i in $(seq 1 90); do
  curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/ | grep -qE '^(200|30[0-9])$' && break
  sleep 5
done

log "Changement du mot de passe admin PentAGI"
CJ=$(mktemp)
change_pw() {
  local cur=$1
  curl -sk -c "$CJ" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -d "{\"mail\":\"admin@pentagi.com\",\"password\":\"$cur\"}" \
    https://127.0.0.1:8443/api/v1/auth/login | grep -q '^200$' || return 1
  [ "$cur" = "$PENTAGI_ADMIN_PASSWORD" ] && return 0
  curl -sk -b "$CJ" -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: application/json' \
    -d "{\"current_password\":\"$cur\",\"password\":\"$PENTAGI_ADMIN_PASSWORD\",\"confirm_password\":\"$PENTAGI_ADMIN_PASSWORD\"}" \
    https://127.0.0.1:8443/api/v1/user/password | grep -q '^200$'
}
if change_pw "$PENTAGI_ADMIN_PASSWORD"; then ADMIN_STATE="ok"
elif change_pw admin; then ADMIN_STATE="ok (changé)"
else ADMIN_STATE="ÉCHEC - le mot de passe est peut-être resté 'admin', change-le dans l'interface"
fi
rm -f "$CJ"

# --- Mise à jour automatique de l'IP au démarrage -----------------------------
log "Installation du service de mise à jour d'IP"
cat > /usr/local/bin/pentagi-update-ip <<'EOF'
#!/usr/bin/env bash
# Réécrit l'IP publique dans la config PentAGI si elle a changé, puis redémarre.
set -euo pipefail
cd /opt/pentagi
IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
grep -q "^PUBLIC_URL=https://$IP:8443$" .env && exit 0
set_env() { sed -i "/^$1=/d" .env; printf '%s=%s\n' "$1" "$2" >> .env; }
set_env PUBLIC_URL "https://$IP:8443"
set_env CORS_ORIGINS "https://localhost:8443,https://$IP:8443"
set_env DOCKER_PUBLIC_IP "$IP"
docker compose up -d --force-recreate pentagi
sed -i "s#https://[0-9.]*:8443#https://$IP:8443#g" /root/credentials/pentagi.txt 2>/dev/null || true
echo "PentAGI mis à jour sur $IP"
EOF
chmod 755 /usr/local/bin/pentagi-update-ip
cat > /etc/systemd/system/pentagi-update-ip.service <<'EOF'
[Unit]
Description=Met à jour l'IP publique de PentAGI
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pentagi-update-ip

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable pentagi-update-ip.service

# --- Strix ---------------------------------------------------------------------
log "Installation de Strix"
export PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin
pipx install --force strix-agent
cat > "$CRED_DIR/strix.env" <<EOF
# Strix passe par LiteLLM (compatible OpenAI)
export STRIX_LLM="${STRIX_LLM:-openai/$CLAUDE_MODEL}"
export LLM_API_BASE="http://127.0.0.1:4000/v1"
export LLM_API_KEY="$LITELLM_MASTER_KEY"
EOF
grep -q 'credentials/strix.env' /root/.bashrc || \
  echo '[ -f /root/credentials/strix.env ] && . /root/credentials/strix.env' >> /root/.bashrc
log "Pré-téléchargement de l'image sandbox Strix"
SANDBOX_IMG=$(python3 - <<'EOF' 2>/dev/null || true
import glob,re
for f in glob.glob('/opt/pipx/venvs/strix-agent/lib/python3*/site-packages/strix/**/*.py', recursive=True):
    m = re.search(r'["\'](ghcr\.io/usestrix/strix-sandbox:[^"\']+)["\']', open(f).read())
    if m: print(m.group(1)); break
EOF
)
[ -n "$SANDBOX_IMG" ] && docker pull -q "$SANDBOX_IMG" || echo "(image sandbox téléchargée au 1er scan)"

# --- Jeton API PentAGI (utilisé par Hermes via pentagi-cli) -------------------
log "Jeton API PentAGI"
PAPI_ENV="$CRED_DIR/pentagi-api.env"
PAPI=https://127.0.0.1:8443/api/v1
token_ok() {
  [ -f "$PAPI_ENV" ] || return 1
  local t; t=$(grep '^PENTAGI_API_TOKEN=' "$PAPI_ENV" | cut -d= -f2-)
  curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $t" \
    "$PAPI/flows/?type=page&page=1&pageSize=1" | grep -q '^200$'
}
if token_ok; then PAPI_STATE="ok (existant)"
else
  CJ=$(mktemp)
  curl -sk -c "$CJ" -o /dev/null -H 'Content-Type: application/json' \
    -d "{\"mail\":\"admin@pentagi.com\",\"password\":\"$PENTAGI_ADMIN_PASSWORD\"}" "$PAPI/auth/login"
  # Le slash final est obligatoire (sinon redirection 307)
  NEW_TOKEN=$(curl -sk -b "$CJ" -H 'Content-Type: application/json' \
    -d '{"name":"hermes-agent","ttl":94608000}' "$PAPI/tokens/" | jq -r '.data.token // empty')
  rm -f "$CJ"
  if [ -n "$NEW_TOKEN" ]; then
    printf 'PENTAGI_API_URL=%s\nPENTAGI_API_TOKEN=%s\n' "$PAPI" "$NEW_TOKEN" > "$PAPI_ENV"
    PAPI_STATE="ok (créé, valable 3 ans)"
  else
    PAPI_STATE="ÉCHEC de création du jeton"
  fi
fi
chmod 600 "$PAPI_ENV" 2>/dev/null || true

# --- pentagi-cli : pilotage de PentAGI en ligne de commande -------------------
log "Installation de pentagi-cli"
cat > /usr/local/bin/pentagi-cli <<'PYEOF'
#!/usr/bin/env python3
"""pentagi-cli - pilote PentAGI via son API REST (utilisé par Hermes Agent).

Exemples :
  pentagi-cli list
  pentagi-cli create "Teste la sécurité de https://cible-autorisee.example"
  pentagi-cli show 3          pentagi-cli tasks 3
  pentagi-cli messages 3 -n 20  pentagi-cli terminal 3 -n 20
  pentagi-cli input 3 "Concentre-toi sur l'authentification"
  pentagi-cli wait 3 --timeout 3600
  pentagi-cli stop 3 | finish 3 | delete 3
"""
import argparse, json, os, ssl, sys, time, urllib.error, urllib.parse, urllib.request

ENV_FILE = "/root/credentials/pentagi-api.env"
CTX = ssl._create_unverified_context()  # certificat auto-signé local


def load_cfg():
    cfg = {}
    try:
        with open(ENV_FILE) as f:
            for line in f:
                if "=" in line and not line.startswith("#"):
                    k, v = line.strip().split("=", 1)
                    cfg[k] = v
    except OSError:
        pass
    url = os.environ.get("PENTAGI_API_URL", cfg.get("PENTAGI_API_URL", "https://127.0.0.1:8443/api/v1"))
    token = os.environ.get("PENTAGI_API_TOKEN", cfg.get("PENTAGI_API_TOKEN"))
    if not token:
        sys.exit(f"Jeton PentAGI introuvable ({ENV_FILE})")
    return url.rstrip("/"), token


URL, TOKEN = load_cfg()


def call(method, path, body=None, query=None):
    url = URL + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            msg = json.loads(raw).get("msg", raw.decode())
        except Exception:
            msg = raw.decode(errors="replace")
        sys.exit(f"Erreur PentAGI HTTP {e.code} sur {method} {path} : {msg}")
    except urllib.error.URLError as e:
        sys.exit(f"PentAGI injoignable ({URL}) : {e.reason}")
    if not raw:
        return None
    return json.loads(raw).get("data")


def listing(path, last=None):
    data = call("GET", path, query={"type": "page", "page": 1, "pageSize": 1000}) or {}
    items = next((v for v in data.values() if isinstance(v, list)), []) if isinstance(data, dict) else data
    items = sorted(items, key=lambda x: x.get("id", 0))
    return items[-last:] if last else items


def cut(s, n=400):
    s = (s or "").strip()
    return s if len(s) <= n else s[:n] + " […]"


def out(obj, as_json):
    if as_json:
        print(json.dumps(obj, indent=2, ensure_ascii=False))
        return True
    return False


def main():
    p = argparse.ArgumentParser(prog="pentagi-cli", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--json", action="store_true", help="sortie JSON brute")
    sp = p.add_subparsers(dest="cmd", required=True)
    sp.add_parser("providers", help="fournisseurs LLM disponibles")
    sp.add_parser("list", help="lister les flows")
    c = sp.add_parser("create", help="créer un flow (lance l'agent)")
    c.add_argument("task", help="consigne en langage naturel (cible + objectif)")
    c.add_argument("--provider", default="custom", help="fournisseur PentAGI (défaut : custom = Claude via LiteLLM)")
    for name, h in [("show", "détail d'un flow"), ("tasks", "tâches et résultats"),
                    ("stop", "arrêter"), ("finish", "terminer"), ("delete", "supprimer"),
                    ("usage", "consommation de tokens")]:
        sp.add_parser(name, help=h).add_argument("id", type=int)
    for name, h in [("messages", "journal des messages des agents"), ("terminal", "commandes exécutées")]:
        x = sp.add_parser(name, help=h)
        x.add_argument("id", type=int)
        x.add_argument("-n", type=int, default=30, help="dernières N entrées")
    i = sp.add_parser("input", help="envoyer une consigne à un flow en attente")
    i.add_argument("id", type=int)
    i.add_argument("text")
    w = sp.add_parser("wait", help="attendre qu'un flow ne soit plus en cours")
    w.add_argument("id", type=int)
    w.add_argument("--timeout", type=int, default=3600)
    w.add_argument("--interval", type=int, default=30)
    a = p.parse_args()

    if a.cmd == "providers":
        d = call("GET", "/providers/")
        if not out(d, a.json):
            for pr in d or []:
                print(f"{pr['name']:<10} modèle par défaut : {pr.get('default_model')}")
    elif a.cmd == "list":
        d = listing("/flows/")
        if not out(d, a.json):
            if not d:
                print("Aucun flow.")
            for f in d:
                print(f"#{f['id']:<4} {f.get('status',''):<10} {f.get('created_at','')[:19]}  {f.get('title','')}")
    elif a.cmd == "create":
        d = call("POST", "/flows/", {"input": a.task, "provider": a.provider})
        if not out(d, a.json):
            print(f"Flow #{d['id']} créé (statut : {d.get('status')}). Suivi : pentagi-cli show {d['id']}")
    elif a.cmd == "show":
        d = call("GET", f"/flows/{a.id}")
        if not out(d, a.json):
            print(f"#{d['id']} [{d.get('status')}] {d.get('title','')}\n"
                  f"modèle : {d.get('model_provider_name')}/{d.get('model')}  créé : {d.get('created_at','')[:19]}")
    elif a.cmd == "tasks":
        d = listing(f"/flows/{a.id}/tasks/")
        if not out(d, a.json):
            for t in d:
                print(f"- tâche #{t['id']} [{t.get('status')}] {t.get('title','')}")
                if t.get("result"):
                    print("  résultat :", cut(t["result"], 1500))
    elif a.cmd == "messages":
        d = listing(f"/flows/{a.id}/msglogs/", a.n)
        if not out(d, a.json):
            for m in d:
                print(f"[{m.get('type')}] {cut(m.get('message'))}")
                if m.get("result"):
                    print("   ->", cut(m["result"]))
    elif a.cmd == "terminal":
        d = listing(f"/flows/{a.id}/termlogs/", a.n)
        if not out(d, a.json):
            for t in d:
                print(f"[{t.get('type')}] {cut(t.get('text'), 800)}")
    elif a.cmd == "usage":
        out(call("GET", f"/flows/{a.id}/usage"), True)
    elif a.cmd in ("stop", "finish"):
        call("PUT", f"/flows/{a.id}", {"action": a.cmd})
        print(f"Flow #{a.id} : action {a.cmd} envoyée.")
    elif a.cmd == "input":
        call("PUT", f"/flows/{a.id}", {"action": "input", "input": a.text})
        print(f"Consigne envoyée au flow #{a.id}.")
    elif a.cmd == "delete":
        call("DELETE", f"/flows/{a.id}")
        print(f"Flow #{a.id} supprimé.")
    elif a.cmd == "wait":
        end = time.time() + a.timeout
        while True:
            st = (call("GET", f"/flows/{a.id}") or {}).get("status")
            if st not in ("created", "running"):
                print(f"Flow #{a.id} : {st}")
                break
            if time.time() > end:
                print(f"Flow #{a.id} toujours {st} après {a.timeout}s")
                sys.exit(3)
            time.sleep(a.interval)


if __name__ == "__main__":
    main()
PYEOF
chmod 755 /usr/local/bin/pentagi-cli

# --- strix-scan : lance Strix en arrière-plan, sans interface -----------------
log "Installation de strix-scan"
mkdir -p /root/strix-work/logs
cat > /usr/local/bin/strix-scan <<'SHEOF'
#!/usr/bin/env bash
# strix-scan - lance et suit des scans Strix non interactifs (utilisé par Hermes Agent).
#   strix-scan start <cible> [-m quick|standard|deep] [-i "consigne"] [-b budget_usd]
#   strix-scan list            scans lancés et état
#   strix-scan logs <id> [N]   dernières lignes du journal d'un scan
#   strix-scan stop <id>       arrêter un scan
#   strix-scan results         dossiers de résultats (rapports)
set -euo pipefail
WORK=/root/strix-work; LOGS=$WORK/logs
[ -f /root/credentials/strix.env ] && . /root/credentials/strix.env
cmd=${1:-help}; shift || true
case "$cmd" in
  start)
    target=${1:?cible manquante}; shift
    mode=standard; instr=""; budget=""
    while [ $# -gt 0 ]; do case "$1" in
      -m) mode=$2; shift 2 ;; -i) instr=$2; shift 2 ;; -b) budget=$2; shift 2 ;;
      *) echo "option inconnue : $1" >&2; exit 1 ;; esac; done
    id=$(date +%Y%m%d-%H%M%S)
    args=(-n -t "$target" -m "$mode")
    [ -n "$instr" ] && args+=(--instruction "$instr")
    [ -n "$budget" ] && args+=(--max-budget "$budget")
    cd "$WORK"
    nohup strix "${args[@]}" > "$LOGS/$id.log" 2>&1 &
    echo "$!" > "$LOGS/$id.pid"; echo "$target" > "$LOGS/$id.target"
    echo "Scan $id lancé sur $target (mode $mode, pid $!). Suivi : strix-scan logs $id" ;;
  list)
    for p in "$LOGS"/*.pid; do [ -e "$p" ] || { echo "Aucun scan."; break; }
      id=$(basename "$p" .pid); pid=$(cat "$p")
      if kill -0 "$pid" 2>/dev/null; then st="en cours"; else st="terminé"; fi
      echo "$id  $st  $(cat "$LOGS/$id.target" 2>/dev/null)"; done ;;
  logs) tail -n "${2:-60}" "$LOGS/${1:?id manquant}.log" ;;
  stop) kill "$(cat "$LOGS/${1:?id manquant}.pid")" && echo "Scan $1 arrêté." ;;
  results) ls -1t "$WORK/strix_runs" 2>/dev/null || echo "Aucun résultat pour l'instant." ;;
  *) sed -n '2,7p' "$0" ;;
esac
SHEOF
chmod 755 /usr/local/bin/strix-scan

# --- Hermes Agent (branché sur LiteLLM) ----------------------------------------
log "Installation de Hermes Agent"
pipx install hermes-agent || pipx upgrade hermes-agent || true
HPY=/opt/pipx/venvs/hermes-agent/bin/python
mkdir -p /root/.hermes/skills/pentagi /root/.hermes/skills/strix
hermes config set model.provider custom >/dev/null 2>&1 || true
CLAUDE_MODEL="$CLAUDE_MODEL" LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" "$HPY" - <<'PYEOF'
import os, yaml
p = "/root/.hermes/config.yaml"
cfg = (yaml.safe_load(open(p)) if os.path.exists(p) else None) or {}
m = cfg.setdefault("model", {})
m.update({"provider": "custom", "base_url": "http://127.0.0.1:4000/v1",
          "api_key": os.environ["LITELLM_MASTER_KEY"],
          "default": os.environ["CLAUDE_MODEL"], "context_length": 1000000})
sk = cfg.setdefault("skills", {})
auto = sk.get("auto_load") or []
for s in ("pentagi", "strix"):
    if s not in auto:
        auto.append(s)
sk["auto_load"] = auto
cfg.setdefault("approvals", {}).setdefault("mode", "smart")
yaml.safe_dump(cfg, open(p, "w"), sort_keys=False, allow_unicode=True)
PYEOF
chmod 600 /root/.hermes/config.yaml

cat > /root/.hermes/skills/pentagi/SKILL.md <<'EOF'
---
name: pentagi
description: Lancer, suivre et piloter des tests d'intrusion automatisés dans PentAGI (installé sur ce serveur) avec la commande pentagi-cli.
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [security, pentest, pentagi]
    category: security
    requires_toolsets: [terminal]
---

# PentAGI

PentAGI tourne sur ce serveur (Docker, https://127.0.0.1:8443). Ses agents utilisent
Claude via LiteLLM. On le pilote avec `pentagi-cli` (jeton déjà configuré).

## Règle absolue
Ne lance un flow que sur une cible pour laquelle l'utilisateur a confirmé avoir
l'autorisation de tester. En cas de doute, demande avant de lancer.

## Commandes
- `pentagi-cli list` : liste des flows (id, statut, titre)
- `pentagi-cli create "<cible + objectif + contraintes>"` : crée un flow et démarre les agents
- `pentagi-cli show <id>` : statut (created, running, waiting, finished, failed)
- `pentagi-cli tasks <id>` : tâches et leurs résultats (c'est là que sont les conclusions)
- `pentagi-cli messages <id> -n 30` : derniers messages des agents
- `pentagi-cli terminal <id> -n 30` : dernières commandes exécutées dans le conteneur Kali
- `pentagi-cli input <id> "<consigne>"` : répondre à un flow en statut `waiting`
- `pentagi-cli wait <id> --timeout 3600` : attendre la fin (bloquant)
- `pentagi-cli stop <id>` / `finish <id>` / `delete <id>`
- `pentagi-cli usage <id>` : consommation de tokens
- Ajouter `--json` avant la sous-commande pour une sortie brute.

## Méthode
1. Rédige une consigne précise : cible exacte, périmètre, ce qui est interdit.
2. `create`, puis surveille avec `show` / `messages` sans boucler trop vite
   (un flow dure de quelques minutes à plusieurs heures).
3. Quand le statut est `waiting`, lis les derniers messages et réponds avec `input`.
4. À la fin, résume les résultats de `tasks` pour l'utilisateur.
EOF

cat > /root/.hermes/skills/strix/SKILL.md <<'EOF'
---
name: strix
description: Lancer et suivre des scans de sécurité Strix (agents IA de test d'intrusion) sur une URL, un domaine, une IP ou un dépôt de code, avec la commande strix-scan.
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [security, pentest, strix]
    category: security
    requires_toolsets: [terminal]
---

# Strix

Strix est installé sur ce serveur et utilise Claude via LiteLLM
(variables dans /root/credentials/strix.env, chargées par strix-scan).

## Règle absolue
Ne scanne qu'une cible pour laquelle l'utilisateur a confirmé avoir l'autorisation
de tester. En cas de doute, demande avant de lancer.

## Commandes
- `strix-scan start <cible> [-m quick|standard|deep] [-i "consigne"] [-b budget_usd]`
  lance un scan en arrière-plan et affiche son identifiant.
  Par défaut : mode `standard`. Propose `-b` pour plafonner le coût.
- `strix-scan list` : scans lancés (en cours / terminé)
- `strix-scan logs <id> [N]` : dernières lignes du journal
- `strix-scan stop <id>` : arrêter un scan
- `strix-scan results` : dossiers de résultats dans /root/strix-work/strix_runs/

## Méthode
1. Confirme la cible et le mode avec l'utilisateur.
2. `strix-scan start ...`, puis suis avec `strix-scan logs <id>` à intervalles raisonnables.
3. À la fin, lis le rapport dans /root/strix-work/strix_runs/<run>/ et résume les
   vulnérabilités trouvées (gravité, preuve, correction).
EOF

# --- Fichiers récapitulatifs des identifiants ---------------------------------
cat > "$CRED_DIR/litellm.txt" <<EOF
=== LiteLLM ===
URL (serveur)    : http://127.0.0.1:4000/v1   (non exposé sur Internet)
URL (docker)     : http://litellm:4000/v1     (réseau pentagi-network)
Master key       : $LITELLM_MASTER_KEY
Modèles          : claude-opus-5-5, claude-sonnet-5-5, claude-haiku-5-5
Config           : $LITELLM_DIR/config.yaml
Clé Anthropic    : $LLM_ENV (ANTHROPIC_API_KEY)
Test             : curl -s http://127.0.0.1:4000/v1/chat/completions -H "Authorization: Bearer \$KEY" \\
                     -H 'Content-Type: application/json' \\
                     -d '{"model":"$CLAUDE_MODEL","messages":[{"role":"user","content":"ping"}]}'
EOF
cat > "$CRED_DIR/pentagi.txt" <<EOF
=== PentAGI ===
URL web          : https://$SERVER_IP:8443   (certificat auto-signé)
Login            : admin@pentagi.com
Mot de passe     : $PENTAGI_ADMIN_PASSWORD
État mot de passe: $ADMIN_STATE
LLM              : $CLAUDE_MODEL via LiteLLM (fournisseur "custom")

PostgreSQL       : postgres / $PENTAGI_POSTGRES_PASSWORD  (base pentagidb)
Scraper          : $LOCAL_SCRAPER_USERNAME / $LOCAL_SCRAPER_PASSWORD
Neo4j            : neo4j / $NEO4J_PASSWORD
Cookie salt      : $COOKIE_SIGNING_SALT

Config           : $PENTAGI_DIR/.env
Agents           : $PENTAGI_DIR/claude-litellm.provider.yml
Clés             : $LLM_ENV  (remplir puis relancer le script)
Changement d'IP  : automatique au boot, ou manuel : pentagi-update-ip

=== Strix ===
Binaire          : strix  (ou strix-scan pour un scan en arrière-plan)
Variables LLM    : $CRED_DIR/strix.env (chargées automatiquement dans le shell root)
Exemple          : strix-scan start https://cible-autorisee.example -m quick

=== Hermes Agent ===
Lancer           : hermes            (conversation)
                   hermes -z "liste les flows PentAGI"   (une seule demande)
Modèle           : $CLAUDE_MODEL via LiteLLM
Skills           : pentagi, strix (chargées à chaque session)
Outils           : pentagi-cli, strix-scan
Jeton PentAGI    : $PAPI_STATE  ($CRED_DIR/pentagi-api.env)
Config           : /root/.hermes/config.yaml
EOF
chmod 600 "$CRED_DIR"/*

log "Terminé"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "LiteLLM : $LITELLM_STATE"
cat "$CRED_DIR/pentagi.txt"
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo -e "\n\033[1;33m/!\\ Pas de clé ANTHROPIC_API_KEY : remplis $LLM_ENV puis relance ce script.\033[0m"
fi
