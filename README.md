# Typebot auf Proxmox LXC – Einzeiler-Installation

> **Hinweis: Das ist NICHT das Typebot-App-Repository.**
> Dieses Repo enthält **nur den Proxmox-LXC-Installer** für Typebot — keinen App-Code.
> Die eigentliche Anwendung liegt bei Upstream:
> `https://github.com/baptisteArno/typebot.io`. Das Install-Script nutzt deren
> offizielle Docker-Images (`baptistearno/typebot-builder`, `baptistearno/typebot-viewer`)
> plus `postgres:16` und `redis:alpine` — alles läuft vollständig lokal.

Typebot (Fair-Source Chatbot-Builder, 34+ Bausteine, Next.js) läuft in einem
unprivilegierten LXC-Container mit Docker Compose: Builder auf Port **8080**,
Viewer auf Port **8081**, systemd-Service mit `Restart=always`, Container mit `onboot=1`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `typebot` |
| Zweck | Visueller Chatbot-Builder (Formulare, Logik, Integrationen, Embed) |
| Tech-Stack | Node.js/Next.js (Docker) + PostgreSQL 16 + Redis |
| Upstream-Repo | `https://github.com/baptisteArno/typebot.io` |
| Web UI | `http://<LXC-IP>:8080` (Builder) + `http://<LXC-IP>:8081` (Viewer), bind `0.0.0.0` via Docker-Ports |
| Standard-Ressourcen | 2 vCPU / 4096 MB RAM / 20 GB Disk (Minimum — 4 Docker-Dienste, mit 2 GB OOM) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | `nesting=1,keyctl=1` (Docker-Voraussetzung), unprivilegiert |

## 1. Installation (Einzeiler, auf dem Proxmox-Host als root)

Einfach kopieren und auf dem Proxmox-Host als `root` einfügen
(Community-Scripts-Stil, keine weitere Datei nötig):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TypeBotBuilder/main/install/typebot.sh)"
```

Anpassungen wahlweise per Umgebungsvariable oder Flag:

```bash
CT_ID=101 CORES=4 RAM=8192 DISK=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TypeBotBuilder/main/install/typebot.sh)"
bash typebot.sh --ctid 101 --cores 2 --memory 4096 --disk 20 --bridge vmbr0 --storage local-lvm
bash typebot.sh --debug   # = bash -x, maximale Fehlermeldungskette
```

Das Skript (`set -euo pipefail`, idempotent):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `typebot` (`onboot: 1`, unprivilegiert, `nesting=1,keyctl=1`),
3. installiert im Container Docker + Compose-Plugin, legt `/opt/typebot/`
   (`docker-compose.yml` + `.env` mit zufälligem `ENCRYPTION_SECRET` /
   `POSTGRES_PASSWORD`) an, schreibt die systemd-Unit, `systemctl enable --now typebot`,
4. verifiziert `systemctl is-active typebot` + HTTP auf `127.0.0.1:8080` und
   `127.0.0.1:8081/__ENV.js` und gibt beide finalen URLs + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active typebot = active).
[OK]    Builder antwortet (HTTP 200 auf localhost:8080).
[OK]    Viewer antwortet (HTTP 200 auf localhost:8081/__ENV.js).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Typebot – Open-Source Chatbot-Builder
  Container    : CT 100 (Hostname: typebot, onboot=1)
  Ressourcen   : 2 vCPU / 4096 MB RAM / 20 GB Disk
  Builder      : http://192.168.1.100:8080
  Viewer       : http://192.168.1.100:8081
  Root-Passwort: aB3... (nur jetzt angezeigt – sicher ablegen!)
  Service      : systemctl status typebot  (im Container via: pct enter 100)
  Stack        : cd /opt/typebot && docker compose ps / docker compose logs -f (im Container)
  Update       : Skript erneut laufen lassen (idempotent, zieht neueste Images + restart)
  Deinstall    : pct stop 100 && pct destroy 100
  Reboot-Test  : pct reboot 100 && sleep 60 && curl -fs http://192.168.1.100:8080 >/dev/null && curl -fs http://192.168.1.100:8081/__ENV.js >/dev/null
  Log          : /tmp/typebot-install-2026-....log
══════════════════════════════════════════════════════════
```

## 2. Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60   # Erster Start nach Reboot: Docker + 4 Dienste brauchen ~30–60 s
pct exec $CT -- systemctl is-active typebot   # muss: active
pct exec $CT -- docker ps --format '{{.Names}} {{.Status}}'
curl -fs http://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1):8080 >/dev/null && echo BUILDER-OK
# Viewer: KEIN curl auf '/' (gibt by design 404) – stattdessen /__ENV.js:
curl -fs http://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1):8081/__ENV.js >/dev/null && echo VIEWER-OK
pct config $CT | grep -i onboot              # muss: onboot: 1
```

## 3. Update (idempotent – einfach erneut laufen lassen)

```bash
bash typebot.sh --ctid 100
# zieht neueste Images (builder/viewer/postgres/redis), schreibt Compose/.env
# (Secrets bleiben erhalten, URLs werden auf aktuelle IP aktualisiert),
# danach `systemctl restart typebot`.
```

Manuell im Container:

```bash
pct enter 100
cd /opt/typebot && docker compose pull && docker compose up -d
systemctl restart typebot && systemctl status typebot --no-pager --full
curl -fs http://127.0.0.1:8080 >/dev/null && echo BUILDER-OK
curl -fs http://127.0.0.1:8081/__ENV.js >/dev/null && echo VIEWER-OK   # '/' gibt 404 by design
```

## 4. Deinstallation

```bash
pct stop 100 && pct destroy 100
```

## 5. Debugging (komplette Fehlermeldungskette)

- Jeder Lauf loggt **stdout+stderr vollständig** nach `/tmp/typebot-install-<Datum>.log`.
- Bei Fehlern druckt das Skript: Befehl, Zeile, Exit-Code, Stacktrace
  (`caller`), `pct config`/`pct status`, `journalctl -u typebot -n 100`,
  `systemctl status typebot`, `docker ps -a`, `docker compose logs --tail=100` —
  niemals nur die letzte Zeile.
- Re-run mit Trace:

```bash
bash -x typebot.sh --ctid 100
DEBUG=1 bash typebot.sh --ctid 100
# Log mitschicken:
tail -n 200 /tmp/typebot-install-*.log
pct exec 100 -- journalctl -u typebot --no-pager -n 100
pct exec 100 -- docker compose -f /opt/typebot/docker-compose.yml logs --tail=100 --no-color
```

## 6. Dateien in diesem Paket

```text
TypeBotBuilder/               # dieses Repo: NUR Proxmox-Installer, kein App-Code
├── install/typebot.sh         # Proxmox-Install-Script (Community-Scripts-konform, Variablen oben)
├── systemd/typebot.service    # systemd-Unit (Restart=always, After=network-online.target + docker.service)
└── README.md                  # diese Datei
```

`install/typebot.sh` bettet die Unit-Vorlage aus `systemd/typebot.service` ein,
damit der Einzeiler ohne weitere Dateien auskommt. Der Compose-Stack
(`postgres:16`, `redis:alpine`, `typebot-builder`, `typebot-viewer`) wird im
Container unter `/opt/typebot/` erzeugt.

## 7. Hinweise

- **Warum Docker statt nativem Build?** Upstream baut mit `bun` + `nx`-Monorepo —
  nativ im LXC wären das mehrere GB Build-Deps und 10+ Minuten Bauzeit. Die
  offiziellen Images sind der dokumentierte Self-Host-Weg
  (`docs.typebot.io/self-hosting`) und machen den Installer idempotent und schnell.
- **Warum 4 GB / 20 GB?** Builder + Viewer (je ein Next.js-Server) + Postgres +
  Redis brauchen real ~2,5–3,5 GB RAM und ~6–8 GB Images. Mit 2 GB/8 GB droht OOM
  bzw. volle Disk — darum warnt das Skript bei kleineren Werten.
- **LXC statt VM:** Mit `nesting=1,keyctl=1` läuft Docker stabil im unprivilegierten
  LXC — keine VM nötig (kein Kernel-/GPU-Bedarf). Nur wenn der Host kein nesting
  erlaubt oder dedizierte Kernel-Features nötig sind, auf VM wechseln.
- **DHCP-Hinweis:** Ändert sich die Container-IP, Installer erneut laufen lassen —
  er erkennt die neue IP und schreibt `NEXTAUTH_URL`/`NEXT_PUBLIC_VIEWER_URL`
  in `/opt/typebot/.env` neu (Secrets bleiben). Für stabile URLs DHCP-Reservierung
  oder statische IP einrichten.
- **Viewer-Health-Check:** `http://<LXC-IP>:8081/` gibt **by design 404**
  (der Viewer kennt nur Bot-Routen) — das ist kein Fehler. Health-Probe ist
  `http://<LXC-IP>:8081/__ENV.js` (statische Datei, 200). Im Browser ist der
  Viewer über konkrete Bot-URLs erreichbar, der Builder über `/` auf `:8080`.
- Erster Start zieht ~2–3 GB Images — Web UI kann 2–4 Minuten brauchen
  (beide Ports werden bis zu 240 s gepollt).
