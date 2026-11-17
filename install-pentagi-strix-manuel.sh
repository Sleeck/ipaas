# =============================================================================
#  PentAGI + Strix + Hermes Agent + LiteLLM (Claude) - VERSION PAS À PAS
#
#  NE PAS LANCER CE FICHIER D'UN COUP.
#  Copie-colle chaque bloc ÉTAPE dans un terminal root, l'un après l'autre,
#  et lis la vérification à la fin de chaque étape avant de passer à la suivante.
#  (Pour une installation automatique : install-pentagi-strix.sh)
#
#  Prérequis : Ubuntu 24.04, root, 4 Go de RAM, 20 Go de disque libre.
#
#  Architecture :
#     Hermes Agent ──┬─ pentagi-cli ──> PentAGI ──┐
#                    ├─ strix-scan ───> Strix ────┤
#                    │                            ▼
#                    └──────────────────> LiteLLM (127.0.0.1:4000) ──> API Anthropic (Claude)
#
#  Chaque bloc relit ce dont il a besoin dans /root/credentials : on peut
#  reprendre à n'importe quelle étape, même dans un nouveau terminal.
#  Tous les blocs peuvent être recollés sans risque.
# =============================================================================

[[ $- == *i* ]] || { echo "Ce fichier se colle bloc par bloc dans un terminal ; pour tout installer d'un coup, utilise install-pentagi-strix.sh"; exit 1; }


# =============================================================================
# ÉTAPE 0 - Vérifications
# =============================================================================
set +H   # désactive l'expansion de "!" dans ce terminal
[ "$(id -u)" -eq 0 ] && echo "OK root" || echo "STOP : passe en root (sudo -i)"
. /etc/os-release; echo "Système : $PRETTY_NAME   (attendu : Ubuntu 24.04)"
python3 -c 'import sys; print("Python :", sys.version.split()[0], "  (attendu : 3.12 ou 3.13)")'
awk '/MemTotal/ {printf "RAM : %d Mo   (attendu : >= 3500)\n", $2/1024}' /proc/meminfo
df -h --output=avail / | tail -1 | xargs echo "Disque libre :"
# -> Si une ligne ne correspond pas, ne va pas plus loin.


# =============================================================================
# ÉTAPE 1a - Fichier des clés et du modèle
# =============================================================================
mkdir -p /root/credentials && chmod 700 /root/credentials
touch /root/credentials/llm.env && chmod 600 /root/credentials/llm.env
grep -q '^# llm.env v2' /root/credentials/llm.env || cat > /root/credentials/llm.env <<'EOF'
# llm.env v2
# Clé API Anthropic (https://console.anthropic.com > API Keys), donnée UNIQUEMENT à LiteLLM.
ANTHROPIC_API_KEY=
# Modèle Claude utilisé partout : claude-opus-5-5, claude-sonnet-5-5 ou claude-haiku-5-5
CLAUDE_MODEL=claude-opus-5-5
# Optionnel : embeddings pour la mémoire de PentAGI (ex. voyageai / voyage-3.5 / pa-...)
EMBEDDING_PROVIDER=
EMBEDDING_MODEL=
EMBEDDING_URL=
EMBEDDING_KEY=
# Optionnel : modèle Strix (vide = openai/<CLAUDE_MODEL> via LiteLLM)
STRIX_LLM=
EOF
grep -E '^CLAUDE_MODEL=' /root/credentials/llm.env
# -> Pour changer de modèle : nano /root/credentials/llm.env


# =============================================================================
# ÉTAPE 1b - Saisie de la clé Anthropic
# =============================================================================
# Colle CETTE LIGNE SEULE, puis tape ou colle la clé et fais Entrée.
# Elle n'apparaît ni à l'écran ni dans l'historique. Entrée vide = plus tard.
read -rsp "Clé API Anthropic (sk-ant-..., Entrée pour plus tard) : " K; echo; [ -n "$K" ] && sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=$K|" /root/credentials/llm.env; unset K; grep -q '^ANTHROPIC_API_KEY=sk-' /root/credentials/llm.env && echo "Clé enregistrée." || echo "Pas de clé pour l'instant."


# =============================================================================
# ÉTAPE 2 - Paquets système et Docker
# =============================================================================
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -y
apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  ca-certificates curl wget unzip openssl jq git pipx python3-venv docker.io docker-compose-v2
systemctl enable --now docker
docker --version && docker compose version
# -> Les deux versions doivent s'afficher.


# =============================================================================
# ÉTAPE 3 - Génération des mots de passe (une seule fois, conservés ensuite)
# =============================================================================
S=/root/credentials/.pentagi-secrets.env; touch $S; chmod 600 $S
add() { grep -q "^$1=" $S || echo "$1=$2" >> $S; }
add COOKIE_SIGNING_SALT "$(openssl rand -hex 32)"
add PENTAGI_POSTGRES_PASSWORD "$(openssl rand -hex 24)"
add LOCAL_SCRAPER_USERNAME scraper
add LOCAL_SCRAPER_PASSWORD "$(openssl rand -hex 24)"
add NEO4J_PASSWORD "$(openssl rand -hex 24)"
add PENTAGI_ADMIN_PASSWORD "Pg$(openssl rand -hex 9)X7-"
add LITELLM_MASTER_KEY "sk-$(openssl rand -hex 24)"
cut -d= -f1 $S
# -> 7 noms de secrets doivent s'afficher (valeurs dans /root/credentials/.pentagi-secrets.env).


# =============================================================================
# ÉTAPE 4 - Configuration des agents PentAGI (tous sur Claude via LiteLLM)
# =============================================================================
. /root/credentials/llm.env; CLAUDE_MODEL=${CLAUDE_MODEL:-claude-opus-5-5}
case "$CLAUDE_MODEL" in
  claude-opus-5-5)   P_IN=4.00; P_OUT=20.00; P_CR=0.20 ;;
  claude-sonnet-5-5) P_IN=2.00; P_OUT=10.00; P_CR=0.10 ;;
  claude-haiku-5-5)  P_IN=0.10; P_OUT=0.50;  P_CR=0.01 ;;
  *)                 P_IN=0;    P_OUT=0;     P_CR=0 ;;
esac
mkdir -p /opt/pentagi
{
  echo "# Tous les agents sur $CLAUDE_MODEL via LiteLLM."
  echo "# Pas de temperature/top_p/reasoning : les modèles Claude 5.5 les refusent."
  for a in simple:4096 simple_json:4096 primary_agent:16000 assistant:16000 generator:16000 \
           refiner:16000 adviser:8192 reflector:8192 searcher:8192 enricher:8192 \
           coder:16000 installer:8192 pentester:16000; do
    printf '\n%s:\n  model: "%s"\n  n: 1\n  max_tokens: %s\n  price:\n    input: %s\n    output: %s\n    cache_read: %s\n' \
      "${a%%:*}" "$CLAUDE_MODEL" "${a##*:}" "$P_IN" "$P_OUT" "$P_CR"
  done
} > /opt/pentagi/claude-litellm.provider.yml
chmod 644 /opt/pentagi/claude-litellm.provider.yml
grep -c 'model:' /opt/pentagi/claude-litellm.provider.yml
# -> Doit afficher 13 (un par agent).


# =============================================================================
# ÉTAPE 5 - PentAGI : téléchargement et fichier .env
# =============================================================================
. /root/credentials/llm.env; . /root/credentials/.pentagi-secrets.env
CLAUDE_MODEL=${CLAUDE_MODEL:-claude-opus-5-5}
SERVER_IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
echo "IP principale : $SERVER_IP"
cd /opt/pentagi
RAW=https://raw.githubusercontent.com/vxcontrol/pentagi/master
curl -fsSL -o docker-compose.yml $RAW/docker-compose.yml
[ -f .env ] || curl -fsSL -o .env $RAW/.env.example
[ -f example.custom.provider.yml ]  || curl -fsSL -o example.custom.provider.yml  $RAW/examples/configs/custom-openai.provider.yml
[ -f example.ollama.provider.yml ]  || curl -fsSL -o example.ollama.provider.yml  $RAW/examples/configs/ollama-llama318b.provider.yml
[ -f example.bedrock.provider.yml ] || curl -fsSL -o example.bedrock.provider.yml $RAW/examples/configs/bedrock.provider.yml
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
set_env PENTAGI_LLM_SERVER_CONFIG_PATH /opt/pentagi/claude-litellm.provider.yml
for k in OPEN_AI_KEY ANTHROPIC_API_KEY GEMINI_API_KEY DEEPSEEK_API_KEY MISTRAL_API_KEY XAI_API_KEY OLLAMA_SERVER_URL; do
  set_env "$k" ""   # pas d'accès direct : tout passe par LiteLLM
done
for k in EMBEDDING_PROVIDER EMBEDDING_MODEL EMBEDDING_URL EMBEDDING_KEY; do set_env "$k" "${!k:-}"; done
chmod 600 .env
grep -E '^(PUBLIC_URL|LLM_SERVER_URL|LLM_SERVER_MODEL)=' .env
# -> Doit afficher ton IP et http://litellm:4000/v1.


# =============================================================================
# ÉTAPE 6 - PentAGI : démarrage (quelques minutes : téléchargement des images)
# =============================================================================
cd /opt/pentagi && docker compose pull -q && docker compose up -d --remove-orphans
for i in $(seq 1 90); do
  curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/ | grep -qE '^(200|30[0-9])$' && break; sleep 5
done
docker compose ps --format 'table {{.Name}}\t{{.Status}}'
curl -sk -o /dev/null -w "Interface web PentAGI : HTTP %{http_code}\n" https://127.0.0.1:8443/
# -> pentagi, pgvector, scraper, pgexporter "Up" et HTTP 200.


# =============================================================================
# ÉTAPE 7 - LiteLLM (proxy vers Claude)
# =============================================================================
. /root/credentials/llm.env; . /root/credentials/.pentagi-secrets.env
mkdir -p /opt/litellm && cd /opt/litellm
printf 'ANTHROPIC_API_KEY=%s\nLITELLM_MASTER_KEY=%s\n' "${ANTHROPIC_API_KEY:-}" "$LITELLM_MASTER_KEY" > .env
chmod 600 .env
{
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
  printf '\nlitellm_settings:\n  drop_params: true\n\ngeneral_settings:\n  master_key: os.environ/LITELLM_MASTER_KEY\n'
} > config.yaml
chmod 644 config.yaml
cat > docker-compose.yml <<'EOF'
services:
  litellm:
    image: ghcr.io/berriai/litellm:main-stable
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
docker compose pull -q && docker compose up -d --force-recreate
for i in $(seq 1 60); do curl -sf http://127.0.0.1:4000/health/liveliness >/dev/null && break; sleep 3; done
curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://127.0.0.1:4000/v1/models | jq -r '.data[].id'
# -> Doit lister claude-opus-5-5, claude-sonnet-5-5, claude-haiku-5-5.


# =============================================================================
# ÉTAPE 8 - Test de Claude via LiteLLM (seulement si la clé est renseignée)
# =============================================================================
. /root/credentials/llm.env; . /root/credentials/.pentagi-secrets.env
curl -s http://127.0.0.1:4000/v1/chat/completions -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${CLAUDE_MODEL:-claude-opus-5-5}\",\"max_tokens\":50,\"messages\":[{\"role\":\"user\",\"content\":\"Réponds juste: OK\"}]}" \
  | jq -r '.choices[0].message.content // .error.message'
# -> "OK" si la clé fonctionne ; sinon le message d'erreur d'Anthropic.


# =============================================================================
# ÉTAPE 9 - Mot de passe admin PentAGI (remplace admin / admin)
# =============================================================================
. /root/credentials/.pentagi-secrets.env
API=https://127.0.0.1:8443/api/v1; CJ=$(mktemp)
login() { curl -sk -c $CJ -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d "{\"mail\":\"admin@pentagi.com\",\"password\":\"$1\"}" $API/auth/login; }
if [ "$(login "$PENTAGI_ADMIN_PASSWORD")" = 200 ]; then echo "Mot de passe déjà changé."
elif [ "$(login admin)" = 200 ]; then
  curl -sk -b $CJ -o /dev/null -w "Changement : HTTP %{http_code}\n" -X PUT -H 'Content-Type: application/json' \
    -d "{\"current_password\":\"admin\",\"password\":\"$PENTAGI_ADMIN_PASSWORD\",\"confirm_password\":\"$PENTAGI_ADMIN_PASSWORD\"}" \
    $API/user/password
else echo "STOP : ni l'ancien ni le nouveau mot de passe ne fonctionnent."; fi
echo "Vérification connexion admin : HTTP $(login "$PENTAGI_ADMIN_PASSWORD")"; rm -f $CJ
# -> "Changement : HTTP 200" puis "Vérification connexion admin : HTTP 200".


# =============================================================================
# ÉTAPE 10 - Mise à jour automatique de l'IP au démarrage du serveur
# =============================================================================
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
systemctl daemon-reload && systemctl enable pentagi-update-ip.service
systemctl is-enabled pentagi-update-ip.service
# -> "enabled".


# =============================================================================
# ÉTAPE 11 - Strix (+ lanceur strix-scan)
# =============================================================================
. /root/credentials/llm.env; . /root/credentials/.pentagi-secrets.env
export PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin
pipx install --force strix-agent
umask 077; cat > /root/credentials/strix.env <<EOF
# Strix passe par LiteLLM (compatible OpenAI)
export STRIX_LLM="${STRIX_LLM:-openai/${CLAUDE_MODEL:-claude-opus-5-5}}"
export LLM_API_BASE="http://127.0.0.1:4000/v1"
export LLM_API_KEY="$LITELLM_MASTER_KEY"
EOF
umask 022
grep -q 'credentials/strix.env' /root/.bashrc || \
  echo '[ -f /root/credentials/strix.env ] && . /root/credentials/strix.env' >> /root/.bashrc
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
# Pré-téléchargement de l'image sandbox Strix (sinon fait au 1er scan)
IMG=$(grep -rhoE 'ghcr\.io/usestrix/strix-sandbox:[0-9A-Za-z._-]+' /opt/pipx/venvs/strix-agent/lib/python3*/site-packages/strix 2>/dev/null | head -1)
[ -n "$IMG" ] && docker pull -q "$IMG"
. /root/credentials/strix.env; strix --version; strix-scan list
# -> Une version de Strix puis "Aucun scan.".


# =============================================================================
# ÉTAPE 12 - Jeton API PentAGI et outil pentagi-cli
# =============================================================================
. /root/credentials/.pentagi-secrets.env
API=https://127.0.0.1:8443/api/v1; PE=/root/credentials/pentagi-api.env
T=$(grep -s '^PENTAGI_API_TOKEN=' $PE | cut -d= -f2-)
if [ -n "$T" ] && [ "$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $T" "$API/flows/?type=page&page=1&pageSize=1")" = 200 ]; then
  echo "Jeton existant valide."
else
  CJ=$(mktemp)
  curl -sk -c $CJ -o /dev/null -H 'Content-Type: application/json' \
    -d "{\"mail\":\"admin@pentagi.com\",\"password\":\"$PENTAGI_ADMIN_PASSWORD\"}" $API/auth/login
  # Le slash final de /tokens/ est obligatoire (sinon redirection 307)
  T=$(curl -sk -b $CJ -H 'Content-Type: application/json' -d '{"name":"hermes-agent","ttl":94608000}' "$API/tokens/" | jq -r '.data.token // empty')
  rm -f $CJ
  [ -n "$T" ] && (umask 077; printf 'PENTAGI_API_URL=%s\nPENTAGI_API_TOKEN=%s\n' "$API" "$T" > $PE) && echo "Jeton créé (valable 3 ans)." || echo "STOP : création du jeton impossible."
fi
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
pentagi-cli providers; pentagi-cli list
# -> "custom  modèle par défaut : claude-..." puis "Aucun flow." (ou la liste).


# =============================================================================
# ÉTAPE 13 - Hermes Agent (branché sur LiteLLM)
# =============================================================================
. /root/credentials/llm.env; . /root/credentials/.pentagi-secrets.env
export PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin
pipx install hermes-agent || pipx upgrade hermes-agent
hermes config set model.provider custom >/dev/null 2>&1
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-5-5}" LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" \
/opt/pipx/venvs/hermes-agent/bin/python - <<'PYEOF'
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
print("Hermes :", m["provider"], m["base_url"], m["default"], "| skills :", auto, "| approbations :", cfg["approvals"]["mode"])
PYEOF
chmod 600 /root/.hermes/config.yaml
# -> "Hermes : custom http://127.0.0.1:4000/v1 claude-... | skills : ['pentagi', 'strix'] | approbations : smart"


# =============================================================================
# ÉTAPE 14 - Skills Hermes : pentagi et strix
# =============================================================================
mkdir -p /root/.hermes/skills/pentagi /root/.hermes/skills/strix
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
hermes skills list 2>/dev/null | grep -E 'pentagi|strix'
# -> Les deux skills "enabled".


# =============================================================================
# ÉTAPE 15 - Récapitulatif des identifiants
# =============================================================================
. /root/credentials/llm.env; . /root/credentials/.pentagi-secrets.env
SERVER_IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
umask 077
cat > /root/credentials/litellm.txt <<EOF
=== LiteLLM ===
URL (serveur)    : http://127.0.0.1:4000/v1   (non exposé sur Internet)
URL (docker)     : http://litellm:4000/v1     (réseau pentagi-network)
Master key       : $LITELLM_MASTER_KEY
Modèles          : claude-opus-5-5, claude-sonnet-5-5, claude-haiku-5-5
Config           : /opt/litellm/config.yaml
Clé Anthropic    : /root/credentials/llm.env (ANTHROPIC_API_KEY)
EOF
cat > /root/credentials/pentagi.txt <<EOF
=== PentAGI ===
URL web          : https://$SERVER_IP:8443   (certificat auto-signé)
Login            : admin@pentagi.com
Mot de passe     : $PENTAGI_ADMIN_PASSWORD
LLM              : ${CLAUDE_MODEL:-claude-opus-5-5} via LiteLLM (fournisseur "custom")

PostgreSQL       : postgres / $PENTAGI_POSTGRES_PASSWORD  (base pentagidb)
Scraper          : $LOCAL_SCRAPER_USERNAME / $LOCAL_SCRAPER_PASSWORD
Neo4j            : neo4j / $NEO4J_PASSWORD
Cookie salt      : $COOKIE_SIGNING_SALT

Config           : /opt/pentagi/.env
Agents           : /opt/pentagi/claude-litellm.provider.yml
Clés             : /root/credentials/llm.env
Changement d'IP  : automatique au boot, ou manuel : pentagi-update-ip

=== Strix ===
Binaire          : strix  (ou strix-scan pour un scan en arrière-plan)
Variables LLM    : /root/credentials/strix.env (chargées automatiquement dans le shell root)
Exemple          : strix-scan start https://cible-autorisee.example -m quick

=== Hermes Agent ===
Lancer           : hermes            (conversation)
                   hermes -z "liste les flows PentAGI"   (une seule demande)
Modèle           : ${CLAUDE_MODEL:-claude-opus-5-5} via LiteLLM
Skills           : pentagi, strix (chargées à chaque session)
Outils           : pentagi-cli, strix-scan
Jeton PentAGI    : /root/credentials/pentagi-api.env
Config           : /root/.hermes/config.yaml
EOF
umask 022
ls -la /root/credentials
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "PentAGI : https://$SERVER_IP:8443  (identifiants : cat /root/credentials/pentagi.txt)"
# -> 5 conteneurs "Up" (pentagi, pgvector, scraper, pgexporter, litellm).


# =============================================================================
# PLUS TARD - Ajouter ou changer la clé Anthropic / le modèle
# =============================================================================
# 1. nano /root/credentials/llm.env        (ANTHROPIC_API_KEY, CLAUDE_MODEL)
# 2. Recoller les étapes 4, 5, 6, 7, 8, 11, 13 et 15.
