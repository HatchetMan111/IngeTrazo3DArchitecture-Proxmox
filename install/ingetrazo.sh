#!/usr/bin/env bash
#
# IngeTrazo Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      IngeTrazo – freier 3D-Modeler (PySide6/Qt6, Desktop) im Browser
# Upstream: https://github.com/ingelibre/ingetrazo
# Installer: https://github.com/HatchetMan111/IngeTrazo3DArchitecture-Proxmox
# Zugang:   XFCE + TigerVNC (:1/5901, nur localhost) + noVNC/websockify (:6080)
#           Browser: http://<LXC-IP>:6080 – kein Cloud-Dienst, alles lokal
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/IngeTrazo3DArchitecture-Proxmox/main/install/ingetrazo.sh)"
#   CT_ID=150 CORES=2 RAM=4096 DISK=10 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/IngeTrazo3DArchitecture-Proxmox/main/install/ingetrazo.sh)"
#   bash ingetrazo.sh --ctid 150 --cores 2 --memory 4096 --disk 10 --bridge vmbr0 --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="ingetrazo"
APP_PORT="6080"
UPSTREAM_REPO="https://github.com/ingelibre/ingetrazo"
INSTALLER_REPO="https://github.com/HatchetMan111/IngeTrazo3DArchitecture-Proxmox"
VNC_SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/IngeTrazo3DArchitecture-Proxmox/main/systemd/ingetrazo-vnc.service"
NOVNC_SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/IngeTrazo3DArchitecture-Proxmox/main/systemd/ingetrazo-novnc.service"

DEFAULT_CORES="2"
DEFAULT_RAM="4096"
DEFAULT_SWAP="512"
DEFAULT_DISK="10"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"
DEFAULT_OS="debian-12-standard"
UNPRIVILEGED="1"
FEATURES="nesting=1"

APP_USER="ingetrazo"
APP_DIR="/opt/ingetrazo"
VENV_DIR="/opt/ingetrazo/.venv"

CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

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

exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer (XFCE + VNC + noVNC, IngeTrazo aus Git-main)

Usage:
  bash ingetrazo.sh [OPTIONEN]
  CT_ID=150 bash ingetrazo.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO}/raw/main/install/ingetrazo.sh)"

Optionen:
  --ctid ID            Container-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufaellig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container uebernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Naechste freie CT-ID: $CT_ID"
fi

if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Pruefe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfuegbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell pruefen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – ueberspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge pruefen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. IngeTrazo + Desktop + VNC/noVNC im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere Desktop + IngeTrazo im Container (nativ, ohne Docker) ..."
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl ca-certificates python3 python3-venv python3-pip libgl1 libegl1 libxkbcommon0 libdbus-1-3 libfontconfig1 mesa-utils xfce4 xfce4-terminal dbus-x11 tigervnc-standalone-server tigervnc-common novnc websockify
  id ingetrazo >/dev/null 2>&1 || useradd -m -s /bin/bash ingetrazo
  if [ ! -d /opt/ingetrazo/.git ]; then
    rm -rf /opt/ingetrazo
    mkdir -p /opt/ingetrazo
    chown ingetrazo:ingetrazo /opt/ingetrazo
    su -s /bin/bash ingetrazo -c "git clone --depth 1 https://github.com/ingelibre/ingetrazo /opt/ingetrazo"
  else
    su -s /bin/bash ingetrazo -c "git -C /opt/ingetrazo pull --ff-only"
  fi
  test -f /opt/ingetrazo/main.py
  test -f /opt/ingetrazo/requirements.txt
  if [ ! -x /opt/ingetrazo/.venv/bin/python ]; then
    python3 -m venv /opt/ingetrazo/.venv
  fi
  /opt/ingetrazo/.venv/bin/pip install --upgrade pip
  /opt/ingetrazo/.venv/bin/pip install -r /opt/ingetrazo/requirements.txt
  mkdir -p /home/ingetrazo/.vnc /home/ingetrazo/.config/autostart
  chown -R ingetrazo:ingetrazo /opt/ingetrazo /home/ingetrazo
  # VNC braucht eine Passwort-Datei, sonst fragt vncserver interaktiv
  # (getpassword error: Inappropriate ioctl) und der Service stirbt.
  # Darum hier nicht-interaktiv erzeugen (TigerVNC nutzt die ersten 8 Zeichen).
  VNC_PASS="$(openssl rand -base64 18 | tr -dc A-Za-z0-9 | head -c 12)"
  su -s /bin/bash ingetrazo -c "echo \"$VNC_PASS\" | vncpasswd -f > /home/ingetrazo/.vnc/passwd"
  chmod 600 /home/ingetrazo/.vnc/passwd
  chown ingetrazo:ingetrazo /home/ingetrazo/.vnc/passwd
  printf "%s" "$VNC_PASS" > /root/.ingetrazo-vnc-pass
  chmod 600 /root/.ingetrazo-vnc-pass
'

VNC_PASS="$(pct exec "$CT_ID" -- cat /root/.ingetrazo-vnc-pass 2>/dev/null || true)"
[[ -n "${VNC_PASS:-}" ]] || { msg_error "VNC-Passwort-Datei /root/.ingetrazo-vnc-pass fehlt im Container."; exit 1; }
msg_ok "VNC-Passwort erzeugt (wird unten einmalig angezeigt)."

pct exec "$CT_ID" -- test -f /opt/ingetrazo/main.py \
  || { msg_error "Checkout unvollstaendig: /opt/ingetrazo/main.py fehlt im Container."; exit 1; }
msg_ok "Checkout ok (main.py vorhanden)."

# VNC xstartup (XFCE) – ASCII-sicher, keine Umlaute
pct push "$CT_ID" /dev/stdin /home/ingetrazo/.vnc/xstartup <<XSTARTUP
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
xrdb \$HOME/.Xresources 2>/dev/null || true
startxfce4 &
XSTARTUP
pct exec "$CT_ID" -- chmod +x /home/ingetrazo/.vnc/xstartup
pct exec "$CT_ID" -- chown ingetrazo:ingetrazo /home/ingetrazo/.vnc/xstartup

# Autostart IngeTrazo im Desktop (optional, startet mit der Session)
pct push "$CT_ID" /dev/stdin /home/ingetrazo/.config/autostart/ingetrazo.desktop <<AUTOSTART
[Desktop Entry]
Type=Application
Name=IngeTrazo
Exec=/opt/ingetrazo/.venv/bin/python /opt/ingetrazo/main.py
Terminal=false
X-GNOME-Autostart-enabled=true
AUTOSTART
pct exec "$CT_ID" -- chown ingetrazo:ingetrazo /home/ingetrazo/.config/autostart/ingetrazo.desktop

# systemd-Units aus diesem Repo uebernehmen (faellt auf Inline-Unit zurueck)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/ingetrazo-vnc.service "$VNC_SERVICE_URL" 2>/dev/null; then
  msg_ok "ingetrazo-vnc.service aus Repo uebernommen."
else
  msg_warn "VNC Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/ingetrazo-vnc.service <<UNITVNC
[Unit]
Description=IngeTrazo VNC Server (:1, localhost only)
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
User=ingetrazo
Group=ingetrazo
Environment=HOME=/home/ingetrazo
ExecStartPre=/bin/mkdir -p /home/ingetrazo/.vnc
ExecStart=/usr/bin/vncserver :1 -localhost yes -geometry 1600x900 -depth 24
ExecStop=/usr/bin/vncserver -kill :1
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNITVNC
fi
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/ingetrazo-novnc.service "$NOVNC_SERVICE_URL" 2>/dev/null; then
  msg_ok "ingetrazo-novnc.service aus Repo uebernommen."
else
  msg_warn "noVNC Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/ingetrazo-novnc.service <<UNITNOVNC
[Unit]
Description=IngeTrazo noVNC Web Access (6080 -> VNC 5901)
After=network-online.target ingetrazo-vnc.service
Wants=network-online.target
Requires=ingetrazo-vnc.service
[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/bin/websockify --web /usr/share/novnc 0.0.0.0:6080 localhost:5901
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNITNOVNC
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable ingetrazo-vnc ingetrazo-novnc
# restart statt start: Re-Runs (Update-Modus, neues VNC-Passwort) aktivieren so sicher
pct exec "$CT_ID" -- systemctl restart ingetrazo-vnc
pct exec "$CT_ID" -- systemctl restart ingetrazo-novnc
msg_ok "VNC (:5901 localhost) + noVNC (:6080) aktiv."

# ---------------------------------------------------------------------------
# 5. Verifikation: Services + Web Desktop + App-Smoke
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active ingetrazo-vnc || { msg_error "systemd-Service ingetrazo-vnc ist nicht active."; pct exec "$CT_ID" -- systemctl status ingetrazo-vnc --no-pager || true; exit 1; }
pct exec "$CT_ID" -- systemctl is-active ingetrazo-novnc || { msg_error "systemd-Service ingetrazo-novnc ist nicht active."; pct exec "$CT_ID" -- systemctl status ingetrazo-novnc --no-pager || true; exit 1; }
msg_ok "Services laufen (ingetrazo-vnc + ingetrazo-novnc = active)."

msg_info "Warte auf Web Desktop (max. 3 Min) ..."
WEB_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${APP_PORT}/" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web Desktop antwortet nicht auf localhost:${APP_PORT}/."; pct exec "$CT_ID" -- systemctl status ingetrazo-novnc --no-pager || true; pct exec "$CT_ID" -- journalctl -u ingetrazo-novnc --no-pager -n 100 || true; exit 1; }
msg_ok "Web Desktop antwortet (HTTP 200 auf localhost:${APP_PORT}/)."

pct exec "$CT_ID" -- test -x /opt/ingetrazo/.venv/bin/python \
  || { msg_error "venv-Python fehlt: /opt/ingetrazo/.venv/bin/python."; exit 1; }
pct exec "$CT_ID" -- /opt/ingetrazo/.venv/bin/python /opt/ingetrazo/main.py --check >/dev/null 2>&1 \
  || pct exec "$CT_ID" -- /opt/ingetrazo/.venv/bin/python /opt/ingetrazo/main.py --help >/dev/null 2>&1 \
  || { msg_error "App-Smoke scheiterte (main.py --check/--help)."; pct exec "$CT_ID" -- /opt/ingetrazo/.venv/bin/python /opt/ingetrazo/main.py --help || true; exit 1; }
msg_ok "App-Smoke ok (main.py --check/--help)."

echo ""
echo "================ INSTALLATION ERFOLGREICH ================"
echo "  App          : IngeTrazo – 3D-Modeler im Browser-Desktop"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web Desktop  : http://${CT_IP}:${APP_PORT}  (VNC-Passwort im Browser eingeben)"
echo "  VNC          : ${CT_IP}:5901 (nur via SSH-Tunnel, VNC bindet localhost)"
echo "  VNC-Passwort : ${VNC_PASS} (nur jetzt angezeigt!)"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unveraendert>} (nur jetzt angezeigt!)"
echo "  Services     : systemctl status ingetrazo-vnc ingetrazo-novnc  (im Container via: pct enter $CT_ID)"
echo "  Update       : Skript erneut laufen lassen (idempotent, git pull + pip upgrade)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/"
echo "  Log          : $LOG_FILE"
echo "=========================================================="
