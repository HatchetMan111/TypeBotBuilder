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

# Auth-Provider (Typebot verlangt mind. einen, sonst Anmelde-Hinweis im Builder).
# Alles optional – was gesetzt ist, landet in /opt/typebot/.env (idempotent).
# SMTP-Weiteres: SMTP_HOST=user.mailhost, SMTP_PORT, SMTP_USER/ SMTP_PASS,
# SMTP_FROM="Anzeigename <absender@domain>", SMTP_SECURE=true nur für Port 465.
ADMIN_EMAIL_ARG="${ADMIN_EMAIL:-}"
SMTP_HOST_ARG="${SMTP_HOST:-}"
SMTP_PORT_ARG="${SMTP_PORT:-}"
SMTP_USER_ARG="${SMTP_USER:-}"
SMTP_PASS_ARG="${SMTP_PASS:-}"
SMTP_FROM_ARG="${SMTP_FROM:-}"
SMTP_SECURE_ARG="${SMTP_SECURE:-}"
SMTP_LOCAL_ARG="${SMTP_LOCAL:-0}"             # 1 = lokales Postfix im LXC (ohne Zugangsdaten)
GITHUB_ID_ARG="${GITHUB_ID:-}"
GITHUB_SECRET_ARG="${GITHUB_SECRET:-}"
GOOGLE_ID_ARG="${GOOGLE_ID:-}"
GOOGLE_SECRET_ARG="${GOOGLE_SECRET:-}"
LOGIN_EMAIL_ARG="${LOGIN_EMAIL:-}"            # Default: typebot@typebot.local (Auto-Login)
NO_AUTO_LOGIN_ARG="${NO_AUTO_LOGIN:-0}"       # 1 = kein automatischer Erstanmelde-Code

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
  --admin-email MAIL   Admin-Mail (erhält UNLIMITED-Plan bei Registrierung)
  --smtp-host HOST     SMTP-Server für E-Mail-Login (Magic-Links)
  --smtp-port PORT     SMTP-Port (Default: 25, 587 mit STARTTLS, 465 mit --smtp-secure)
  --smtp-user USER     SMTP-Benutzer (darf Sonderzeichen enthalten)
  --smtp-pass PASS     SMTP-Passwort (darf Sonderzeichen enthalten; lieber als ENV SMTP_PASS)
  --smtp-from FROM     Absender, z. B. 'Typebot <noreply@domain.tld>'
  --smtp-secure        SMTP mit implizitem TLS (nur für Port 465)
  --smtp-local         explizites lokales Postfix (ohne Flags ist das bereits
                       Default, solange kein externes SMTP angegeben ist)
  --github-id ID       GitHub-OAuth Client-ID (+ --github-secret)
  --github-secret S    GitHub-OAuth Secret (lieber als ENV GITHUB_SECRET)
  --google-id ID       Google-OAuth Client-ID (+ --google-secret)
  --google-secret S    Google-OAuth Secret (lieber als ENV GOOGLE_SECRET)
  --login-email MAIL   Adresse für den automatischen Erstanmelde-Code
                       (Default: typebot@typebot.local, lokal zugestellt)
  --no-auto-login      keinen Erstanmelde-Code erzeugen/ausgeben
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
ADMIN_EMAIL="$ADMIN_EMAIL_ARG"
SMTP_HOST="$SMTP_HOST_ARG"
SMTP_PORT="$SMTP_PORT_ARG"
SMTP_USER="$SMTP_USER_ARG"
SMTP_PASS="$SMTP_PASS_ARG"
SMTP_FROM="$SMTP_FROM_ARG"
SMTP_SECURE="$SMTP_SECURE_ARG"
SMTP_LOCAL="$SMTP_LOCAL_ARG"
GITHUB_ID="$GITHUB_ID_ARG"
GITHUB_SECRET="$GITHUB_SECRET_ARG"
GOOGLE_ID="$GOOGLE_ID_ARG"
GOOGLE_SECRET="$GOOGLE_SECRET_ARG"
LOGIN_EMAIL="$LOGIN_EMAIL_ARG"
NO_AUTO_LOGIN="$NO_AUTO_LOGIN_ARG"

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
    --admin-email)     ADMIN_EMAIL="${2:?--admin-email braucht einen Wert}"; shift 2 ;;
    --smtp-host)       SMTP_HOST="${2:?--smtp-host braucht einen Wert}"; shift 2 ;;
    --smtp-port)       SMTP_PORT="${2:?--smtp-port braucht einen Wert}"; shift 2 ;;
    --smtp-user)       SMTP_USER="${2:?--smtp-user braucht einen Wert}"; shift 2 ;;
    --smtp-pass)       SMTP_PASS="${2:?--smtp-pass braucht einen Wert}"; shift 2 ;;
    --smtp-from)       SMTP_FROM="${2:?--smtp-from braucht einen Wert}"; shift 2 ;;
    --smtp-secure)     SMTP_SECURE="true"; shift ;;
    --smtp-local)      SMTP_LOCAL="1"; shift ;;
    --github-id)       GITHUB_ID="${2:?--github-id braucht einen Wert}"; shift 2 ;;
    --github-secret)   GITHUB_SECRET="${2:?--github-secret braucht einen Wert}"; shift 2 ;;
    --google-id)       GOOGLE_ID="${2:?--google-id braucht einen Wert}"; shift 2 ;;
    --google-secret)   GOOGLE_SECRET="${2:?--google-secret braucht einen Wert}"; shift 2 ;;
    --login-email)     LOGIN_EMAIL="${2:?--login-email braucht einen Wert}"; shift 2 ;;
    --no-auto-login)   NO_AUTO_LOGIN="1"; shift ;;
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
if [[ -n "$SMTP_PORT" && ! "$SMTP_PORT" =~ ^[0-9]+$ ]]; then
  msg_error "Ungültiger --smtp-port: $SMTP_PORT (nur Zahlen, z. B. 25, 587, 465)"
  exit 1
fi
if [[ -n "$SMTP_SECURE" && "$SMTP_SECURE" != "true" && "$SMTP_SECURE" != "false" ]]; then
  msg_error "Ungültiges SMTP_SECURE: $SMTP_SECURE (nur true/false)"
  exit 1
fi
if [[ -z "$SMTP_HOST" && -z "$GITHUB_ID" && -z "$GOOGLE_ID" && "$SMTP_LOCAL" != "1" && "$NO_AUTO_LOGIN" == "1" ]]; then
  msg_warn "Kein Auth-Provider und kein Auto-Login – Builder zeigt:"
  msg_warn "  'mindestens einen Authentifizierungsanbieter konfigurieren'."
  msg_warn "  Tipp: Flag weglassen (Auto-Login ist Default) oder --smtp-host ... mitgeben (siehe --help)."
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
    ROOT_PASSWORD="$(openssl rand -hex 8)"
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
# Auth-Provider-Optionen vom Host (Flags/ENV); leere Werte = nicht konfiguriert.
ADMIN_EMAIL="${ADMIN_EMAIL}"
SMTP_HOST="${SMTP_HOST}"
SMTP_PORT="${SMTP_PORT}"
SMTP_USER="${SMTP_USER}"
SMTP_PASS="${SMTP_PASS}"
SMTP_FROM="${SMTP_FROM}"
SMTP_SECURE="${SMTP_SECURE}"
SMTP_LOCAL="${SMTP_LOCAL}"
GITHUB_ID="${GITHUB_ID}"
GITHUB_SECRET="${GITHUB_SECRET}"
GOOGLE_ID="${GOOGLE_ID}"
GOOGLE_SECRET="${GOOGLE_SECRET}"
LOGIN_EMAIL="${LOGIN_EMAIL}"
NO_AUTO_LOGIN="${NO_AUTO_LOGIN}"

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
# Sicheres Einlesen (KEIN source: Zeichen wie $ oder ! in Passwoertern
# wuerden sonst expandiert/ausgefuehrt). Liest KEY=VALUE literal, ohne Ausfuehrung.
load_env_file() {
  local line key val
  while IFS= read -r line || [[ -n "\$line" ]]; do
    [[ "\$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="\${line%%=*}"; val="\${line#*=}"
    if (( \${#val} >= 2 )); then
      if [[ "\${val:0:1}" == '"' && "\${val: -1}" == '"' ]]; then val="\${val:1:-1}"
      elif [[ "\${val:0:1}" == "'" && "\${val: -1}" == "'" ]]; then val="\${val:1:-1}"
      fi
    fi
    # Host-Flags/ENV gewinnen: nur setzen, wenn noch leer (nicht gesetzte
    # Host-Optionen sind "" und werden so aus der gespeicherten .env gefuellt).
    if [[ -z "\${!key:-}" ]]; then printf -v "\$key" '%s' "\$val"; fi
  done < "\$1"
}
if [[ -f /opt/typebot/.env ]]; then
  load_env_file /opt/typebot/.env
  echo "[LXC] Bestehende .env gefunden – Secrets/Provider werden wiederverwendet."
fi
# Secrets mit GARANTIERTER Laenge: 'openssl rand -hex N' liefert exakt 2*N
# Zeichen, ganz ohne Filter-Pipe. (Die naive Variante 'rand -base64 N |
# tr -dc ... | head -c N' ist KAPUTT: tr entfernt +/=, head fuellt NICHT auf
# -> Secret meist zu kurz. Typebot validiert ENCRYPTION_SECRET >= 32 Zeichen
# im Instrumentation-Hook und wirft sonst auf JEDE Route HTTP 500.)
if [[ -z "\${ENCRYPTION_SECRET:-}" ]] || (( \${#ENCRYPTION_SECRET} < 32 )); then
  [[ -n "\${ENCRYPTION_SECRET:-}" ]] && echo "[LXC][WARN] ENCRYPTION_SECRET zu kurz (\${#ENCRYPTION_SECRET} statt >=32 Zeichen) – wird neu generiert (sonst dauerhaft HTTP 500)."
  ENCRYPTION_SECRET="\$(openssl rand -hex 16)"
  echo "[LXC] Neuer ENCRYPTION_SECRET generiert (\${#ENCRYPTION_SECRET} Zeichen)."
fi
(( \${#ENCRYPTION_SECRET} >= 32 )) || { echo "[LXC][ERROR] ENCRYPTION_SECRET-Generierung fehlgeschlagen." >&2; exit 1; }
# POSTGRES_PASSWORD NUR beim Erst-Setup erzeugen – spaeter aendern wuerde die
# DB-Auth brechen (Volume mit initialisiertem Passwort bleibt erhalten).
if [[ -z "\${POSTGRES_PASSWORD:-}" ]]; then
  POSTGRES_PASSWORD="\$(openssl rand -hex 12)"
  echo "[LXC] Neues POSTGRES_PASSWORD generiert (\${#POSTGRES_PASSWORD} Zeichen)."
fi

# 127.0.0.1/localhost erreicht der Builder-Container NICHT (eigenes Loopback)
# -> als "lokal" werten und ueber host.docker.internal + Postfix routen.
if [[ "\$SMTP_HOST" == "127.0.0.1" || "\$SMTP_HOST" == "localhost" ]]; then SMTP_HOST=""; fi

# Login-Adresse normalisieren (Postfix-Zustellung ist case-sensitiv).
if [[ -z "\$LOGIN_EMAIL" ]]; then LOGIN_EMAIL="typebot@typebot.local"; LOGIN_EXPLICIT=0; else LOGIN_EXPLICIT=1; fi
LOGIN_EMAIL="\$(printf '%s' "\$LOGIN_EMAIL" | tr '[:upper:]' '[:lower:]')"
LOGIN_LOCALPART="\${LOGIN_EMAIL%%@*}"; LOGIN_DOMAIN="\${LOGIN_EMAIL#*@}"
# Erster Nutzer bekommt den UNLIMITED-Plan (Upstream: ADMIN_EMAIL).
if [[ -z "\$ADMIN_EMAIL" ]]; then ADMIN_EMAIL="\$LOGIN_EMAIL"; echo "[LXC] ADMIN_EMAIL default: \$ADMIN_EMAIL"; fi

# Lokales Postfix: Default wenn kein externes SMTP konfiguriert ist (dann
# klappt der Erstanmelde-Code ohne jegliche Zugangsdaten). Explizite SMTP_*-
# Werte gewinnen immer gegen diese Defaults.
USE_LOCAL_SMTP=0
if [[ "\$SMTP_LOCAL" == "1" ]]; then USE_LOCAL_SMTP=1; fi
if [[ -z "\$SMTP_HOST" && "\$NO_AUTO_LOGIN" != "1" ]]; then USE_LOCAL_SMTP=1; fi
if [[ "\$USE_LOCAL_SMTP" == "1" ]]; then
  echo "[LXC] Installiere lokales Postfix (fuer Builder erreichbar als host.docker.internal:25) ..."
  apt-get install -y --no-install-recommends postfix
  echo "typebot.local" > /etc/mailname
  # inet_interfaces=all: Der Builder laeuft im Docker-Netz (Bridge), loopback-only
  # wuerde ihn aussperren. Relay bleibt trotzdem lokal (mynetworks unten).
  postconf -e "myhostname = typebot.local" "inet_protocols = ipv4" \
    "mydestination = \$myhostname, localhost, typebot.local" \
    "mynetworks = 127.0.0.0/8 172.16.0.0/12" \
    "inet_interfaces = all"
  systemctl enable postfix
  systemctl restart postfix
  SMTP_HOST="host.docker.internal"
  SMTP_PORT="25"
  SMTP_IGNORE_TLS="true"
  [[ -z "\$SMTP_FROM" ]] && SMTP_FROM="Typebot <typebot@typebot.local>"
  echo "[LXC] Postfix-Status: \$(systemctl is-active postfix)"
fi
# E-Mail-Provider registriert Upstream NUR mit FROM – Default setzen, damit
# --smtp-host allein bereits genuegt (kein stiller No-Provider).
if [[ -n "\$SMTP_HOST" && -z "\$SMTP_FROM" ]]; then SMTP_FROM="Typebot <noreply@\$SMTP_HOST>"; fi
# URLs zeigen IMMER auf die aktuelle Container-IP (DHCP-Wechsel-safe)
NEXTAUTH_URL="http://\$LXC_IP:\$BUILDER_PORT"
NEXT_PUBLIC_VIEWER_URL="http://\$LXC_IP:\$VIEWER_PORT"
DATABASE_URL="postgresql://postgres:\$POSTGRES_PASSWORD@typebot-db:5432/typebot"
# Unquoted heredoc: Container-Vars expandieren hier (Werte werden NICHT
# re-expandiert, Sonderzeichen in Passwoertern sind also sicher).
cat > /opt/typebot/.env <<ENV_EOF
ENCRYPTION_SECRET=\$ENCRYPTION_SECRET
POSTGRES_PASSWORD=\$POSTGRES_PASSWORD
DATABASE_URL=\$DATABASE_URL
NEXTAUTH_URL=\$NEXTAUTH_URL
NEXT_PUBLIC_VIEWER_URL=\$NEXT_PUBLIC_VIEWER_URL
NODE_OPTIONS=--no-node-snapshot
ENV_EOF
# Optionale Werte NUR wenn nicht leer (leere Strings brechen min(1)-Checks).
maybe_env() { if [[ -n "\$2" ]]; then printf '%s=%s\n' "\$1" "\$2" >> /opt/typebot/.env; fi; }
maybe_env ADMIN_EMAIL "\$ADMIN_EMAIL"
maybe_env SMTP_HOST "\$SMTP_HOST"
maybe_env SMTP_PORT "\$SMTP_PORT"
maybe_env SMTP_USERNAME "\$SMTP_USER"
maybe_env SMTP_PASSWORD "\$SMTP_PASS"
maybe_env NEXT_PUBLIC_SMTP_FROM "\$SMTP_FROM"
maybe_env SMTP_SECURE "\$SMTP_SECURE"
maybe_env SMTP_IGNORE_TLS "\$SMTP_IGNORE_TLS"
maybe_env GITHUB_CLIENT_ID "\$GITHUB_ID"
maybe_env GITHUB_CLIENT_SECRET "\$GITHUB_SECRET"
maybe_env GOOGLE_AUTH_CLIENT_ID "\$GOOGLE_ID"
maybe_env GOOGLE_AUTH_CLIENT_SECRET "\$GOOGLE_SECRET"
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
    # Damit der Builder das Host-Postfix (lokaler Pfad) erreicht:
    extra_hosts:
      - "host.docker.internal:host-gateway"
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
    extra_hosts:
      - "host.docker.internal:host-gateway"
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

# HTTP-Probe: JEDE HTTP-Antwort (auch 404) zaehlt als "antwortet" – nur 000
# (keine TCP-Verbindung) ist ein Fehler. Grund: Der Viewer hat keine 200er-
# Root-Route ('/' -> 404), ist aber gesund; sein statisches /__ENV.js gibt 200.
wait_for_http() {
  local label="\$1" url="\$2"
  local i code
  for i in \$(seq 1 120); do
    code="\$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "\$url" 2>/dev/null || true)"
    [[ -z "\$code" ]] && code="000"
    if [[ "\$code" != "000" ]]; then
      echo "[LXC] \$label antwortet (HTTP \$code auf \$url)."
      return 0
    fi
    if [[ \$((i % 12)) -eq 0 ]]; then echo "[LXC] ... warte auf \$label (\$((i*2))s), docker ps:"; docker ps --format '{{.Names}} {{.Status}}' || true; fi
    sleep 2
  done
  echo "[LXC][ERROR] \$label antwortet nicht auf \$url (keine TCP/HTTP-Antwort)." >&2
  return 1
}

echo "[LXC] Warte auf Builder (http://127.0.0.1:\$BUILDER_PORT, max 240s) ..."
if ! wait_for_http "Builder" "http://127.0.0.1:\$BUILDER_PORT"; then
  echo "[LXC][ERROR] Builder-Diagnose:" >&2
  systemctl status typebot --no-pager --full >&2 || true
  journalctl -u typebot --no-pager -n 100 >&2 || true
  docker ps -a >&2 || true
  docker compose logs --tail=100 --no-color >&2 || true
  exit 1
fi

echo "[LXC] Warte auf Viewer (http://127.0.0.1:\$VIEWER_PORT/__ENV.js, max 240s) ..."
if ! wait_for_http "Viewer" "http://127.0.0.1:\$VIEWER_PORT/__ENV.js"; then
  echo "[LXC][ERROR] Viewer-Diagnose:" >&2
  docker compose logs --tail=100 --no-color >&2 || true
  exit 1
fi

# Automatischer Erstanmelde-Code: loest den E-Mail-Login (Auth.js-CSRF-Flow
# per curl) fuer LOGIN_EMAIL aus. Lokaler Pfad: fischt den 6-stelligen Code
# aus der lokalen Mailbox und druckt Code + Direkt-Link (10 Min gueltig).
rm -f /opt/typebot/.auto-login-ok
trigger_signin() {
  local mail="\$1" jar csrf code
  jar="\$(mktemp)"
  csrf="\$(curl -fsS --max-time 10 -c "\$jar" "http://127.0.0.1:\$BUILDER_PORT/api/auth/csrf" 2>/dev/null | grep -o '"csrfToken":"[^"]*"' | cut -d'"' -f4 || true)"
  code="000"
  if [[ -n "\$csrf" ]]; then
    code="\$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -b "\$jar" -c "\$jar" --data-urlencode "csrfToken=\$csrf" --data-urlencode "email=\$mail" --data-urlencode "callbackUrl=http://127.0.0.1:\$BUILDER_PORT/typebots" "http://127.0.0.1:\$BUILDER_PORT/api/auth/signin/nodemailer" 2>/dev/null || true)"
    [[ -z "\$code" ]] && code="000"
  fi
  rm -f "\$jar"
  printf '%s' "\$code"
}
if [[ "\$NO_AUTO_LOGIN" == "1" ]]; then
  echo "[LXC] Auto-Login deaktiviert (--no-auto-login)."
elif [[ "\$SMTP_HOST" == "host.docker.internal" ]]; then
  if [[ "\$LOGIN_DOMAIN" != "typebot.local" && "\$LOGIN_DOMAIN" != "localhost" ]]; then
    echo "[LXC][WARN] Auto-Login uebersprungen: \$LOGIN_EMAIL ist extern, aber nur lokales Postfix konfiguriert (nicht zustellbar)." >&2
    echo "[LXC][WARN] Entweder --login-email mit @typebot.local nutzen oder externes SMTP angeben." >&2
  elif [[ ! "\$LOGIN_LOCALPART" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "[LXC][WARN] Auto-Login uebersprungen: ungueltiger Mailbox-Name." >&2
  else
    id "\$LOGIN_LOCALPART" >/dev/null 2>&1 || useradd --no-create-home --shell /usr/sbin/nologin "\$LOGIN_LOCALPART"
    MAILBOX="/var/mail/\$LOGIN_LOCALPART"
    BEFORE_SIZE=0
    [[ -f "\$MAILBOX" ]] && BEFORE_SIZE="\$(stat -c%s "\$MAILBOX")"
    echo "[LXC] Fordere Login-Code fuer \$LOGIN_EMAIL an ..."
    SIGNIN_HTTP="\$(trigger_signin "\$LOGIN_EMAIL")"
    if [[ "\$SIGNIN_HTTP" != "302" && "\$SIGNIN_HTTP" != "200" ]]; then
      echo "[LXC][WARN] Login-Ausloeser fehlgeschlagen (HTTP \$SIGNIN_HTTP) – Anmeldung ggf. manuell im Builder." >&2
    else
      CODE=""
      for i in \$(seq 1 30); do
        if [[ -f "\$MAILBOX" ]]; then
          NEWMAIL="\$(tail -c +\$((BEFORE_SIZE+1)) "\$MAILBOX" 2>/dev/null || true)"
          FLAT="\$(printf '%s' "\$NEWMAIL" | sed -e ':a' -e 'N' -e '\$!ba' -e 's/=\r\{0,1\}\n//g' | sed 's/=3D/=/g')"
          CODE="\$(printf '%s' "\$FLAT" | grep -o 'signin/email-redirect?token=[0-9]\{6\}' | grep -o '[0-9]\{6\}$' | tail -n1 || true)"
          [[ -n "\$CODE" ]] && break
        fi
        sleep 2
      done
      if [[ -z "\$CODE" ]]; then
        echo "[LXC][WARN] Kein Login-Code in \$MAILBOX gefunden – Anmeldung ggf. manuell im Builder." >&2
      else
        LOGIN_URL="http://\$LXC_IP:\$BUILDER_PORT/api/auth/callback/nodemailer?token=\$CODE&email=\${LOGIN_EMAIL/@/%40}&callbackUrl=http://\$LXC_IP:\$BUILDER_PORT/typebots"
        echo ""
        echo "[LXC] ═══════ LOGIN (Code 10 Minuten gueltig) ═══════"
        echo "[LXC] E-Mail : \$LOGIN_EMAIL"
        echo "[LXC] Code   : \$CODE   (im Builder unter Sign-in eintippen)"
        echo "[LXC] Direkt : \$LOGIN_URL"
        echo "[LXC] ═══════════════════════════════════════════════"
        touch /opt/typebot/.auto-login-ok
      fi
    fi
  fi
else
  LOGIN_TARGET=""
  if [[ "\$LOGIN_EXPLICIT" == "1" ]]; then LOGIN_TARGET="\$LOGIN_EMAIL"
  elif [[ -n "\$ADMIN_EMAIL" ]]; then LOGIN_TARGET="\$ADMIN_EMAIL"
  fi
  if [[ -z "\$LOGIN_TARGET" ]]; then
    echo "[LXC] Externes SMTP konfiguriert – Anmeldung manuell im Builder (Magic-Code kommt per Mail)."
  else
    echo "[LXC] Fordere Login-Code fuer \$LOGIN_TARGET an ..."
    SIGNIN_HTTP="\$(trigger_signin "\$LOGIN_TARGET")"
    if [[ "\$SIGNIN_HTTP" != "302" && "\$SIGNIN_HTTP" != "200" ]]; then
      echo "[LXC][WARN] Login-Ausloeser fehlgeschlagen (HTTP \$SIGNIN_HTTP) – Anmeldung ggf. manuell im Builder." >&2
    else
      echo "[LXC] Magic-Code an \$LOGIN_TARGET unterwegs (10 Min gueltig, ggf. Spam-Ordner)."
    fi
  fi
fi
echo "[LXC] Service aktiv: \$(systemctl is-active typebot)"
echo "[LXC] Container: \$(docker ps --format '{{.Names}} {{.Status}}' | tr '\\n' '; ')"
# Typebot verlangt mind. einen Auth-Provider, sonst Hinweis im Builder.
# (Prueft auch GitLab/Facebook/Azure/Keycloak/Custom aus manueller .env.)
if [[ -z "\${SMTP_HOST:-}" && -z "\${GITHUB_CLIENT_ID:-}" && -z "\${GOOGLE_AUTH_CLIENT_ID:-}" && -z "\${GITLAB_CLIENT_ID:-}" && -z "\${FACEBOOK_CLIENT_ID:-}" && -z "\${AZURE_AD_CLIENT_ID:-}" && -z "\${KEYCLOAK_CLIENT_ID:-}" && -z "\${CUSTOM_OAUTH_CLIENT_ID:-}" ]]; then
  echo "[LXC][WARN] Kein Auth-Provider konfiguriert – Builder meldet: 'mindestens einen Authentifizierungsanbieter konfigurieren'." >&2
  echo "[LXC][WARN] Nachtragen (idempotent, Container bleibt): Installer auf dem HOST erneut laufen lassen, z. B.:" >&2
  echo "[LXC][WARN]   bash typebot.sh --ctid <ID> --admin-email ich@domain.tld --smtp-host smtp.domain.tld --smtp-port 587 --smtp-user ich@domain.tld --smtp-pass '...' --smtp-from 'Typebot <noreply@domain.tld>'" >&2
  echo "[LXC][WARN] oder ohne Zugangsdaten:  bash typebot.sh --ctid <ID> --smtp-local   (lokales Postfix, Zustellung ab Heimnetz evtl. spam-gefiltert)" >&2
else
  echo "[LXC] Auth-Provider konfiguriert."
fi
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

# HTTP-Code statt -f: JEDE Antwort (auch Viewer-404 auf '/') zaehlt als "lebt".
BUILDER_CODE="$(pct exec "$CTID" -- curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:${BUILDER_PORT}" 2>/dev/null || true)"
[[ -z "$BUILDER_CODE" ]] && BUILDER_CODE="000"
if [[ "$BUILDER_CODE" == "000" ]]; then
  msg_error "HTTP-Check fehlgeschlagen: Builder http://127.0.0.1:${BUILDER_PORT} antwortet nicht (keine Verbindung)."
  pct exec "$CTID" -- docker compose -f /opt/typebot/docker-compose.yml logs --tail=100 --no-color || true
  exit 1
fi
msg_ok "Builder antwortet (HTTP $BUILDER_CODE auf localhost:${BUILDER_PORT})."

VIEWER_CODE="$(pct exec "$CTID" -- curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:${VIEWER_PORT}/__ENV.js" 2>/dev/null || true)"
[[ -z "$VIEWER_CODE" ]] && VIEWER_CODE="000"
if [[ "$VIEWER_CODE" == "000" ]]; then
  msg_error "HTTP-Check fehlgeschlagen: Viewer http://127.0.0.1:${VIEWER_PORT}/__ENV.js antwortet nicht (keine Verbindung)."
  pct exec "$CTID" -- docker compose -f /opt/typebot/docker-compose.yml logs --tail=100 --no-color || true
  exit 1
fi
msg_ok "Viewer antwortet (HTTP $VIEWER_CODE auf localhost:${VIEWER_PORT}/__ENV.js)."

AUTH_DESC="keiner – Builder zeigt Auth-Hinweis (Nachtrag: README Kap. Auth)"
if pct exec "$CTID" -- grep -Eq '^(SMTP_HOST|GITHUB_CLIENT_ID|GOOGLE_AUTH_CLIENT_ID|GITLAB_CLIENT_ID|FACEBOOK_CLIENT_ID|AZURE_AD_CLIENT_ID|KEYCLOAK_CLIENT_ID|CUSTOM_OAUTH_CLIENT_ID)=.+' /opt/typebot/.env 2>/dev/null; then
  AUTH_DESC="konfiguriert (E-Mail und/oder OAuth – Details im Container: grep -E 'HOST|CLIENT_ID' /opt/typebot/.env)"
fi

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
echo -e "  Auth-Provider: ${AUTH_DESC}"
if pct exec "$CTID" -- test -f /opt/typebot/.auto-login-ok 2>/dev/null; then
echo -e "  Login        : Code + Direkt-Link stehen oben ([LXC] LOGIN, 10 Min gültig)"
else
echo -e "  Login        : im Builder anmelden (E-Mail-Code per Mail, siehe README Kap. 8)"
fi
if [[ "$CREATED_NOW" == "1" && "$GENERATED_PW" == "1" ]]; then
echo -e "  Root-Passwort: ${C_BOLD}${ROOT_PASSWORD}${C_RESET} (nur jetzt angezeigt – sicher ablegen!)"
fi
echo -e "  Service      : systemctl status ${APP}  (im Container via: pct enter ${CTID})"
echo -e "  Stack        : cd /opt/typebot && docker compose ps / docker compose logs -f (im Container)"
echo -e "  Update       : Skript erneut laufen lassen (idempotent, zieht neueste Images + restart)"
echo -e "  Deinstall    : pct stop ${CTID} && pct destroy ${CTID}"
echo -e "  Reboot-Test  : pct reboot ${CTID} && sleep 60 && curl -fs http://${CT_IP:-<LXC-IP>}:${BUILDER_PORT} >/dev/null && curl -fs http://${CT_IP:-<LXC-IP>}:${VIEWER_PORT}/__ENV.js >/dev/null"
echo -e "  Log          : ${LOG_FILE}"
echo -e "  Setup-Kopie  : ${TMP_SETUP}"
if [[ "$DEBUG" != "1" ]]; then
echo -e "  Debug bei Fehlern: ${C_CYAN}bash -x typebot.sh --ctid ${CTID}${C_RESET}"
fi
echo -e "${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
