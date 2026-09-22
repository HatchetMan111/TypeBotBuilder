#!/usr/bin/env bash
#
# Typebot Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:     Typebot – Open-Source Chatbot-Builder (Builder :8080 + Viewer :8081)
# Upstream: https://github.com/baptisteArno/typebot.io
# Stack:   Node.js/Next.js (offizielle Docker-Images) + PostgreSQL 16 + Redis
# Läuft:   vollständig lokal im LXC, keine Cloud nötig
# Host:    DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TypeBotBuilder/main/install/typebot.sh)"
#   CT_ID=101 CORES=2 RAM=4096 DISK=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TypeBotBuilder/main/install/typebot.sh)"
#   bash typebot.sh --ctid 101 --cores 2 --memory 4096 --disk 20 --bridge vmbr0 --debug
#
# Hinweis: Typebot besteht aus 4 Containern (Builder, Viewer, Postgres, Redis).
# Darum weicht der Standard (2 vCPU / 4096 MB / 20 GB) bewusst von der
# 1–2-GB-Faustregel ab – mit 2 GB läuft Postgres + 2x Next.js in OOM.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="typebot"                                 # Container-Hostname + Service-Name
BUILDER_PORT="8080"                           # Typebot Builder Web UI (Upstream: 8080:3000)
VIEWER_PORT="8081"                            # Typebot Viewer Web UI (Upstream: 8081:3000)
BUILDER_IMAGE="baptistearno/typebot-builder:latest"
VIEWER_IMAGE="baptistearno/typebot-viewer:latest"
POSTGRES_IMAGE="postgres:16"
REDIS_IMAGE="redis:alpine"

DEFAULT_CORES="2"                             # vCPU (Typebot-Empfehlung: 2–4)
DEFAULT_RAM="4096"                            # RAM in MB (Minimum für Builder+Viewer+PG+Redis)
DEFAULT_SWAP="1024"                           # Swap (MB)
DEFAULT_DISK="20"                             # Disk in GB (Docker-Images + DB, min. 12)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"               # Template-Familie (Docker-getestet)
UNPRIVILEGED="1"
FEATURES="nesting=1,keyctl=1"                 # nesting/keyctl = Docker im LXC nötig

# Umgebungs-Overrides erlauben: CT_ID=101 CORES=4 RAM=8192 DISK=20 ./typebot.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS="$*"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe zusätzlich ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash typebot.sh [OPTIONEN]
  CT_ID=101 bash typebot.sh
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TypeBotBuilder/main/install/typebot.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM}, Minimum 4096 empfohlen)
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --debug, -x          set -x + maximale Fehlermeldungskette
  --help, -h           diese Hilfe

Nach der Installation:
  Builder: http://<LXC-IP>:${BUILDER_PORT}
  Viewer:  http://<LXC-IP>:${VIEWER_PORT}
EOF
}

# ---------------------------------------------------------------------------
# Debugging: komplette Fehlermeldungskette (Stacktrace, stderr/stdout, Exit-Code, Logs)
# ---------------------------------------------------------------------------
on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  set +x
  # Sehr lange Befehle (z. B. Heredoc-Blöcke) kürzen – das Log enthält alles.
  if ((${#cmd} > 2000)); then
    cmd="${cmd:0:2000}… [gekürzt, vollständiger Befehl in $LOG_FILE]"
  fi
  echo ""
  msg_error "════════════ INSTALLATION FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Args      : $SCRIPT_ARGS"
  msg_error "Logdatei  : $LOG_FILE (komplette stdout/stderr-Kette)"
  echo ""
  msg_error "--- Stacktrace (neuester Aufruf zuerst) ---"
  local i=0
  while caller "$i"; do ((i++)) || true; done
  echo ""
  if command -v pct >/dev/null 2>&1 && [[ -n "${CTID:-}" ]]; then
    msg_error "--- pct config ${CTID} ---"
    pct config "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- pct status ${CTID} ---"
    pct status "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- systemctl status im Container (typebot) ---"
    pct exec "${CTID}" -- systemctl status "${APP}" --no-pager --full 2>&1 || true
    echo ""
    msg_error "--- journalctl im Container (typebot, letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- journalctl -u "${APP}" --no-pager -n 100 2>&1 || true
    echo ""
    msg_error "--- docker ps im Container ---"
    pct exec "${CTID}" -- docker ps -a 2>&1 || true
    echo ""
    msg_error "--- docker compose logs (letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- docker compose -f /opt/typebot/docker-compose.yml logs --tail=100 --no-color 2>&1 || true
  fi
  echo ""
  msg_error "Re-run mit vollem Trace:"
  # shellcheck disable=SC2086
  msg_error "  bash -x typebot.sh $SCRIPT_ARGS"
  msg_error "  oder: DEBUG=1 bash typebot.sh $SCRIPT_ARGS"
  msg_error "Bitte bei Fehlermeldungen IMMER die komplette Logdatei ($LOG_FILE) mitschicken."
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="$CT_ID_ARG"
HOSTNAME_ARG="$APP"
CORES="$CORES_ARG"
RAM="$RAM_ARG"
DISK="$DISK_ARG"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
ROOT_PASSWORD=""
SSH_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)            CTID="${2:?--ctid braucht einen Wert}"; shift 2 ;;
    --hostname)        HOSTNAME_ARG="${2:?--hostname braucht einen Wert}"; shift 2 ;;
    --cores)           CORES="${2:?}"; shift 2 ;;
    --memory)          RAM="${2:?}"; shift 2 ;;
    --disk)            DISK="${2:?}"; shift 2 ;;
    --storage)         STORAGE_ARG="${2:?}"; shift 2 ;;
    --template-store)  TEMPLATE_STORE="${2:?}"; shift 2 ;;
    --bridge)          BRIDGE="${2:?}"; shift 2 ;;
    --password)        ROOT_PASSWORD="${2:?}"; shift 2 ;;
    --ssh-key)         SSH_KEY="${2:?}"; shift 2 ;;
    --debug|-x)        DEBUG="1"; set -x; shift ;;
    --help|-h)         usage; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done

# Trap NACH dem Parsen setzen, damit SCRIPT_ARGS die echten Args enthält
# shellcheck disable=SC2064
trap "on_error \$? \$LINENO \"\$BASH_COMMAND\"" ERR

# ---------------------------------------------------------------------------
# Pre-Checks (muss auf dem Proxmox-Host als root laufen)
# ---------------------------------------------------------------------------
msg_info "Prüfe Voraussetzungen (Proxmox-Host, root, Tools) ..."
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  msg_error "Bitte als root auf dem Proxmox-Host ausführen (sudo -i)."
  exit 1
fi
for bin in pct pveam pvesh pvesm wget curl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    msg_error "Benötigtes Tool fehlt: $bin – läuft das Skript wirklich auf einem Proxmox-VE-Host?"
    exit 1
  fi
done
if [[ "$RAM" -lt 4096 ]]; then
  msg_warn "RAM=${RAM} MB < 4096 MB – Typebot (Builder+Viewer+Postgres+Redis) braucht min. 4 GB, sonst OOM."
fi
if [[ "$DISK" -lt 12 ]]; then
  msg_warn "DISK=${DISK} GB < 12 GB – Docker-Images + DB brauchen min. ~12 GB."
fi
msg_ok "Host-Checks bestanden."

# ---------------------------------------------------------------------------
# CT-ID: immer die nächste freie ID nehmen (außer explizit gesetzt)
# ---------------------------------------------------------------------------
if [[ -z "$CTID" ]]; then
  msg_info "Ermittle nächste freie CT-ID ..."
  CTID="$(pvesh get /cluster/nextid)"
  msg_ok "Nächste freie CT-ID: $CTID"
else
  msg_info "CT-ID vorgegeben: $CTID"
fi

HOSTNAME_FINAL="$HOSTNAME_ARG"
if [[ ! "$HOSTNAME_FINAL" =~ ^[a-zA-Z0-9-]+$ ]]; then
  msg_error "Ungültiger Hostname: $HOSTNAME_FINAL (nur Buchstaben, Zahlen, Bindestrich)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Storage-Erkennung (idempotent: vorhandene Storages nutzen)
# ---------------------------------------------------------------------------
detect_storage() {
  local s
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | grep -x "local-lvm" || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | head -n1 || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  echo "local-lvm"
}
if [[ -z "$STORAGE_ARG" ]]; then
  STORAGE_ARG="$(detect_storage)"
  msg_info "RootFS-Storage (auto): $STORAGE_ARG"
else
  msg_info "RootFS-Storage (vorgegeben): $STORAGE_ARG"
fi

# ---------------------------------------------------------------------------
# Template sicherstellen
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Template-Liste (pveam update) ..."
pveam update

msg_info "Suche neuestes ${DEFAULT_OS}-Template auf ${TEMPLATE_STORE} ..."
TEMPLATE_FILE="$(pveam available --section system 2>/dev/null \
  | grep -o "${DEFAULT_OS}[^ ]*\\.tar\\.zst" | sort -V | tail -n1 || true)"
if [[ -z "$TEMPLATE_FILE" ]]; then
  msg_error "Kein Template für ${DEFAULT_OS} gefunden. Verfügbare Debian-Templates:"
  pveam available --section system 2>&1 | grep -i debian || true
  exit 1
fi
TEMPLATE_REF="${TEMPLATE_STORE}:vztmpl/${TEMPLATE_FILE}"
msg_info "Template: $TEMPLATE_REF"
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE_FILE"; then
  msg_info "Lade Template herunter (kann dauern) ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE_FILE"
else
  msg_ok "Template bereits vorhanden – Download übersprungen (idempotent)."
fi

# ---------------------------------------------------------------------------
# Container erstellen (idempotent: existiert die CT-ID schon, wiederverwenden)
# ---------------------------------------------------------------------------
CREATED_NOW=0
GENERATED_PW=0
if pct status "$CTID" >/dev/null 2>&1; then
  msg_warn "Container $CTID existiert bereits – wird wiederverwendet (idempotent, kein Neu-Erstellen)."
  EXISTING_HOST="$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}' || true)"
  msg_info "Bestehender Hostname: ${EXISTING_HOST:-unbekannt}"
else
  if [[ -z "$ROOT_PASSWORD" ]]; then
    ROOT_PASSWORD="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    GENERATED_PW=1
  fi
  msg_info "Erstelle LXC $CTID (hostname=${HOSTNAME_FINAL}, cores=${CORES}, ram=${RAM}MB, disk=${DISK}G) ..."
  CREATE_ARGS=(
    "$CTID" "$TEMPLATE_REF"
    --hostname "$HOSTNAME_FINAL"
    --cores "$CORES"
    --memory "$RAM"
    --swap "$DEFAULT_SWAP"
    --rootfs "${STORAGE_ARG}:${DISK}"
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
    --ostype debian
    --unprivileged "$UNPRIVILEGED"
    --features "$FEATURES"
    --onboot 1
    --start 0
    --password "$ROOT_PASSWORD"
  )
  if [[ -n "$SSH_KEY" ]]; then
    if [[ ! -f "$SSH_KEY" ]]; then msg_error "SSH-Key nicht gefunden: $SSH_KEY"; exit 1; fi
    CREATE_ARGS+=(--ssh-public-keys "$SSH_KEY")
  fi
  pct create "${CREATE_ARGS[@]}"
  # onboot + nesting explizit sicherstellen (Reboot-sicher, Docker-fähig)
  pct set "$CTID" --onboot 1 --features "$FEATURES"
  CREATED_NOW=1
  msg_ok "Container $CTID erstellt (Name: $HOSTNAME_FINAL, onboot=1, features=$FEATURES)."
fi

msg_info "Starte Container $CTID ..."
if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
  pct start "$CTID"
fi
for i in $(seq 1 30); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
  sleep 2
  if [[ "$i" -eq 30 ]]; then msg_error "Container $CTID reagiert nicht auf 'pct exec'."; exit 1; fi
done
msg_ok "Container $CTID läuft."

sleep 5

# ---------------------------------------------------------------------------
# Installation IM Container (idempotentes Setup-Skript via pct push + exec)
# ---------------------------------------------------------------------------
msg_info "Installiere ${APP} im Container (Docker + Compose-Stack: Builder/Viewer/Postgres/Redis) ..."

# systemd-Unit-Vorlage (identisch zu systemd/typebot.service im Repo)
read -r -d '' UNIT_FILE <<'UNIT_EOF' || true
[Unit]
Description=Typebot – Open-Source Chatbot-Builder (Docker Compose: Builder + Viewer + Postgres + Redis)
Documentation=https://docs.typebot.io/self-hosting/get-started
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/typebot
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_EOF

# Setup-Skript lokal bauen (Host-Variablen werden HIER expandiert,
# Container-Variablen sind mit \$ escaped und werden ERST im LXC expandiert).
TMP_SETUP="$(mktemp /tmp/typebot-setup.XXXXXX.sh)"
cat > "$TMP_SETUP" <<SETUP_EOF
#!/usr/bin/env bash
set -euo pipefail
APP="${APP}"
BUILDER_PORT="${BUILDER_PORT}"
VIEWER_PORT="${VIEWER_PORT}"
BUILDER_IMAGE="${BUILDER_IMAGE}"
VIEWER_IMAGE="${VIEWER_IMAGE}"
POSTGRES_IMAGE="${POSTGRES_IMAGE}"
REDIS_IMAGE="${REDIS_IMAGE}"

echo "[LXC] apt update + Basis-Pakete ..."
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates openssl iproute2 procps

echo "[LXC] Docker sicherstellen (idempotent) ..."
DOCKER_OK=0
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "[LXC] Docker + Compose bereits vorhanden: \$(docker --version) / \$(docker compose version --short)"
  DOCKER_OK=1
fi
if [[ "\$DOCKER_OK" != "1" ]]; then
  # Debian-Bookworm-Repos enthalten KEIN docker-compose-plugin (nur docker.io).
  # Darum: offizielles Docker-Repo (docker-ce + Compose v2); Fallback docker.io + Plugin-Binary.
  echo "[LXC] Installiere Docker aus dem offiziellen Docker-Repo ..."
  apt-get install -y --no-install-recommends gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 3 --max-time 60 https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  DARCH="\$(dpkg --print-architecture)"
  DCODENAME="\$(. /etc/os-release && echo "\$VERSION_CODENAME")"
  echo "deb [arch=\$DARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$DCODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  if apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
    echo "[LXC] Docker aus offiziellem Repo installiert."
  else
    echo "[LXC][WARN] Offizielles Docker-Repo fehlgeschlagen – Fallback: docker.io + Compose-Plugin-Binary von GitHub."
    rm -f /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y --no-install-recommends docker.io
    CMACHINE="\$(uname -m)"
    case "\$CMACHINE" in
      x86_64) CMARCH="x86_64" ;;
      aarch64|arm64) CMARCH="aarch64" ;;
      *) echo "[LXC][ERROR] Nicht unterstützte Architektur für Compose-Fallback: \$CMACHINE" >&2; exit 1 ;;
    esac
    mkdir -p /usr/libexec/docker/cli-plugins
    curl -fSL --retry 3 --max-time 180 -o /usr/libexec/docker/cli-plugins/docker-compose "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-\$CMARCH"
    chmod +x /usr/libexec/docker/cli-plugins/docker-compose
  fi
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
fi
docker --version
docker compose version

echo "[LXC] Container-IP ermitteln (fuer NEXTAUTH_URL / VIEWER_URL) ..."
LXC_IP="\$(ip -4 -o addr show eth0 2>/dev/null | awk '\$4 !~ /^127\\./ {print \$4}' | cut -d/ -f1 | head -n1 || true)"
if [[ -z "\$LXC_IP" ]]; then
  LXC_IP="\$(ip -4 -o addr show 2>/dev/null | awk '\$2 != "lo" && \$4 !~ /^127\\./ {print \$4}' | cut -d/ -f1 | head -n1 || true)"
fi
if [[ -z "\$LXC_IP" ]]; then
  echo "[LXC][ERROR] Keine IPv4-Adresse gefunden." >&2
  ip -4 -o addr show >&2 || true
  exit 1
fi
echo "[LXC] Container-IP: \$LXC_IP"

echo "[LXC] /opt/typebot vorbereiten (idempotent, Secrets bleiben erhalten) ..."
mkdir -p /opt/typebot
if [[ -f /opt/typebot/.env ]]; then
  # shellcheck disable=SC1091
  source /opt/typebot/.env || true
  echo "[LXC] Bestehende .env gefunden – Secrets werden wiederverwendet."
fi
if [[ -z "\${ENCRYPTION_SECRET:-}" ]]; then
  ENCRYPTION_SECRET="\$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)"
  echo "[LXC] Neuer ENCRYPTION_SECRET generiert."
fi
if [[ -z "\${POSTGRES_PASSWORD:-}" ]]; then
  POSTGRES_PASSWORD="\$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 24)"
  echo "[LXC] Neues POSTGRES_PASSWORD generiert."
fi
# URLs zeigen IMMER auf die aktuelle Container-IP (DHCP-Wechsel-safe)
NEXTAUTH_URL="http://\$LXC_IP:\$BUILDER_PORT"
NEXT_PUBLIC_VIEWER_URL="http://\$LXC_IP:\$VIEWER_PORT"
DATABASE_URL="postgresql://postgres:\$POSTGRES_PASSWORD@typebot-db:5432/typebot"
cat > /opt/typebot/.env <<ENV_EOF
ENCRYPTION_SECRET=\$ENCRYPTION_SECRET
POSTGRES_PASSWORD=\$POSTGRES_PASSWORD
DATABASE_URL=\$DATABASE_URL
NEXTAUTH_URL=\$NEXTAUTH_URL
NEXT_PUBLIC_VIEWER_URL=\$NEXT_PUBLIC_VIEWER_URL
NODE_OPTIONS=--no-node-snapshot
ENV_EOF
chmod 0600 /opt/typebot/.env
echo "[LXC] .env geschrieben (NEXTAUTH_URL=\$NEXTAUTH_URL)."

echo "[LXC] docker-compose.yml schreiben ..."
cat > /opt/typebot/docker-compose.yml <<'COMPOSE_EOF'
services:
  typebot-db:
    image: ${POSTGRES_IMAGE}
    restart: always
    volumes:
      - db-data:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=typebot
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - typebot-network

  typebot-redis:
    image: ${REDIS_IMAGE}
    restart: always
    command: --save 60 1 --loglevel warning
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep PONG"]
      start_period: 20s
      interval: 30s
      retries: 5
      timeout: 3s
    volumes:
      - redis-data:/data
    networks:
      - typebot-network

  typebot-builder:
    image: ${BUILDER_IMAGE}
    restart: always
    depends_on:
      typebot-redis:
        condition: service_healthy
      typebot-db:
        condition: service_healthy
    ports:
      - "8080:3000"
    env_file: .env
    environment:
      REDIS_URL: redis://typebot-redis:6379
    networks:
      - typebot-network

  typebot-viewer:
    image: ${VIEWER_IMAGE}
    restart: always
    depends_on:
      typebot-redis:
        condition: service_healthy
      typebot-db:
        condition: service_healthy
    ports:
      - "8081:3000"
    env_file: .env
    environment:
      REDIS_URL: redis://typebot-redis:6379
    networks:
      - typebot-network

networks:
  typebot-network:
    driver: bridge

volumes:
  db-data:
  redis-data:
COMPOSE_EOF
echo "[LXC] Compose-Stack: builder=\$BUILDER_IMAGE viewer=\$VIEWER_IMAGE"

echo "[LXC] systemd-Unit schreiben ..."
cat > /etc/systemd/system/typebot.service <<UNIT_INNER_EOF
${UNIT_FILE}
UNIT_INNER_EOF
systemctl daemon-reload
systemctl enable typebot

echo "[LXC] Images ziehen (kann beim ersten Mal dauern) ..."
cd /opt/typebot
docker compose pull || {
  echo "[LXC][WARN] 'docker compose pull' meldete Fehler – versuche trotzdem zu starten." >&2
  docker images >&2 || true
}

echo "[LXC] Stack (neu) starten ..."
if systemctl is-active --quiet typebot; then
  systemctl restart typebot
else
  systemctl start typebot
fi
sleep 10
# Falls die Unit auf 'docker compose up' (foreground) zeigt, sichert
# 'up -d' den detachten Betrieb zusätzlich ab (idempotent).
docker compose up -d
sleep 5

echo "[LXC] Warte auf Builder (http://127.0.0.1:\$BUILDER_PORT, max 240s) ..."
OK_BUILDER=0
for i in \$(seq 1 120); do
  if curl -fsS --max-time 5 "http://127.0.0.1:\$BUILDER_PORT" >/dev/null 2>&1; then OK_BUILDER=1; break; fi
  if [[ \$((i % 12)) -eq 0 ]]; then echo "[LXC] ... warte auf Builder (\${i}x2s), docker ps:"; docker ps --format '{{.Names}} {{.Status}}' || true; fi
  sleep 2
done
if [[ "\$OK_BUILDER" != "1" ]]; then
  echo "[LXC][ERROR] Builder antwortet nicht auf 127.0.0.1:\$BUILDER_PORT" >&2
  systemctl status typebot --no-pager --full >&2 || true
  journalctl -u typebot --no-pager -n 100 >&2 || true
  docker ps -a >&2 || true
  docker compose logs --tail=100 --no-color >&2 || true
  exit 1
fi
echo "[LXC] Builder antwortet."

echo "[LXC] Warte auf Viewer (http://127.0.0.1:\$VIEWER_PORT, max 240s) ..."
OK_VIEWER=0
for i in \$(seq 1 120); do
  if curl -fsS --max-time 5 "http://127.0.0.1:\$VIEWER_PORT" >/dev/null 2>&1; then OK_VIEWER=1; break; fi
  sleep 2
done
if [[ "\$OK_VIEWER" != "1" ]]; then
  echo "[LXC][ERROR] Viewer antwortet nicht auf 127.0.0.1:\$VIEWER_PORT" >&2
  docker compose logs --tail=100 --no-color >&2 || true
  exit 1
fi
echo "[LXC] Viewer antwortet."
echo "[LXC] Service aktiv: \$(systemctl is-active typebot)"
echo "[LXC] Container: \$(docker ps --format '{{.Names}} {{.Status}}' | tr '\\n' '; ')"
SETUP_EOF

chmod 0644 "$TMP_SETUP"
msg_info "Setup-Skript lokal: $TMP_SETUP (Kopie bleibt zur Fehlersuche erhalten)"
pct push "$CTID" "$TMP_SETUP" /tmp/typebot-setup.sh
pct exec "$CTID" -- bash /tmp/typebot-setup.sh
msg_ok "Installation im Container abgeschlossen."

# ---------------------------------------------------------------------------
# Verifikation vom Host aus (Service + HTTP + IP)
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."

SERVICE_STATE="$(pct exec "$CTID" -- systemctl is-active "$APP" 2>&1 || true)"
if [[ "$SERVICE_STATE" != "active" ]]; then
  msg_error "Service-Check fehlgeschlagen: 'systemctl is-active $APP' = '$SERVICE_STATE' (erwartet: active)"
  pct exec "$CTID" -- systemctl status "$APP" --no-pager --full || true
  pct exec "$CTID" -- journalctl -u "$APP" --no-pager -n 100 || true
  pct exec "$CTID" -- docker ps -a || true
  exit 1
fi
msg_ok "Service läuft (systemctl is-active $APP = active)."

if ! pct exec "$CTID" -- curl -fsS --max-time 10 "http://127.0.0.1:${BUILDER_PORT}" >/dev/null; then
  msg_error "HTTP-Check fehlgeschlagen: Builder http://127.0.0.1:${BUILDER_PORT} antwortet nicht."
  pct exec "$CTID" -- docker compose -f /opt/typebot/docker-compose.yml logs --tail=100 --no-color || true
  exit 1
fi
msg_ok "Builder antwortet (HTTP-Check auf localhost:${BUILDER_PORT})."

if ! pct exec "$CTID" -- curl -fsS --max-time 10 "http://127.0.0.1:${VIEWER_PORT}" >/dev/null; then
  msg_error "HTTP-Check fehlgeschlagen: Viewer http://127.0.0.1:${VIEWER_PORT} antwortet nicht."
  pct exec "$CTID" -- docker compose -f /opt/typebot/docker-compose.yml logs --tail=100 --no-color || true
  exit 1
fi
msg_ok "Viewer antwortet (HTTP-Check auf localhost:${VIEWER_PORT})."

CT_IP="$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
[[ -z "$CT_IP" ]] && CT_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

echo ""
echo -e "${C_GREEN}${C_BOLD}════════════════ INSTALLATION ERFOLGREICH ════════════════${C_RESET}"
echo -e "  App          : ${C_BOLD}Typebot – Open-Source Chatbot-Builder${C_RESET}"
echo -e "  Container    : CT ${C_BOLD}${CTID}${C_RESET} (Hostname: ${C_BOLD}${HOSTNAME_FINAL}${C_RESET}, onboot=1)"
echo -e "  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${DISK} GB Disk"
if [[ -n "${CT_IP:-}" ]]; then
echo -e "  Builder      : ${C_BOLD}http://${CT_IP}:${BUILDER_PORT}${C_RESET}"
echo -e "  Viewer       : ${C_BOLD}http://${CT_IP}:${VIEWER_PORT}${C_RESET}"
else
echo -e "  Builder      : ${C_BOLD}http://<LXC-IP>:${BUILDER_PORT}${C_RESET} (IP konnte nicht auto-ermittelt werden: pct exec $CTID -- ip a)"
echo -e "  Viewer       : ${C_BOLD}http://<LXC-IP>:${VIEWER_PORT}${C_RESET}"
fi
if [[ "$CREATED_NOW" == "1" && "$GENERATED_PW" == "1" ]]; then
echo -e "  Root-Passwort: ${C_BOLD}${ROOT_PASSWORD}${C_RESET} (nur jetzt angezeigt – sicher ablegen!)"
fi
echo -e "  Service      : systemctl status ${APP}  (im Container via: pct enter ${CTID})"
echo -e "  Stack        : cd /opt/typebot && docker compose ps / docker compose logs -f (im Container)"
echo -e "  Update       : Skript erneut laufen lassen (idempotent, zieht neueste Images + restart)"
echo -e "  Deinstall    : pct stop ${CTID} && pct destroy ${CTID}"
echo -e "  Reboot-Test  : pct reboot ${CTID} && sleep 60 && curl -fs http://${CT_IP:-<LXC-IP>}:${BUILDER_PORT} >/dev/null && curl -fs http://${CT_IP:-<LXC-IP>}:${VIEWER_PORT} >/dev/null"
echo -e "  Log          : ${LOG_FILE}"
echo -e "  Setup-Kopie  : ${TMP_SETUP}"
if [[ "$DEBUG" != "1" ]]; then
echo -e "  Debug bei Fehlern: ${C_CYAN}bash -x typebot.sh --ctid ${CTID}${C_RESET}"
fi
echo -e "${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
