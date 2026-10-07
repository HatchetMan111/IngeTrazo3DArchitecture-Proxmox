# IngeTrazo auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Repos): `https://github.com/ingelibre/ingetrazo`
> (freier 3D-Modeler, PySide6/Qt6 Desktop, `main.py`)
> Dieses Repo enthält **nur den Proxmox-Installer**: Install-Script + systemd-Units.
> Die App läuft nativ (Git-Clone + venv, ohne Docker) – vollständig lokal, keine Cloud nötig.
> Zugriff via Browser-Desktop (XFCE + TigerVNC + noVNC), da IngeTrazo eine Desktop-App ist.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/IngeTrazo3DArchitecture-Proxmox/main/install/ingetrazo.sh)"
```

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=4096 DISK=10 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/IngeTrazo3DArchitecture-Proxmox/main/install/ingetrazo.sh)"
bash ingetrazo.sh --ctid 150 --cores 2 --memory 4096 --disk 10 --bridge vmbr0 --storage local-lvm
bash ingetrazo.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/ingetrazo-install-*.log
```

> Die systemd-Units liegen unter `systemd/ingetrazo-vnc.service` und
> `systemd/ingetrazo-novnc.service` desselben Repos und werden
> vom Installer von dort geladen (Fallback: Inline-Unit im Script).

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `ingetrazo` |
| Zweck | Freier 3D-Modeler (Architektur/Ingenieurwesen) als Browser-Desktop im LXC |
| Tech-Stack | Python/PySide6 + venv `/opt/ingetrazo/.venv`, XFCE, TigerVNC `:1/5901` (localhost), noVNC/websockify `:6080` |
| GitHub-Repo (Upstream) | `https://github.com/ingelibre/ingetrazo` (Quelle: Git-Clone `main`) |
| Web-Zugang | `http://<LXC-IP>:6080` (noVNC), VNC ` <IP>:5901` (nur localhost/SSH-Tunnel) |
| Standard-Ressourcen | 2 vCPU / 4096 MB RAM / 512 MB Swap / 10 GB Disk |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `ingetrazo` (`onboot: 1`, unprivilegiert),
3. installiert im Container Desktop + VNC/noVNC + Python/venv/git + Qt/GL-Libs,
   klont/pullt `ingelibre/ingetrazo` nach `/opt/ingetrazo`, installiert
   `requirements.txt`, legt User `ingetrazo` + VNC-xstartup + Autostart an,
   schreibt beide systemd-Units, `systemctl enable --now`,
4. verifiziert `systemctl is-active ingetrazo-vnc ingetrazo-novnc` + HTTP auf
   `localhost:6080/` + App-Smoke (`main.py --check/--help`)
   und gibt die finale URL + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Services laufen (ingetrazo-vnc + ingetrazo-novnc = active).
[OK]    Web Desktop antwortet (HTTP 200 auf localhost:6080/).

================ INSTALLATION ERFOLGREICH ================
  App          : IngeTrazo – 3D-Modeler im Browser-Desktop
  Container    : CT 100 (Hostname: ingetrazo, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 4096 MB RAM / 10 GB Disk
  Web Desktop  : http://192.168.1.100:6080
  VNC          : 192.168.1.100:5901 (nur via SSH-Tunnel, VNC bindet localhost)
  ...
  Log          : /tmp/ingetrazo-install-2026-....log
==========================================================
```

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active ingetrazo-vnc ingetrazo-novnc
curl -fs http://<LXC-IP>:6080/ >/dev/null && echo WEB_DESKTOP_OK
```

## Update / Deinstall

```bash
bash ingetrazo.sh --ctid 100            # Update: idempotent (git pull + pip upgrade + restart)
pct stop 100 && pct destroy 100     # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/ingetrazo-install-*.log`.
- `bash ingetrazo.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status ingetrazo-vnc ingetrazo-novnc --no-pager`, `journalctl -u ingetrazo-novnc -n 100`.

## Dateien

- `install/ingetrazo.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/ingetrazo-vnc.service` – VNC `:1` (localhost, `After=network-online.target`, `Restart=always`).
- `systemd/ingetrazo-novnc.service` – websockify `:6080 -> 5901` (`Requires=ingetrazo-vnc`, `Restart=always`).
