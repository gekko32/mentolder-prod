# Runbook: mentolder-Prod auf frischem Cluster neu aufbauen

Ausführender: Claude Code auf Windows (Desktop-App oder CLI), bedient vom
Operator (Gekko). Ergebnis:

1. WSL-Instanz `gekko-ops` mit Benutzer `gekko` (sudo ohne Passwort), Schlüssel
   `gekko_ed25519` und SSH-Konfiguration für alle Knoten.
2. mentolder-prod ist eigenständig: Basen vendored, Images unter
   `ghcr.io/gekko32/*`, Secrets per SOPS/age, kein Bezug mehr auf
   `Paddione/Bachelorprojekt` im Deploy-Pfad.
3. `gekko-hetzner-2/3/4` laufen als frischer k3s-HA-Cluster mit aktuellen
   Versionen. Die Daten wurden aus dem Altcluster übernommen.
4. Optionale Dienste (heute `replicas: 0`) sind mit Ressourcenschätzung angeboten.
5. Alle Klartext-Werte liegen in Gekkos Vaultwarden, im Repo nur verschlüsselt.
6. Bachelorprojekt ist von mentolder-Deploy-Anteilen bereinigt.
7. Die Ops-Instanz ist auf Gekkos Laptop übertragen, falls der Runbook woanders lief (Phase 10).

Stand der Ist-Aufnahme: 2026-10-20 (siehe [Anhang A](#anhang-a-ist-aufnahme-2026-10-20)).

---

## Regeln für den ausführenden Agenten

- **Gates sind Pflicht.** Jeder Schritt mit `GATE` endet mit einer Rückfrage an den
  Operator. Ohne ausdrückliches „weiter“ nicht fortfahren.
- **Phase 5 ist destruktiv.** Sie löscht die Produktion. Vor Phase 5 müssen die
  Backups aus Phase 4 lokal vorliegen **und** eine Restore-Probe erfolgreich sein.
- **Keine Secret-Werte ausgeben.** Weder im Chat noch in Logs, Commits, PR-Texten
  oder Dateinamen. Nur Schlüsselnamen, Anzahlen und SHA-256-Präfixe (8 Zeichen).
- **Klartext nur in tmpfs.** Arbeitsverzeichnis für Klartext ist
  `$PLAIN=/run/user/$(id -u)/mentolder-plain` (RAM, verschwindet beim WSL-Stopp).
  Persistent nur age-verschlüsselt.
  WSL stoppt eine Instanz ohne offene Prozesse nach kurzer Zeit, dabei geht
  tmpfs verloren. Deshalb ab Phase 0.9 einen Keepalive offen halten
  (`Start-Process -WindowStyle Hidden wsl.exe -ArgumentList '-d','gekko-ops','--','sleep','infinity'`)
  und die Handover-Datei bis Phase 8 zusätzlich age-verschlüsselt ablegen
  (`age -p -o ~/mentolder-ops/handover.json.age "$PLAIN/handover.json"`).
- **Variablen überleben keinen Aufruf.** Jeder `wsl.exe … bash -l -s`-Aufruf ist
  eine neue Shell. `$PLAIN`, `$B`, `$R`, `KUBECONFIG` und die Zugänge aus 2.0
  kommen deshalb aus `~/mentolder-ops/env.sh` (angelegt in 0.9, über
  `~/.profile` in jeder Login-Shell geladen). Werte, die später gebraucht
  werden, dort bzw. in den Zeigerdateien daneben ablegen, nicht nur exportieren.
- **Eingaben mit Passphrase oder Token** (`age -p`, `age -d` einer `.json.age`,
  GHCR-Token in 6.1, `bw login`/`bw unlock` in 8.1) brauchen ein Terminal. Über
  `wsl.exe … bash -s` gibt es keins. Diese Blöcke führt der Operator selbst in
  einem eigenen Fenster aus (`wsl -d gekko-ops`), der Agent nennt den Befehl und
  wartet. Ergebnisse landen in `$PLAIN` bzw. `~/mentolder-ops` und sind danach
  für alle Aufrufe da.
- **Linux-Befehle** laufen in der WSL-Instanz. Von der Windows-Seite aus:

  ```bash
  wsl.exe -d gekko-ops -u gekko --cd ~ -- bash -l -s <<'EOF'
  # Befehle
  EOF
  ```

  Alternative ab Phase 1: Claude Code in `gekko-ops` installieren
  (`npm i -g @anthropic-ai/claude-code`) und dort mit diesem Runbook fortfahren.
- **Fortschritt protokollieren** in `~/mentolder-ops/LOG.md` (Phase, Schritt,
  Ergebnis, Zeit). Bei Abbruch dort wieder aufsetzen.
- **Repo-Änderungen** an `gekko32/mentolder-prod` nur per PR. CODEOWNERS
  verlangt Review durch `@gekko32`.

---

## Eingaben

Vor Phase 1 vom Operator erfragen und in `~/mentolder-ops/inputs.env` ablegen
(Datei `chmod 600`, Werte mit `SECRET` gehören nach `$PLAIN/inputs.secret.env`).

| ID | Name | Beispiel / Hinweis | Geheim |
|---|---|---|---|
| I0 | Handover-Datei | `mentolder-handover-<datum>.json` aus `scripts/handover-export.sh` oder die per `age -p` verschlüsselte Fassung `….json.age` (beide gehen, siehe [Phase 2.0](#20-handover-datei)). Enthält alle Secrets und I1, I2 und I5 | ja |
| I1 | `HCLOUD_TOKEN` | Hetzner-Cloud-Projekt der gekko-Server, Read/Write. Nur für `NODE_RESET=rebuild` (siehe I8) | ja |
| I2 | `TS_AUTHKEY`, `TS_API_KEY` | Tailnet `gekko32@github`. Auth-Key: reusable, **nicht** ephemeral, Tag `tag:fleet` (siehe 5.1) | ja |
| I3 | `VW_URL`, `VW_EMAIL` | Vaultwarden ist Teil des Deployments und am Anfang nicht verfügbar. Erst in Phase 8 nötig, siehe 7.5 | URL nein |
| I4 | GitHub-Login `gekko32` | `gh auth login` mit Scopes `repo`, `workflow`, `write:packages`, `read:org` | ja |
| I5 | NUC | Tailnet-IP `100.87.136.73` (Tailnet `gekko32@github`, Proxmox-Host, Kernel `6.8.12-12-pve`), Admin-User für die einmalige Einrichtung von `gekko` | nein |
| I6 | `NUC_ROLE` | `backup` (empfohlen) oder `agent` (siehe Phase 5.6) | nein |
| I7 | `OS_IMAGE` | `ubuntu-26.04` (Standard, falls bei Hetzner gelistet), sonst `ubuntu-24.04` | nein |
| I8 | `NODE_RESET` | `rebuild` (Standard, braucht I1) oder `wipe` (nur über die bestehende SSH-Verbindung, kein Hetzner-Zugang nötig, siehe 5.2) | nein |
| I9 | Wartungsfenster | Datum/Uhrzeit, geschätzt 3 h | nein |
| I10 | Filen-Zugang | nur falls die nächtlichen Backups als zweite Quelle genutzt werden | ja |

---

## Phase 0: Windows-Seite und WSL-Instanz

Läuft auf Windows (PowerShell als Administrator, falls angegeben).

### 0.1 WSL prüfen

```powershell
wsl --version
wsl -l -v
```

Erwartung: WSL ≥ 2.4 (Stand Aufnahme: 3.0.3). Existiert `gekko-ops` bereits:
`GATE` (neu anlegen = `wsl --unregister gekko-ops` löscht die alte Instanz).

### 0.2 `.wslconfig` abgleichen, nicht überschreiben

`C:\Users\PatrickKorczewski\.wslconfig` gilt für **alle** Distros. Die Datei
existiert bereits mit `networkingMode = Mirrored`, `dnsTunneling = true` und
`autoProxy = true`. Das reicht. Nichts ändern. Nur falls die Datei fehlt,
diese Minimalfassung anlegen:

```ini
[wsl2]
networkingMode = Mirrored
dnsTunneling = true
autoProxy = true
```

Mirrored ist nötig, damit `gekko-ops` das Tailnet des Windows-Hosts mitnutzt.

### 0.3 Tailscale auf Windows

```powershell
winget list Tailscale.Tailscale
```

Fehlt es:

```powershell
winget install --id Tailscale.Tailscale -e --accept-package-agreements --accept-source-agreements
```

Anmeldung im Tailnet `gekko32@github` über GitHub im Browser:

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" login --hostname $env:COMPUTERNAME --timeout 5m
```

Der Befehl gibt eine URL `https://login.tailscale.com/a/…` aus und öffnet sie
meist selbst. Dann `GATE`: Der Operator meldet sich im Browser mit
**Sign in with GitHub** als `gekko32` an und bestätigt das Gerät. Ist der
Rechner schon in einem anderen Tailnet (z. B. dem von Patrick), vorher
`tailscale switch --list` prüfen. Mit `tailscale login` kommt ein zusätzliches
Konto dazu, das bestehende bleibt unter `tailscale switch` erhalten.

Prüfen:

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" status --json | ConvertFrom-Json | Select-Object -ExpandProperty CurrentTailnet
& "C:\Program Files\Tailscale\tailscale.exe" ping -c 1 nuc
```

Erwartung: Tailnet `gekko32@github` (bzw. `gekko32.github`), `pong` vom NUC.
Die Hetzner-Knoten tauchen dort erst nach Phase 5 auf. Bis dahin läuft der
Zugriff auf sie über die öffentlichen IPs (SSH) und den Tunnel aus 1.1. Durch
`networkingMode = Mirrored` nutzt `gekko-ops` das Tailnet des Windows-Hosts mit,
in WSL ist kein eigenes Tailscale nötig.

### 0.4 Distro anlegen

```powershell
wsl --install Ubuntu-24.04 --name gekko-ops --no-launch
```

Falls `--name` nicht unterstützt wird oder der Name kollidiert, per Import:

```powershell
New-Item -ItemType Directory -Force C:\WSL\gekko-ops | Out-Null
curl.exe -L -o $env:TEMP\noble.tar.gz https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz
wsl --import gekko-ops C:\WSL\gekko-ops $env:TEMP\noble.tar.gz --version 2
Remove-Item $env:TEMP\noble.tar.gz
```

### 0.5 Benutzer `gekko`, sudo ohne Passwort, systemd

```powershell
wsl -d gekko-ops -u root -- bash -c "id gekko 2>/dev/null || useradd -m -s /bin/bash -G sudo gekko; passwd -l gekko; echo 'gekko ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-gekko; chmod 440 /etc/sudoers.d/90-gekko; visudo -cf /etc/sudoers.d/90-gekko; printf '[boot]\nsystemd=true\n[user]\ndefault=gekko\n[interop]\nappendWindowsPath=false\n' > /etc/wsl.conf"
wsl --terminate gekko-ops
wsl -d gekko-ops -- bash -c "sudo loginctl enable-linger gekko; whoami; sudo -n true && echo sudo-ok; systemctl is-system-running || true; loginctl show-user gekko -p Linger"
```

Erwartung: `gekko`, `sudo-ok`, `running` oder `degraded`, `Linger=yes`.
Ohne Linger löscht systemd `/run/user/<uid>` (und damit `$PLAIN`), sobald die
letzte Sitzung von `gekko` endet. Das passiert zwischen zwei `wsl.exe`-Aufrufen.
`appendWindowsPath=false` verhindert, dass Windows-Binaries (`kubectl.exe`,
`ssh.exe`) Linux-Werkzeuge überschatten.

### 0.6 Schlüssel übernehmen

NTFS-Dateien unter `/mnt/c` haben Modus `0744`, ssh verweigert sie
(„UNPROTECTED PRIVATE KEY FILE“). Deshalb kopieren, nicht verlinken:

```bash
install -d -m700 ~/.ssh
install -m600 /mnt/c/Users/PatrickKorczewski/.ssh/gekko_ed25519 ~/.ssh/gekko_ed25519
install -m644 /mnt/c/Users/PatrickKorczewski/.ssh/gekko_ed25519.pub ~/.ssh/gekko_ed25519.pub
ssh-keygen -y -f ~/.ssh/gekko_ed25519 | cut -d' ' -f2 | diff - <(cut -d' ' -f2 ~/.ssh/gekko_ed25519.pub) && echo key-pair-ok
```

Liegt der Schlüssel auf diesem Rechner nicht unter dem Pfad oben, aus der
Handover-Datei übernehmen. Das holt den Schritt „Handover-Datei einlesen“ aus
[Phase 2.0](#20-handover-datei) vor (dort dann überspringen):

```bash
sudo apt-get update && sudo apt-get install -y age jq
PLAIN=/run/user/$(id -u)/mentolder-plain; install -d -m700 "$PLAIN"
HO=/mnt/c/<pfad>/mentolder-handover-<datum>.json.age   # oder ….json (unverschluesselt)
case "$HO" in
  *.age) age -d -o "$PLAIN/handover.json" "$HO" ;;   # fragt nach der Passphrase
  *)     install -m600 "$HO" "$PLAIN/handover.json" ;;
esac
jq -e '.items|length>0' "$PLAIN/handover.json" >/dev/null && echo handover-ok
jq -r '.items[]|select(.name=="ops/ssh-gekko_ed25519").notes' "$PLAIN/handover.json" > ~/.ssh/gekko_ed25519
jq -r '.items[]|select(.name=="ops/ssh-gekko_ed25519").fields[0].value' "$PLAIN/handover.json" > ~/.ssh/gekko_ed25519.pub
chmod 600 ~/.ssh/gekko_ed25519
```

`$PLAIN` liegt in tmpfs und verschwindet beim WSL-Stopp. Dann diesen Block
wiederholen.

### 0.7 SSH-Konfiguration

`~/.ssh/config` in `gekko-ops` (Modus 600):

```sshconfig
Host gekko-hetzner-* nuc/*
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ControlMaster auto
    ControlPath ~/.ssh/cm-%C
    ControlPersist 5m

Host gekko-hetzner-2/gekko
    HostName 178.104.169.206
    User gekko
    IdentityFile ~/.ssh/gekko_ed25519

Host gekko-hetzner-3/gekko
    HostName 46.225.125.59
    User gekko
    IdentityFile ~/.ssh/gekko_ed25519

Host gekko-hetzner-4/gekko
    HostName 178.104.159.79
    User gekko
    IdentityFile ~/.ssh/gekko_ed25519

Host nuc/gekko
    # Tailnet-IP (Tailnet gekko32@github); lokale LAN-IP alternativ moeglich
    HostName 100.87.136.73
    User gekko
    IdentityFile ~/.ssh/gekko_ed25519
```

`ControlPath` nutzt `%C` (Hash), weil `%h`/`%n` den `/` im Alias in einen
Verzeichnispfad verwandeln würde.

Windows-Seite (`C:\Users\PatrickKorczewski\.ssh\config`): die drei
`gekko-hetzner-*/gekko`-Einträge existieren bereits mit identischen Werten.
Nur `nuc/gekko` ergänzen. Vorher Sicherung anlegen
(`config.bak-<datum>`), Datei nicht neu generieren.

Nach Phase 5 ändern sich die Host-Keys der Knoten. Dann alte Einträge in
`~/.ssh/known_hosts` entfernen (`ssh-keygen -R <ip>`, Windows und WSL).

Verifikation:

```bash
for h in 2 3 4; do ssh gekko-hetzner-$h/gekko 'echo "$(hostname) $(sudo -n true && echo sudo-ok)"'; done
```

### 0.8 NUC vorbereiten

Der NUC ist ein Proxmox-Host im Tailnet `gekko32@github`. Der Windows-Rechner,
auf dem dieser Runbook läuft, muss im selben Tailnet angemeldet sein (0.3).
Proxmox-Hosts haben meist kein `sudo`. Deshalb vorher als root
`apt-get install -y sudo` ausführen. Mit dem vorhandenen Admin-User (I5)
einmalig:

```bash
ssh -o IdentitiesOnly=no "$NUC_BOOTSTRAP_USER@100.87.136.73" "sudo bash -s" <<EOF
id gekko 2>/dev/null || useradd -m -s /bin/bash -G sudo gekko
passwd -l gekko
echo 'gekko ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-gekko && chmod 440 /etc/sudoers.d/90-gekko
install -d -m700 -o gekko -g gekko /home/gekko/.ssh
echo '$(cat ~/.ssh/gekko_ed25519.pub)' > /home/gekko/.ssh/authorized_keys
chown gekko:gekko /home/gekko/.ssh/authorized_keys && chmod 600 /home/gekko/.ssh/authorized_keys
EOF
ssh nuc/gekko 'sudo -n true && echo sudo-ok'
```

### 0.9 Werkzeuge in `gekko-ops`

Immer die aktuelle stabile Version installieren und die installierten Versionen
in `~/mentolder-ops/versions.lock` festhalten.

```bash
sudo apt-get update && sudo apt-get -y full-upgrade
sudo apt-get install -y git curl jq unzip zstd pv rsync age gnupg ca-certificates \
  openssl postgresql-client python3 python3-yaml nodejs npm

mkdir -p ~/.local/bin ~/mentolder-ops && cd ~/mentolder-ops
# gemeinsame Umgebung fuer alle spaeteren Aufrufe (siehe Regeln)
cat > ~/mentolder-ops/env.sh <<'X'
export PATH="$HOME/.local/bin:$PATH"
export PLAIN=/run/user/$(id -u)/mentolder-plain
[ -f ~/mentolder-ops/backup.dir ] && export B=$(cat ~/mentolder-ops/backup.dir)
[ -f ~/mentolder-ops/age.pub ] && export R=$(cat ~/mentolder-ops/age.pub)
[ -f ~/mentolder-ops/kubeconfig.current ] && export KUBECONFIG=$(cat ~/mentolder-ops/kubeconfig.current)
[ -f "$PLAIN/inputs.secret.env" ] && . "$PLAIN/inputs.secret.env"
true
X
grep -q mentolder-ops/env.sh ~/.profile || echo '[ -f ~/mentolder-ops/env.sh ] && . ~/mentolder-ops/env.sh' >> ~/.profile
gh_latest() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name; }

# kubectl (stabile Linie)
KV=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo ~/.local/bin/kubectl "https://dl.k8s.io/release/$KV/bin/linux/amd64/kubectl"
# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR=~/.local/bin USE_SUDO=false bash
# flux, sops, yq, kustomize, crane, cosign, hcloud, task, gh
curl -fsSL https://fluxcd.io/install.sh | bash -s ~/.local/bin
V=$(gh_latest getsops/sops);    curl -fsSLo ~/.local/bin/sops "https://github.com/getsops/sops/releases/download/$V/sops-$V.linux.amd64"
V=$(gh_latest mikefarah/yq);    curl -fsSLo ~/.local/bin/yq "https://github.com/mikefarah/yq/releases/download/$V/yq_linux_amd64"
curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash -s -- ~/.local/bin
V=$(gh_latest google/go-containerregistry); curl -fsSL "https://github.com/google/go-containerregistry/releases/download/$V/go-containerregistry_Linux_x86_64.tar.gz" | tar -xz -C ~/.local/bin crane
V=$(gh_latest sigstore/cosign); curl -fsSLo ~/.local/bin/cosign "https://github.com/sigstore/cosign/releases/download/$V/cosign-linux-amd64"
V=$(gh_latest hetznercloud/cli); curl -fsSL "https://github.com/hetznercloud/cli/releases/download/$V/hcloud-linux-amd64.tar.gz" | tar -xz -C ~/.local/bin hcloud
sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -d -b ~/.local/bin
(type -p gh >/dev/null) || { sudo mkdir -p -m 755 /etc/apt/keyrings && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null && sudo apt-get update && sudo apt-get install -y gh; }
sudo npm i -g @bitwarden/cli
chmod +x ~/.local/bin/*

{ date -Is; for t in kubectl helm flux sops yq kustomize crane cosign hcloud task gh bw age; do printf '%s ' "$t"; $t version --client 2>/dev/null | head -1 || $t --version 2>/dev/null | head -1; done; } > versions.lock
cat versions.lock
```

Danach anmelden: `gh auth login` (I4). Für `hcloud` (I1) reicht das in 2.0 aus
der Handover-Datei gesetzte `HCLOUD_TOKEN` in der Umgebung, ohne Handover-Datei
`hcloud context create gekko`.

`GATE`: Werkzeugliste und SSH-Verifikation zeigen.

---

## Phase 1: Ist-Aufnahme (nur lesend)

### 1.1 Kubeconfig des Altclusters

Die Altknoten hängen in Patricks Tailnet, der Ausführungsrechner in
`gekko32@github`. Die API (6443) ist öffentlich gesperrt. Deshalb über einen
SSH-Tunnel zugreifen (`127.0.0.1` steht im API-Zertifikat):

```bash
mkdir -p ~/.kube
ssh gekko-hetzner-2/gekko 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's#https://127.0.0.1:6443#https://127.0.0.1:16443#' > ~/.kube/fleet-old
chmod 600 ~/.kube/fleet-old
ssh -f -N -o ExitOnForwardFailure=yes -L 16443:127.0.0.1:6443 gekko-hetzner-2/gekko
echo ~/.kube/fleet-old > ~/mentolder-ops/kubeconfig.current; . ~/mentolder-ops/env.sh
kubectl get nodes -o wide
```

Der Tunnel muss bis Phase 4 einschließlich bestehen. Nach einem Abbruch mit
demselben `ssh -f -N …` neu öffnen.

### 1.2 Inventar schreiben

Nach `~/mentolder-ops/inventory/` (ohne Secret-Werte):

```bash
cd ~/mentolder-ops && mkdir -p inventory
kubectl get nodes -o wide                         > inventory/nodes.txt
kubectl top nodes                                 > inventory/top.txt
kubectl get pv,pvc -A -o wide                     > inventory/storage.txt
kubectl get deploy,sts,ds,cronjob -A -o wide      > inventory/workloads.txt
kubectl get ingress,ingressroute -A               > inventory/ingress.txt 2>&1
kubectl get kustomizations,ocirepositories,gitrepositories -A > inventory/flux.txt
kubectl get secrets -A -o custom-columns=NS:.metadata.namespace,N:.metadata.name,T:.type,OWNER:.metadata.ownerReferences[0].kind > inventory/secrets-index.txt
kubectl get deploy,sts -A -o json | jq -r '.items[]|select(.spec.replicas==0)|"\(.metadata.namespace)/\(.metadata.name)"' > inventory/scaled-zero.txt
for h in 2 3 4; do ssh gekko-hetzner-$h/gekko 'echo "$(hostname): $(df -h / | awk "NR==2{print \$2\" gesamt, \"\$4\" frei\"}")"; sudo du -sh /var/lib/rancher/k3s/storage/* 2>/dev/null'; done > inventory/disk.txt
```

### 1.3 Abweichungen klären

`GATE`: dem Operator vorlegen und bestätigen lassen:

- Namespaces `workspace-korczewski`, `workspace-staging`, `website-korczewski`
  und `website-staging` (am 2026-10-20 erst 8 h alt) gehören laut ADR-014 nicht
  auf fleet. Sie werden **nicht** übernommen. Mit Patrick klären, ob dort Daten
  liegen.
- `flux-office` (Collabora) stand am 2026-10-20 auf „Reconciliation in progress“.
  Den Zustand vor dem Umbau festhalten.
- Port 22 ist auf den öffentlichen IPs erreichbar, obwohl ADR-014 SSH nur privat
  oder per Tailnet vorsieht. Phase 5 setzt bewusst `ufw limit 22/tcp` mit reinem
  Schlüssel-Login, weil die SSH-Konfiguration öffentliche IPs nutzt.

---

## Phase 2: Secrets und Umgebungswerte erfassen

Quelle der Wahrheit ist der **laufende Cluster**: Er enthält die entschlüsselten
Werte aller SealedSecrets und die Secrets, die nie versiegelt wurden. Ein
git-crypt-Schlüssel ist dafür nicht nötig.

### 2.0 Handover-Datei

Da Vaultwarden erst nach dem Neuaufbau wieder läuft, transportiert eine
JSON-Datei alle Werte zum Ausführungsrechner. Erzeugt wird sie auf einem
Rechner mit Zugriff auf den Altcluster (Kontext `fleet`):

```bash
bash scripts/handover-export.sh ~/mentolder-handover-$(date +%F).json
```

Inhalt (Format `bitwardenjson`, direkt importierbar mit `bw import`):

- `k8s/<namespace>/<name>`: ein Eintrag pro Kubernetes-Secret, Felder = Schlüssel.
  Werte über 3000 Zeichen stehen in eigenen Einträgen `k8s/<ns>/<name>#<key>`.
  Binärwerte tragen das Suffix `:base64`.
- `ops/inputs`: Tailscale-API- und Auth-Key, Hetzner-Token, NUC-IP.
- `ops/sops-age`: neuer SOPS-Schlüssel (privat und öffentlich).
- `ops/k3s`: neues k3s-Token.
- `ops/ssh-gekko_ed25519`: Schlüsselpaar.

Nicht enthalten sind TLS-Secrets (cert-manager stellt neu aus) und von
Operatoren generierte Secrets. Am 2026-10-20 nutzte der Altcluster alle in den
Workloads referenzierten Schlüssel ohne Lücke (70 `secretKeyRef`/`envFrom`
geprüft). Leer war nur `website-secrets:GITHUB_MODELS_TOKEN` (optional).

Auf dem Ausführungsrechner. Die Datei darf unverschlüsselt (`.json`) oder mit
`age -p` verschlüsselt (`.json.age`) vorliegen. Wurde sie schon in 0.6
eingelesen, den ersten Block überspringen.

Handover-Datei einlesen:

```bash
PLAIN=/run/user/$(id -u)/mentolder-plain; install -d -m700 "$PLAIN"
HO=/mnt/c/<pfad>/mentolder-handover-<datum>.json.age   # oder ….json (unverschluesselt)
case "$HO" in
  *.age) age -d -o "$PLAIN/handover.json" "$HO" ;;   # fragt nach der Passphrase
  *)     install -m600 "$HO" "$PLAIN/handover.json" ;;
esac
jq -e '.items|length>0' "$PLAIN/handover.json" >/dev/null && echo handover-ok
```

Werte übernehmen:

```bash
# handover-to-secrets.sh liegt in gekko32/mentolder-prod (nach dem Merge von PR #18
# auf main, bis dahin Branch docs/fresh-cluster-runbook). Klon aus 3.1 vorziehen:
[ -d ~/mentolder-ops/prod ] || git clone https://github.com/gekko32/mentolder-prod ~/mentolder-ops/prod
cd ~/mentolder-ops/prod && { [ -f scripts/handover-to-secrets.sh ] || git checkout docs/fresh-cluster-runbook -- scripts/handover-to-secrets.sh; }
bash scripts/handover-to-secrets.sh "$PLAIN/handover.json" "$PLAIN/secrets"
jq -r '.items[]|select(.name=="ops/sops-age").fields[]|select(.name=="SOPS_AGE_KEY").value' "$PLAIN/handover.json" > "$PLAIN/mentolder.agekey"
jq -r '.items[]|select(.name=="ops/sops-age").fields[]|select(.name=="SOPS_AGE_PUBLIC").value' "$PLAIN/handover.json" > ~/mentolder-ops/age.pub
# Zugaenge aus ops/inputs (fuer 5.1 bis 5.3)
ho_input() { jq -r --arg k "$1" '.items[]|select(.name=="ops/inputs").fields[]|select(.name==$k).value' "$PLAIN/handover.json"; }
{ printf 'export TS_AUTHKEY=%q\n'   "$(ho_input TAILSCALE_AUTH_KEY)"
  printf 'export TS_API_KEY=%q\n'   "$(ho_input TAILSCALE_API_KEY)"
  printf 'export HCLOUD_TOKEN=%q\n' "$(ho_input HCLOUD_TOKEN)"; } > "$PLAIN/inputs.secret.env"
chmod 600 "$PLAIN/inputs.secret.env"
. "$PLAIN/inputs.secret.env"
for v in TS_AUTHKEY TS_API_KEY HCLOUD_TOKEN; do [ -n "${!v}" ] && echo "$v gesetzt" || echo "$v FEHLT"; done
```

`$PLAIN/inputs.secret.env` in jeder neuen Shell vor Phase 5 erneut laden
(`. "$PLAIN/inputs.secret.env"`).

Damit sind 2.1 und 2.2 erledigt, mit einer Ausnahme: Die passwortgeschützte
Kopie des age-Schlüssels aus 2.1 ist **Pflicht**. Ohne sie liegt der Schlüssel,
der alle Backups aus Phase 4 entschlüsselt, nur in tmpfs. Ein WSL-Neustart vor
Phase 8 macht die Backups dann unlesbar:

```bash
age -p -o ~/mentolder-ops/mentolder.agekey.age "$PLAIN/mentolder.agekey"   # Passphrase gibt der Operator ein
```

Weiter mit 2.3. Die Handover-Datei auf dem Transportmedium **nicht** sofort
vernichten:

- `.json.age`: bis zum Abschluss von Phase 8.3 aufbewahren, dann mit `shred -u` löschen.
- `.json` (unverschlüsselt): sofort verschlüsselt sichern und das Original vernichten:
  `age -p -o ~/mentolder-ops/handover.json.age "$PLAIN/handover.json" && shred -u "$HO"`.

Nach einem WSL-Neustart lassen sich `$PLAIN` und der Schlüssel mit dem Block
„Handover-Datei einlesen“ (dann mit `HO=~/mentolder-ops/handover.json.age`) oder mit
`age -d -o "$PLAIN/mentolder.agekey" ~/mentolder-ops/mentolder.agekey.age` wiederherstellen.

### 2.1 Arbeitsbereich und age-Schlüssel (nur ohne Handover-Datei)

```bash
PLAIN=/run/user/$(id -u)/mentolder-plain
install -d -m700 "$PLAIN"
age-keygen -o "$PLAIN/mentolder.agekey"
grep -o 'age1[0-9a-z]*' "$PLAIN/mentolder.agekey" > ~/mentolder-ops/age.pub
```

Dieser Schlüssel wird später der SOPS-Schlüssel des Clusters. Er geht in
Phase 8 nach Vaultwarden. Bis dahin liegt er nur in tmpfs **und** als
passwortgeschützte Kopie:
`age -p -o ~/mentolder-ops/mentolder.agekey.age "$PLAIN/mentolder.agekey"`
(Passphrase gibt der Operator ein, sie wird nicht gespeichert).

### 2.2 Secrets exportieren (nur ohne Handover-Datei)

Umfang: Namespaces `workspace`, `website`, `coturn`, `rustdesk`,
`workspace-office`, `monitoring`, `cert-manager`, `flux-system`. Ausgeschlossen:
Service-Account-Tokens, Helm-Releases, k3s-Node-Passwörter, von Operatoren
generierte Secrets (`*-generated`, `*-web-config`, `prometheus-*`,
`monitoring-admission`, `cert-manager-webhook-ca`).

```bash
NS="workspace website coturn rustdesk workspace-office monitoring cert-manager flux-system"
mkdir -p "$PLAIN/secrets"
for ns in $NS; do
  kubectl get secrets -n "$ns" -o json | jq -c '.items[]
    | select(.type|IN("kubernetes.io/service-account-token","helm.sh/release.v1","k3s.cattle.io/node-password")|not)
    | select(.metadata.name|test("-generated$|-web-config$|^prometheus-|^monitoring-admission$|^cert-manager-webhook-ca$|^sh\\.helm")|not)
    | {apiVersion:"v1",kind:"Secret",type,
       metadata:{name:.metadata.name,namespace:.metadata.namespace,
                 labels:(.metadata.labels//{}|with_entries(select(.key|test("sealedsecrets|kustomize.toolkit")|not))),
                 annotations:(.metadata.annotations//{}|with_entries(select(.key|test("cert-manager.io/")))) },
       data}' \
  | while read -r s; do n=$(jq -r '.metadata.namespace+"__"+.metadata.name' <<<"$s"); echo "$s" > "$PLAIN/secrets/$n.json"; done
done
ls "$PLAIN/secrets" | wc -l
```

TLS-Secrets (`kubernetes.io/tls`) werden mit ihren `cert-manager.io`-Annotationen
übernommen. So stellt cert-manager im neuen Cluster keine neuen Zertifikate aus
(Let's-Encrypt-Rate-Limits).

Sofort eine verschlüsselte Sicherung anlegen:

```bash
tar -C "$PLAIN" -cf - secrets | zstd | age -r "$(cat ~/mentolder-ops/age.pub)" > ~/mentolder-ops/secrets-$(date +%F).tar.zst.age
```

### 2.3 Umgebungswerte

Die nicht geheimen Werte stehen in `environments/mentolder.yaml` und
`environments/fleet-mentolder.yaml` in diesem Repo. Veraltete Einträge
**nicht** übernehmen und für die Bereinigung in Phase 3 vormerken:

- `WG_MESH_*`: ADR-014 hat das WireGuard-Mesh abgeschafft.
- `PVE*_SSH_*`, `PVE_HOSTS`, `DEVC_*`: Proxmox und devc sind stillgelegt.
- `DEV_*`, `TURN_NODE: pk-hetzner-4`, `TURN_PUBLIC_IP: 204.168.244.104`,
  `TURN_OVERLAY_IP: 10.20.0.1`: verweisen auf pk-hetzner-Knoten.
  Mit der Live-Konfiguration abgleichen (`kubectl get cm -n workspace domain-config -o yaml`,
  coturn-Deployment).
- `WEBSITE_NODE_AFFINITY` mit `pk-hetzner-*`: auf `gekko-hetzner-*` setzen.
- `LLM_*`-URLs auf `workspace-dev` und `LLM_HOST_IP 192.168.100.10`: im
  Prod-Cluster nicht erreichbar. `LLM_ENABLED` mit dem Operator klären.

### 2.4 Lücken gegen das Schema prüfen und füllen

`environments/schema.yaml` (nach Phase 3.1 im Repo, vorher aus
`Paddione/Bachelorprojekt` bei `UPSTREAM_REF`) listet alle Secret-Schlüssel mit
`required` und `generate`. Abgleich:

```bash
# alle Schlüssel aus den Live-Secrets
jq -r '.data|keys[]' "$PLAIN"/secrets/*.json | sort -u > "$PLAIN/live-keys.txt"
# Schema-Secrets (Abschnitt secrets:) mit generate-Angabe
yq -r '.secrets[] | [.name, (.generate // false), (.length // 32), (.required // false)] | @tsv' environments/schema.yaml > "$PLAIN/schema-secrets.tsv"
# fehlende oder leere Werte
while IFS=$'\t' read -r k gen len req; do
  v=$(jq -r --arg k "$k" 'select(.data[$k]!=null)|.data[$k]' "$PLAIN"/secrets/*.json | head -1)
  [ -z "$v" ] && printf '%s\t%s\t%s\t%s\n' "$k" "$gen" "$len" "$req"
done < "$PLAIN/schema-secrets.tsv" > "$PLAIN/missing.tsv"
cat "$PLAIN/missing.tsv"   # Schluessel, generate, length, required (keine Werte)
```

Regeln für fehlende oder leere Werte:

| Fall | Aktion |
|---|---|
| `generate: true`, Wert nicht an restaurierte Daten gebunden | neu erzeugen: `openssl rand -base64 64 \| tr -d '\n/+=' \| cut -c1-<length>` |
| Wert an Daten gebunden (siehe unten) | **nie neu erzeugen**, Phase abbrechen, Operator fragen |
| externer Zugang (SMTP, ipv64, Filen, GHCR, Mailbox) | Operator fragen, nicht raten |
| nur Altinfrastruktur (WG, PVE, devc) | weglassen |

**An Daten gebunden** und deshalb unverändert aus dem Altcluster zu übernehmen:
alle `*_DB_PASSWORD`, Postgres-Superuser, Nextcloud `secret`/`passwordsalt`/
`instanceid` (stehen in `config.php` auf dem PVC `nextcloud-app`), Pocket-ID-
Encryption-Key, OIDC-Client-Secrets (in der Pocket-ID-DB registriert),
Signaling/TURN-Secrets (in der Nextcloud-DB konfiguriert), `brain`-/`studio`-
Schlüssel für vorhandene Daten.

Neu erzeugte Werte in `$PLAIN/generated.env` (Schlüsselname = Wert) ablegen und
in die passende Secret-Datei unter `$PLAIN/secrets/` eintragen.

`GATE`: Liste fehlender Schlüssel mit geplanter Aktion vorlegen (ohne Werte).

---

## Phase 3: mentolder-prod entkoppeln

Ziel: Der neue Cluster synchronisiert ausschließlich aus `gekko32/mentolder-prod`
und zieht Images ausschließlich aus `ghcr.io/gekko32/*`. Diese Phase läuft
**vor** dem Wartungsfenster, der Altcluster bleibt unberührt.

Alle Änderungen auf einem Branch, z. B. `gekko/fresh-cluster`, als ein PR oder
als Folge kleiner PRs. Der Altcluster liest `main` über `gekko-mentolder-flux`.
Deshalb **erst nach Phase 5 mergen** oder vorher `gekko-mentolder-flux` und
`mentolder-prod*` suspendieren.

### 3.1 Basen vendoren

Das Werkzeug existiert bereits: `scripts/export-mentolder-prod.sh` in
Bachelorprojekt (Inventar: `docs/handover/mentolder-gekko/INVENTORY.md` dort).

```bash
cd ~/mentolder-ops
git clone https://github.com/Paddione/Bachelorprojekt upstream
git clone https://github.com/gekko32/mentolder-prod prod && cd prod && git switch -c gekko/fresh-cluster
REF=$(tr -d '[:space:]' < UPSTREAM_REF)
git -C ../upstream checkout --quiet "$REF"
bash ../upstream/scripts/export-mentolder-prod.sh --ref "$REF" --out ../export
```

Übernahme in `prod/`:

- `k3d/`, `prod/`, `prod-fleet/{platform,components,coturn,website-common}`,
  `environments/{schema,versions}.yaml`, Render-Skripte aus dem Export.
- Zusätzlich die Overlays für `office` und `rustdesk`. Der Export kennt nur
  `platform`, `mentolder`, `website-mentolder` und `coturn`. Quelle der beiden:
  die Kustomizations `flux-office` und `flux-rustdesk` in
  `upstream/flux/clusters/fleet-gekko/ks-prod.yaml` (deren `path` im Render).
- Die vorhandenen Gekko-Overlays (`prod-mentolder/`, `prod-fleet/mentolder/`,
  `prod-fleet/website-mentolder/`) bleiben führend. Bei Konflikten gewinnt der
  Gekko-Stand.
- **Nicht** übernehmen: `environments/.secrets/**`,
  `environments/sealed-secrets/**`, git-crypt-Filter, Templates mit
  `__GEKKO_*__`, falls die Werte unten schon feststehen.
- `UPSTREAM_REF` durch `VENDORED_FROM` ersetzen (Commit + Datum, nur zur Info).
- `render.yml` umstellen: kein Upstream-Checkout mehr, Render aus dem eigenen
  Baum mit den Targets `platform,coturn,office,rustdesk,mentolder,website-mentolder`.

Verifikation (Render-Äquivalenz gegen den heutigen Stand):

```bash
for t in mentolder website-mentolder; do
  kustomize build ../export/prod-fleet/$t > /tmp/old-$t.yaml
  kustomize build prod-fleet/$t          > /tmp/new-$t.yaml
  diff -q /tmp/old-$t.yaml /tmp/new-$t.yaml && echo "$t identisch"
done
```

Abweichungen sind nur dort zulässig, wo 3.2 (Images), 3.3 (Secrets) oder 2.3
(veraltete Werte) sie verursachen.

### 3.2 Images selbst bauen (`ghcr.io/gekko32`)

Der GHCR-Namespace entspricht dem GitHub-Account. Also `ghcr.io/gekko32/*`,
nicht `ghcr.io/gekko`. Kein Kopieren aus `ghcr.io/paddione`: mentolder-prod
baut jedes Image aus eigenen Quellen.

Image-Liste aus dem Render ableiten, nicht von Hand pflegen:

```bash
kustomize build prod-fleet/mentolder prod-fleet/website-mentolder 2>/dev/null | yq -r '.. | .image? | select(.)' \
  | grep '^ghcr.io/paddione/' | sed 's/@sha256.*//' | sort -u
```

Stand 2026-10-21: `collabora-code`, `downloads-content`, `einvoice-sidecar`,
`mcp-node`, `mentolder-web`, `studio-server` und `talk-transcriber`. `brett`,
`website` und `fuehrungsfunk` bauen ihre eigenen gekko32-Repos.

- Quellen aus Bachelorprojekt vendoren (`components/mentolder-web`,
  `components/studio-server`, `docker/{collabora,einvoice-sidecar,mcp-node}`,
  `k3d/talk-transcriber`, `rustdesk-installer`, `scripts/downloads.*`) und in
  `VENDORED_FROM` vermerken.
- Workflows `build-images.yml`, `build-collabora.yml` (Push auf `main`, PRs nur
  Build) und `build-downloads.yml` (nur manuell, privat, Repo-Secrets
  `RUSTDESK_CLIENT_CONFIG_STRING` und `RUSTDESK_UNATTENDED_PASSWORD`). Login mit
  `GITHUB_TOKEN`, Tags `latest` und `sha-<commit>`.
- Basen auf `ghcr.io/gekko32/<name>:latest` umstellen. `render.yml` löst die
  Digests aller eigenen Images auf (Pins in `images.env`) und setzt sie per
  `kustomize edit set image` bzw. `STUDIO_IMAGE_DIGEST`.

Verifikation: Render-Schritt „Check image references“ in `render.yml` (keine
`ghcr.io/paddione`-Referenz, eigene Images nur digest-gepinnt).

Die ersten eigenen Builds stammen aus dem vendorten Quellstand und können sich
vom bisher laufenden Image unterscheiden (z. B. Collabora 26.04 statt 25.04,
studio-server neuer als das Image vom Juni). In Phase 6 abnehmen.

**Manueller Schritt (GitHub-UI, keine API):** Jedes neue Paket ist zunächst
privat. Für jedes Paket außer `downloads-content` unter
`https://github.com/users/gekko32/packages/container/<name>/settings` die
Sichtbarkeit auf **Public** setzen und das Paket mit diesem Repo verknüpfen.
`downloads-content` bleibt privat (eingebackenes Passwort). Danach braucht der
neue Cluster `ghcr-pull-secret` nur noch für `downloads-content`, mit einem
gekko32-Token.

`GATE`: Operator bestätigt, dass alle Pakete außer `downloads-content`
öffentlich sind (`crane manifest ghcr.io/gekko32/<name>:latest` ohne Login).

### 3.3 SOPS/age einrichten

```yaml
# .sops.yaml
creation_rules:
  - path_regex: secrets/.*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: age1…   # Inhalt von ~/mentolder-ops/age.pub
```

Struktur: `secrets/<namespace>/<name>.sops.yaml` plus
`secrets/kustomization.yaml`. Befüllt wird das erst in Phase 8, nach der
Abnahme. Bis dahin enthält der Ordner nur `kustomization.yaml` mit leerer
`resources:`-Liste.

### 3.4 Flux-Einstieg für den neuen Cluster

Der neue Cluster gehört nur noch Gekko. Die Mandanten-Trennung aus
Bachelorprojekt (`gekko-mentolder-flux`, Admission-Policies) entfällt.
Cosign-Prüfung und Commit-Signaturprüfung bleiben.

Neues Verzeichnis `flux/clusters/fleet/` im Repo:

- `flux-instance.yaml`: `FluxInstance` mit Sync auf
  `https://github.com/gekko32/mentolder-prod`, `ref: refs/heads/main`,
  `path: flux/clusters/fleet`. Komponenten wie bisher (source, kustomize, helm,
  notification).
- `oci-source.yaml`: `OCIRepository mentolder-manifests` in `flux-system`, URL
  `oci://ghcr.io/gekko32/mentolder-manifests`, cosign
  `matchOIDCIdentity` auf
  `^https://github\.com/gekko32/mentolder-prod/\.github/workflows/render\.yml@refs/heads/main$`.
- `ks-secrets.yaml`: Kustomization `mentolder-secrets`, Quelle `GitRepository`
  `flux-system`, `path: ./secrets`, `decryption: {provider: sops, secretRef: {name: sops-age}}`,
  `prune: false`.
- `ks-prod.yaml`: Kustomizations `platform`, `coturn`, `office`, `rustdesk`,
  `mentolder-prod` und `mentolder-prod-website` aus dem OCI-Artefakt, jeweils
  `dependsOn: [mentolder-secrets, platform]`. Die bestehenden
  `healthChecks` (shared-db, pocket-id) übernehmen.
- Das alte `flux/` (Namespace `gekko-mentolder`) bleibt bis zur Abschaltung des
  Altclusters liegen und wird in Phase 9 entfernt.

`GATE`: PR öffnen (Draft), Render-Workflow auf dem Branch per
`workflow_dispatch` testen, Diff-Zusammenfassung vorlegen. **Nicht mergen.**

---

## Schnellweg: Phase 4 bis 6 mit `scripts/fresh-cluster/` (Generalprobe 2026-10-21)

Die Schritte 4.3 bis 6.6 sind als Skripte erprobt. Generalprobe am 2026-10-21 auf
drei Wegwerf-Servern (`rehearsal.sh`, LE-Staging, CronJobs aus, ausgehend kein
SMTP) mit einer Live-Sicherung der Produktion: alle Hosts antworteten wie im
Altcluster, Datenbank zeilengenau, Volumes in gleicher Größe. Danach abgebaut.
Die Abschnitte 4.x bis 6.x unten bleiben die Referenz für das Warum.

Voraussetzungen: Phase 2.0 in dieser Shell geladen (`. ~/mentolder-ops/env.sh`),
`$PLAIN/ghcr-token` (6.1), Tunnel zum Altcluster als User-Dienst
`fleet-old-tunnel` (1.1, `Restart=always`), Linger an.

| Schritt | Befehl | Dauer (Probe) |
|---|---|---|
| 4.2 | PR #21 mergen, Flux anwenden lassen, dann `flux suspend kustomization --all -n gekko-mentolder` | 5 min |
| 4.3/4.4 | `S=scripts/fresh-cluster; echo ~/mentolder-ops/backup/$(date +%F) > ~/mentolder-ops/backup.dir; . ~/mentolder-ops/env.sh; $S/backup.sh "$B"` | 8 min |
| 4.5 | `$S/probe.sh "$B"`, Zweitkopie `rsync -a "$B" "$(cat ~/mentolder-ops/second-copy.dir)/"` | 3 min |
| `GATE` | „Phase 5 starten“ | |
| 5.2 | `CONFIRM=rebuild $S/fleet.sh rebuild` | 2 min |
| 5.3 | `$S/fleet.sh wait` (Tailnet + cloud-init) | 5–8 min |
| 5.4 | `$S/fleet.sh k3s` (Kanal v1.37, Token aus der Handover-Datei) | 2 min |
| 6.1 | `export KUBECONFIG=~/.kube/fleet; echo ~/.kube/fleet > ~/mentolder-ops/kubeconfig.current; TLS_BACKUP=$B/tls-secrets.json.age $S/fleet.sh secrets` | 1 min |
| 6.2 | `$S/fleet.sh flux` (PR #20 ist seit 2026-10-21 19:01 auf `main`, `render.yml` erzeugt das Artefakt) | 10 min |
| 6.3 | `$S/fleet.sh restore-window` | 1 min |
| 6.4 | `$S/fleet.sh restore-db "$B"` | 1 min |
| 6.5 | `$S/fleet.sh restore-pvcs "$B"` | 7 min |
| 6.6 | `$S/fleet.sh restore-done`, danach `occ` (siehe 6.6) | 5 min |
| 6.7 | Abnahme | 15 min |

Geschätzte Ausfallzeit damit rund 75 Minuten statt 3 Stunden.

Funde der Generalprobe, in den Skripten bzw. PR #20 bereits behoben:

| Fund | Folge ohne Korrektur | Korrektur |
|---|---|---|
| `kubectl exec` über den API-Tunnel bricht große Streams ab (websocket 1006) | DB-Dump abgeschnitten, unbemerkt | Dump/Restore per SSH auf dem DB-Knoten, Vollständigkeitsprüfung auf `dump complete` |
| `tar` endet mit 1, wenn Dateien sich ändern (Grafana läuft weiter) | 4.4 bricht nach der ersten Monitoring-PVC ab | Exit 1 als Warnung |
| `tailscale up --ssh` übernimmt Port 22 im Tailnet, Policy erlaubt SSH nur `autogroup:self` | kein SSH zu den getaggten Knoten über das Tailnet | ohne `--ssh`, normales sshd |
| Grundprovisionierung jetzt per cloud-init beim Rebuild (`node-cloud-init.yaml.tmpl`) | – | kein root-SSH aus dem Internet; Einmal-Auth-Key je Knoten (1 h), da Hetzner user-data im Klartext hält |
| k3s-Kanal `stable` ist v1.36, der Altcluster lief auf v1.37.1 | Downgrade der Kubernetes-Version | Kanal `v1.37` |
| Öffentlich offen im Altcluster: 6443, 10250, 2379/2380, 8472, 9500, 10256 | – | nur noch privat/Tailnet; öffentlich 22 (limit), 80, 443, TURN, Janus |
| cert-manager und lego-Webhook waren von Hand per Helm installiert, nicht im Render | `platform` scheitert am fehlenden ClusterIssuer-CRD | PR #20: `flux/infra` (HelmReleases, Kustomization `infra-controllers`) |
| lego-Webhook braucht `IPV64_API_KEY` als Umgebungsvariable (im Altcluster von Hand ergänzt) | DNS-01 meldet „credentials missing“ | PR #20: postRenderer im HelmRelease |
| ipv64 antwortet beim Aufräumen der zweiten TXT-Antwort (Apex + Wildcard) mit 403, cert-manager arbeitet Challenges je DNS-Name nacheinander ab | nur das erste Wildcard-Zertifikat wird ausgestellt, die anderen hängen (Ursache für `office-wildcard` InProgress im Altcluster) | TLS-Secrets aus dem Altcluster mitnehmen (gültig bis 2027-01-10). **Offen bis zur Erneuerung am 2026-12-11** |
| Secret `monitoring/monitoring-admission` (kube-webhook-certgen) fehlt in Render und Handover | Prometheus-Operator startet nicht | `fleet.sh secrets` erzeugt ein selbstsigniertes Paar |
| `downloads-content` ist privat, `render.yml` (GITHUB_TOKEN) kann es nicht lesen | Render auf `main` scheitert, Flux bekommt kein Artefakt | Paket-Einstellung „Manage Actions access“: `gekko32/mentolder-prod` mit Read, sonst Digest in `images.env` pinnen |
| `flux resume` wartet bis zum Intervall | Apps bleiben bis zu 10 min auf 0 | `restore-done` stößt `flux reconcile` an |
| Nextcloud-Container läuft schon als `www-data`, `su` fragt nach Passwort | 6.6-Befehl scheitert | `php occ …` direkt |
| Restore-Probe: Größen liegen 6–38 % unter Live (Bloat) | ±10 %-Kriterium schlägt fehl | Vergleich der Zeilenzahl je Tabelle (`probe.sh`) |
| Auf `gekko-hetzner-2` läuft ein k3d-Dev-Cluster (`mentolder-dev`, seit 2026-05-13), auf `-3` ein GitHub-Runner für `Paddione/Bachelorprojekt`, auf allen drei `wg-gpu` zu 2.241.169.56 | gehen beim Rebuild verloren | Entscheidung vor Phase 5 |

## Phase 4: Wartungsfenster, Sicherung, Restore-Probe

### 4.1 Platz prüfen

Auf `gekko-hetzner-2` und `-3` sind nur je ca. 13 GB frei (Stand 2026-10-20).
Backups deshalb **direkt per SSH auf `gekko-ops` streamen**, nie auf dem Knoten
zwischenspeichern. Freien Platz in WSL prüfen: `df -h ~` muss mindestens die
Summe aus `inventory/disk.txt` plus 20 % bieten. Sonst
`~/mentolder-ops/backup` auf ein größeres Laufwerk legen (`/mnt/d/...`). Das
geht, weil die Dateien age-verschlüsselt sind.

### 4.2 Ankündigung und Einfrieren

`GATE`: Beginn des Wartungsfensters (I9) bestätigen.

```bash
export KUBECONFIG=~/.kube/fleet-old
flux suspend kustomization --all -n gekko-mentolder
flux suspend kustomization --all -n flux-system
kubectl -n workspace get deploy -o json | jq -r '.items[]|select(.spec.replicas>0)|"\(.metadata.name)=\(.spec.replicas)"' > ~/mentolder-ops/replicas-before.txt
for d in $(cut -d= -f1 ~/mentolder-ops/replicas-before.txt | grep -vx shared-db); do kubectl -n workspace scale deploy "$d" --replicas=0; done
kubectl -n workspace get cronjob -o name | xargs -r -n1 kubectl -n workspace patch --type merge -p '{"spec":{"suspend":true}}'
kubectl -n workspace wait --for=delete pod -l 'app!=shared-db' --timeout=300s || true
```

Danach laufen nur noch `shared-db` und die Plattform.

### 4.3 Datenbank (logisch, versionsunabhängig)

```bash
# Backup-Verzeichnis einmalig festlegen; 4.4 bis 6.5 nutzen es ueber env.sh, auch an Folgetagen
[ -f ~/mentolder-ops/backup.dir ] || echo ~/mentolder-ops/backup/$(date +%F) > ~/mentolder-ops/backup.dir
. ~/mentolder-ops/env.sh; mkdir -p "$B"; [ -n "$R" ] || { echo "age.pub fehlt (2.0)"; exit 1; }
kubectl -n workspace exec deploy/shared-db -- sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}" --clean --if-exists' \
  | zstd -T0 | tee >(sha256sum > "$B/db.sha256") | age -r "$R" > "$B/shared-db.sql.zst.age"
kubectl -n workspace exec deploy/shared-db -- sh -c 'psql -U "${POSTGRES_USER:-postgres}" -Atc "select datname, pg_database_size(datname) from pg_database where not datistemplate"' > "$B/db-sizes.txt"
```

Den Benutzernamen gegebenenfalls aus dem Deployment lesen
(`kubectl -n workspace get deploy shared-db -o yaml | grep -A1 POSTGRES_USER`).
Die Postgres-Version und das genaue Image festhalten (die Restore-Probe braucht
dasselbe Image, falls `shared-db` Erweiterungen wie pgvector mitbringt):

```bash
kubectl -n workspace exec deploy/shared-db -- postgres --version > "$B/db-version.txt"
kubectl -n workspace get deploy shared-db -o jsonpath='{.spec.template.spec.containers[0].image}' > "$B/db-image.txt"
kubectl -n workspace exec deploy/shared-db -- sh -c 'psql -U "${POSTGRES_USER:-postgres}" -Atc "select extname from pg_extension" -d postgres' > "$B/db-extensions.txt"
```

### 4.4 Volumes (roh, per SSH vom Knoten)

Für jede PVC aus `inventory/storage.txt` im Namespace `workspace`
(`nextcloud-app`, `nextcloud-data-pvc`, `pocket-id-data`, `brain-data`,
`fuehrungsfunk-daten`, `backup-pvc`; `shared-db-pvc` zusätzlich als Rohkopie)
sowie optional `monitoring-grafana`:

```bash
kubectl -n workspace scale deploy shared-db --replicas=0
kubectl get pv -o json | jq -r '.items[]|select(.spec.claimRef.namespace|IN("workspace","monitoring"))
  |[.spec.claimRef.namespace,.spec.claimRef.name,(.spec.local.path//.spec.hostPath.path),.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]]|@tsv' > "$B/pv-map.tsv"
while IFS=$'\t' read -r ns pvc path node; do
  case "$pvc" in bge-*|prometheus-*|alertmanager-*) continue;; esac
  echo ">> $ns/$pvc von $node"
  ssh -n "$node/gekko" "sudo tar --numeric-owner --xattrs --acls -C '$path' -cpf - ." \
    | pv -N "$pvc" | zstd -T0 | tee >(sha256sum > "$B/${ns}__${pvc}.sha256") | age -r "$R" > "$B/${ns}__${pvc}.tar.zst.age"
done < "$B/pv-map.tsv"
# Vollstaendigkeit: ein Archiv pro nicht uebersprungener PVC
grep -cvE $'\t(bge-|prometheus-|alertmanager-)' "$B/pv-map.tsv"; ls "$B"/*.tar.zst.age | wc -l
```

`ssh -n` ist Pflicht: Ohne `-n` liest `ssh` den Rest von `pv-map.tsv` aus stdin,
und nur die erste PVC wird gesichert. Beide Zahlen oben müssen gleich sein.

TLS-Secrets und alle anderen Secrets liegen bereits aus Phase 2.2 vor. Zusätzlich
die etcd-Datenbank sichern, um bei einem Rückbau den Altcluster samt Zustand
wiederherstellen zu können:

```bash
ssh gekko-hetzner-2/gekko 'sudo k3s etcd-snapshot save --name pre-rebuild && sudo ls /var/lib/rancher/k3s/server/db/snapshots/ | grep pre-rebuild'
ssh gekko-hetzner-2/gekko 'sudo sh -c "cat /var/lib/rancher/k3s/server/db/snapshots/pre-rebuild-*; "' | age -r "$R" > "$B/etcd-pre-rebuild.age"
ssh gekko-hetzner-2/gekko 'sudo cat /var/lib/rancher/k3s/server/token' | age -r "$R" > "$B/k3s-token-old.age"
```

### 4.5 Restore-Probe (Pflicht vor Phase 5)

```bash
age -d -i "$PLAIN/mentolder.agekey" "$B/shared-db.sql.zst.age" | zstd -dc > "$PLAIN/probe.sql"
command -v docker >/dev/null || sudo apt-get install -y docker.io
# dasselbe Image wie shared-db (Erweiterungen), sonst Fallback auf postgres:<major>
PGIMAGE=$(cat "$B/db-image.txt" 2>/dev/null)
[ -n "$PGIMAGE" ] || PGIMAGE="postgres:$(grep -oE '[0-9]+' "$B/db-version.txt" | head -1)"
sudo docker run -d --name pgprobe -e POSTGRES_PASSWORD=probe "$PGIMAGE"
until sudo docker exec pgprobe pg_isready -U postgres >/dev/null 2>&1; do sleep 2; done
sudo docker exec -i pgprobe psql -U postgres -v ON_ERROR_STOP=0 < "$PLAIN/probe.sql" > /dev/null 2> "$PLAIN/probe.err"
sudo docker exec pgprobe psql -U postgres -Atc "select datname, pg_database_size(datname) from pg_database where not datistemplate"
sudo docker rm -f pgprobe; shred -u "$PLAIN/probe.sql"
```

Erwartung: dieselben Datenbanken wie in `db-sizes.txt`, Größen im Bereich ±10 %.
Fehler in `probe.err` sind nur zulässig für bereits existierende Rollen
(`role "postgres" already exists`) und `current user cannot be dropped`
(Folge von `--clean`). Prüfen:
`grep -v -E 'already exists|current user cannot be dropped' "$PLAIN/probe.err" | head -20`.
Ist das Image privat (`ghcr.io/…`), vorher `sudo docker login ghcr.io` oder auf
`postgres:<major>` plus passende Erweiterung ausweichen.

Für jede Volume-Datei: `age -d … | zstd -dc | tar -tf - | wc -l` (lesbar,
Dateianzahl > 0). Nextcloud-App muss `config/config.php` enthalten.

Zweite Kopie: das komplette `$B` auf ein zweites Ziel kopieren (NUC bei
`NUC_ROLE=backup`: `rsync -a "$B" nuc/gekko:/srv/mentolder-backup/`, sonst
Windows-Laufwerk oder Filen).

`GATE`: Ab hier ist der Weg destruktiv. Vorlegen: Liste der Backup-Dateien mit
Größe und SHA-256-Präfix (Anzahl Volume-Archive = Anzahl PVCs aus 4.4),
Ergebnis der Restore-Probe, Ort der Zweitkopie, Nachweis, dass der age-Schlüssel
außerhalb von tmpfs verschlüsselt vorliegt (`ls -l ~/mentolder-ops/mentolder.agekey.age`).
Operator muss mit „Phase 5 starten“ bestätigen.

---

## Phase 5: Knoten neu aufsetzen

### 5.1 Tailnet vorbereiten

Die Knoten hängen heute im Tailnet von Patrick (`p.korczewski@`). Nach dem
Neuaufbau treten sie dem Tailnet `gekko32@github` bei. Dort liegen auch der NUC
und Gekkos Windows-Rechner. Patrick braucht danach eine Freigabe
(Device-Sharing) oder ein eigenes Konto in diesem Tailnet.

Stand 2026-10-20 im Tailnet `gekko32@github`:

- Die Policy definiert keine `tagOwners`. `--advertise-tags=tag:fleet` schlägt
  deshalb fehl.
- Der übergebene Auth-Key ist `ephemeral: true` und ohne Tag. Ephemere Geräte
  verschwinden nach längerer Offline-Zeit aus dem Tailnet. Für Server ist das
  ungeeignet.

`TS_AUTHKEY` und `TS_API_KEY` kommen aus 2.0 (`. "$PLAIN/inputs.secret.env"`).
Der Auth-Key in der Handover-Datei vom 2026-10-20 ist identisch mit
`tailscale-authkey-fleet.txt`. In der Admin-Konsole unter **Settings → Keys**
prüfen, ob er schon reusable, nicht ephemeral und mit `tag:fleet` angelegt ist.
Dann entfallen die Schritte 2 und 3 unten, Schritt 1 (Policy) trotzdem prüfen.

Vorher korrigieren (per API mit `TS_API_KEY` oder in der Admin-Konsole):

1. In der Policy ergänzen: `"tagOwners": {"tag:fleet": ["autogroup:admin"]}`.
2. Neuen Auth-Key anlegen: reusable, **nicht** ephemeral, pre-approved, Tag
   `tag:fleet`. Getaggte Geräte haben keinen Key-Ablauf.
3. Den alten Key `kW8beSCrcC21CNTRL` widerrufen.

```bash
TS_AUTHKEY=$(curl -s -u "$TS_API_KEY:" -X POST https://api.tailscale.com/api/v2/tailnet/-/keys \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":false,"preauthorized":true,"tags":["tag:fleet"]}}},"expirySeconds":7776000,"description":"fleet-nodes"}' | jq -r .key)
case "$TS_AUTHKEY" in tskey-auth-*) echo "neuer Auth-Key gesetzt";; *) echo "FEHLER: kein Key erhalten"; unset TS_AUTHKEY;; esac
sed -i "s|^export TS_AUTHKEY=.*|$(printf 'export TS_AUTHKEY=%q' "$TS_AUTHKEY")|" "$PLAIN/inputs.secret.env"
```

Die alten Einträge `gekko-hetzner-2/3/4` in Patricks Tailnet entfernt Patrick
nach dem Rebuild.

### 5.2 OS frisch

**Variante `rebuild` (Standard):**

```bash
hcloud image list --type system | grep -E 'ubuntu-2[46]\.04'
hcloud server list -o columns=name,ipv4,private_net,status
# Primaer-IPs stehen auf auto_delete=true (Stand 2026-10-20). Rebuild behaelt sie,
# ein versehentliches Loeschen eines Servers wuerde sie aber freigeben. Absichern:
for ip in $(hcloud primary-ip list -o noheader -o columns=id); do hcloud primary-ip update "$ip" --auto-delete=false; done
for n in gekko-hetzner-2 gekko-hetzner-3 gekko-hetzner-4; do hcloud server rebuild "$n" --image "$OS_IMAGE"; done
```

IPs (öffentlich und privat `192.168.200.x`) bleiben bei `rebuild` erhalten, DNS
bleibt unverändert. Root-Zugang danach: Hetzner hinterlegt die SSH-Keys aus der
Servererstellung. Ob `gekko_ed25519` dazugehört, zeigt
`hcloud ssh-key list`. Klappt `ssh -i ~/.ssh/gekko_ed25519 root@<ip>` nicht:
`hcloud server reset-password <name>`, einmalig per Passwort anmelden und den
Schlüssel in `/root/.ssh/authorized_keys` eintragen.

**Variante `wipe`** (nur über die bestehende SSH-Verbindung als `gekko`, kein
Hetzner-Token): pro Knoten
`sudo /usr/local/bin/k3s-uninstall.sh && sudo rm -rf /var/lib/rancher /etc/rancher`,
dann `sudo apt-get update && sudo apt-get -y full-upgrade` und optional
`sudo do-release-upgrade` auf 26.04. In 5.3 dann `ssh gekko-hetzner-N/gekko sudo bash -s`
statt `root@<ip>`. Die Unterschiede zu `rebuild`:

- Kein sauberes OS. Reste wie alte Pakete, das WireGuard-Mesh und Konfigurationen
  von Hand bleiben liegen.
- Ein Release-Upgrade auf entfernten Servern kann hängen bleiben.
- Sperrt eine Firewall-Regel SSH aus, gibt es ohne Hetzner-Zugang keine Rettung
  (Rescue-System oder Konsole).

Mit Hetzner-Token ist jeder Fehler über die Konsole reparierbar. Deshalb
bleibt `rebuild` der Standard.

### 5.3 Grundprovisionierung pro Knoten

Neue Host-Keys: vorher `for ip in 178.104.169.206 46.225.125.59 178.104.159.79; do ssh-keygen -R "$ip"; done`
(in WSL und auf Windows).

Als root über SSH, idempotent. Grundlage ist
`scripts/hetzner/cloud-init-server.yaml.tmpl` (vendored aus Bachelorprojekt),
um diese Punkte ergänzt:

```bash
. "$PLAIN/inputs.secret.env"
[ -n "${TS_AUTHKEY:-}" ] || { echo "TS_AUTHKEY fehlt, zuerst 2.0 und 5.1"; exit 1; }
provision() {  # $1=name $2=private-ip $3=public-ip
ssh -o StrictHostKeyChecking=accept-new root@"$3" bash -s <<EOF
set -euo pipefail
hostnamectl set-hostname $1
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades ufw fail2ban curl jq open-iscsi nfs-common
dpkg-reconfigure -f noninteractive unattended-upgrades
# Benutzer gekko
id gekko 2>/dev/null || useradd -m -s /bin/bash -G sudo gekko
passwd -l gekko
echo 'gekko ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-gekko && chmod 440 /etc/sudoers.d/90-gekko
install -d -m700 -o gekko -g gekko /home/gekko/.ssh
echo '$(cat ~/.ssh/gekko_ed25519.pub)' > /home/gekko/.ssh/authorized_keys
chown gekko:gekko /home/gekko/.ssh/authorized_keys; chmod 600 /home/gekko/.ssh/authorized_keys
# SSH nur mit Schluessel, kein root
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'X'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X
# Kernel/sysctl fuer k3s
printf 'net.ipv4.ip_forward=1\nnet.bridge.bridge-nf-call-iptables=1\nfs.inotify.max_user_instances=8192\nfs.inotify.max_user_watches=1048576\n' > /etc/sysctl.d/99-k3s.conf
modprobe br_netfilter; echo br_netfilter > /etc/modules-load.d/k3s.conf; sysctl --system >/dev/null
# Firewall: oeffentlich 22 (limit), 80, 443, TURN; Clusterports nur privat/Tailnet
ufw --force reset; ufw default deny incoming; ufw default allow outgoing
ufw limit 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
ufw allow 3478; ufw allow 5349; ufw allow 49152:65535/udp comment 'TURN relay'
ufw allow from 192.168.200.0/24
ufw allow in on tailscale0
ufw allow from 10.42.0.0/16; ufw allow from 10.43.0.0/16
ufw --force enable
# Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --auth-key='$TS_AUTHKEY' --hostname=$1 --advertise-tags=tag:fleet --ssh --accept-routes=false
systemctl reload ssh
EOF
}
provision gekko-hetzner-2 192.168.200.2 178.104.169.206
provision gekko-hetzner-3 192.168.200.3 46.225.125.59
provision gekko-hetzner-4 192.168.200.4 178.104.159.79
```

Die TURN-Ports vor dem Einsatz mit dem coturn-Overlay abgleichen
(`prod-fleet/coturn/`). Nur coturn-Knoten brauchen den Relay-Bereich.
Verifikation: `ssh gekko-hetzner-$h/gekko 'sudo -n true && tailscale ip -4 && ufw status | head -5'`.

### 5.4 k3s (HA, embedded etcd, aktuelle stabile Version)

```bash
K3S_VERSION=$(curl -fsSL https://update.k3s.io/v1-release/channels | jq -r '.data[]|select(.id=="stable").latest')
# Token aus der Handover-Datei (ops/k3s), sonst neu erzeugen
K3S_TOKEN=$(jq -r '.items[]|select(.name=="ops/k3s").fields[0].value' "$PLAIN/handover.json" 2>/dev/null || true)
[ -n "$K3S_TOKEN" ] || { K3S_TOKEN=$(openssl rand -hex 32); echo "K3S_TOKEN=$K3S_TOKEN" >> "$PLAIN/generated.env"; }
k3s_cfg() {  # $1=name $2=private-ip $3=public-ip $4=init|join
TSIP=$(ssh "$1/gekko" tailscale ip -4)
cat <<EOF
node-ip: "$2"
flannel-iface: enp7s0
tls-san: ["$1", "$2", "$3", "$TSIP"]
secrets-encryption: true
write-kubeconfig-mode: "0600"
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 20
kube-apiserver-arg: ["audit-log-path=/var/log/k3s-audit.log","audit-log-maxage=14"]
$( [ "$4" = init ] && echo 'cluster-init: true' || echo 'server: "https://192.168.200.2:6443"' )
EOF
}
for spec in "gekko-hetzner-2 192.168.200.2 178.104.169.206 init" \
            "gekko-hetzner-3 192.168.200.3 46.225.125.59 join" \
            "gekko-hetzner-4 192.168.200.4 178.104.159.79 join"; do
  set -- $spec
  k3s_cfg "$@" | ssh "$1/gekko" 'sudo install -D -m600 /dev/stdin /etc/rancher/k3s/config.yaml'
  ssh "$1/gekko" "curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION='$K3S_VERSION' K3S_TOKEN='$K3S_TOKEN' sh -s - server"
  ssh "$1/gekko" 'sudo k3s kubectl wait --for=condition=Ready node/$(hostname) --timeout=300s'
done
ssh gekko-hetzner-2/gekko 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed 's#https://127.0.0.1:6443#https://gekko-hetzner-2:6443#' > ~/.kube/fleet
chmod 600 ~/.kube/fleet; echo ~/.kube/fleet > ~/mentolder-ops/kubeconfig.current; . ~/mentolder-ops/env.sh
kubectl get nodes -o wide
```

Die Interface-Bezeichnung `enp7s0` vorher prüfen (`ip -br a`), sie kann sich mit
dem OS-Image ändern. Die `disable:`-Liste aus dem vendored Template übernehmen,
falls dort Komponenten abgeschaltet sind. Traefik bleibt aktiv (k3s-HelmChart,
wie im Altcluster).

Erwartung: drei Knoten `Ready`, Rollen `control-plane,etcd`, Version =
`$K3S_VERSION`.

### 5.5 Automatische k3s-Updates (empfohlen)

`system-upgrade-controller` installieren und einen `Plan` auf den `stable`-Kanal
setzen (Concurrency 1, `cordon: true`). Manifest-Quelle:
`https://github.com/rancher/system-upgrade-controller/releases/latest`. Als eigene
Kustomization `platform-upgrades` in `flux/clusters/fleet/` ablegen, nicht von
Hand anwenden.

### 5.6 NUC

| `NUC_ROLE` | Bedeutung | Bewertung |
|---|---|---|
| `dev-node` | lokaler Entwicklungsrechner, kein Clustermitglied, kein Backup-Ziel | Zweitkopie der Backups (4.5) dann auf ein Windows-Laufwerk des Ausführungsrechners (die Dateien sind age-verschlüsselt) und zusätzlich die nächtlichen Filen-Backups prüfen |
| `backup` (empfohlen) | Off-site-Ziel für Backups (restic oder rsync über SSH/Tailnet), kein Clustermitglied | passt zu ADR-014 (Flannel über das private Hetzner-Netz) |
| `agent` | k3s-Agent, z. B. für KI-Dienste | Der NUC erreicht `192.168.200.0/24` nicht. Dafür müssten **alle** Knoten auf Flannel über Tailscale umstellen (k3s `vpn-auth: name=tailscale,joinKey=…`), mit höherer Latenz für etcd und Pod-Traffic. Erst nach eigener Entscheidung. |

Bei `backup`: auf dem NUC `tailscale up`, Verzeichnis `/srv/mentolder-backup`
(Besitzer `gekko`), danach in Phase 6.6 die Backup-CronJobs zusätzlich dorthin
schreiben lassen oder einen nächtlichen Pull vom NUC aus einrichten.

`GATE`: Knotenstatus vorlegen.

---

## Phase 6: Flux-Bootstrap, Restore, Abnahme

### 6.1 Secrets vorab anwenden (außerhalb von Flux)

Namespaces anlegen und alle Secrets aus Phase 2 einspielen, **bevor** Flux die
Workloads und Certificates anlegt. Vorher die Passwörter `KC_USER1`/`KC_USER2`
tauschen (Block am Ende von [6.8](#68-restbezüge-zu-patrick-lösen)):

Die GHCR-Pull-Secrets im Handover (`ghcr-pull-secret` in `workspace`, `website`,
`workspace-office`, `ghcr-auth` in `flux-system`) laufen auf **Patricks**
GitHub-Token. Vorher durch einen Token von `gekko32` ersetzen (klassischer PAT,
nur Scope `read:packages`, auf github.com als `gekko32` anlegen). Gebraucht wird
er nur für das private `downloads-content`, die Deployments verweisen aber in
allen drei Namespaces auf das Secret:

```bash
read -rsp 'GHCR-Token von gekko32 (read:packages): ' GHCR_TOKEN < /dev/tty; echo
for ns in workspace website workspace-office; do
  kubectl create secret docker-registry ghcr-pull-secret -n "$ns" --docker-server=ghcr.io \
    --docker-username=gekko32 --docker-password="$GHCR_TOKEN" --dry-run=client -o json > "$PLAIN/secrets/${ns}__ghcr-pull-secret.json"
done
rm -f "$PLAIN/secrets/flux-system__ghcr-auth.json"   # OCI-Artefakt ist oeffentlich
unset GHCR_TOKEN
```

Dann einspielen:

```bash
for ns in $(for f in "$PLAIN"/secrets/*.json; do jq -r .metadata.namespace "$f"; done | sort -u); do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
for f in "$PLAIN"/secrets/*.json; do kubectl apply --server-side --field-manager=bootstrap -f "$f"; done
kubectl create secret generic sops-age -n flux-system --from-file=age.agekey="$PLAIN/mentolder.agekey" --dry-run=client -o yaml | kubectl apply -f -
```

Die Namespaces einzeln anlegen: `xargs` mit mehreren `-o yaml`-Ausgaben ergibt
YAML ohne `---`-Trenner, und `kubectl apply` legt dann nur einen Namespace an.

Secrets für `flux-system` aus dem Altcluster (`ghcr-auth`,
`flux-operator-entitlement`, `gekko-mentolder-*`) nur übernehmen, wenn das neue
Layout sie braucht. Bei öffentlichen Paketen entfällt `ghcr-auth`. Die
Git-Signaturprüfung braucht das Secret mit Gekkos öffentlichem GPG-Schlüssel
(`gekko-mentolder-git-verify`, im neuen Layout unter dem Namen, den
`flux/clusters/fleet/` referenziert).

### 6.2 Flux

```bash
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator -n flux-system --create-namespace
kubectl apply -f ~/mentolder-ops/prod/flux/clusters/fleet/flux-instance.yaml
```

Der PR aus Phase 3 muss dafür **jetzt gemergt** sein, weil die FluxInstance
`main` liest. `GATE` vor dem Merge. Danach Render-Workflow abwarten
(`gh run watch` auf `render.yml`) und prüfen:

```bash
flux get sources all -A
flux get kustomizations -A
```

### 6.3 Restore-Fenster öffnen

Sobald `shared-db` läuft:

```bash
flux suspend kustomization mentolder-prod mentolder-prod-website -n flux-system
for d in $(kubectl -n workspace get deploy -o name | grep -v '/shared-db$'); do kubectl -n workspace scale "$d" --replicas=0; done
kubectl -n workspace get cronjob -o name | xargs -r -n1 kubectl -n workspace patch --type merge -p '{"spec":{"suspend":true}}'
```

### 6.4 Datenbank zurückspielen

```bash
age -d -i "$PLAIN/mentolder.agekey" "$B/shared-db.sql.zst.age" | zstd -dc \
  | kubectl -n workspace exec -i deploy/shared-db -- sh -c 'psql -U "${POSTGRES_USER:-postgres}" -v ON_ERROR_STOP=0 -f -' > /dev/null 2> "$PLAIN/restore.err"
grep -v -E 'already exists|current user cannot be dropped' "$PLAIN/restore.err" | head -20
kubectl -n workspace exec deploy/shared-db -- sh -c 'psql -U "${POSTGRES_USER:-postgres}" -Atc "select datname, pg_database_size(datname) from pg_database where not datistemplate"'
```

Mit `db-sizes.txt` vergleichen. Liegt die neue Postgres-Major-Version über der
alten, ist der logische Dump der richtige Weg. Die Rohkopie von
`shared-db-pvc` ist nur Rückfallebene bei gleicher Version.

### 6.5 Volumes zurückspielen

Pro PVC einen Hilfs-Pod starten, Inhalt leeren, Archiv entpacken. Damit spielt
es keine Rolle, auf welchem Knoten local-path das neue Volume anlegt.

```bash
restore_pvc() {  # $1=namespace $2=pvc
kubectl -n "$1" run "restore-$2" --restart=Never --image=debian:stable-slim --overrides="{\"spec\":{\"containers\":[{\"name\":\"r\",\"image\":\"debian:stable-slim\",\"command\":[\"sleep\",\"86400\"],\"volumeMounts\":[{\"name\":\"d\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"d\",\"persistentVolumeClaim\":{\"claimName\":\"$2\"}}]}}"
kubectl -n "$1" wait --for=condition=Ready "pod/restore-$2" --timeout=180s
kubectl -n "$1" exec "restore-$2" -- sh -c 'find /data -mindepth 1 -delete'
age -d -i "$PLAIN/mentolder.agekey" "$B/${1}__${2}.tar.zst.age" | zstd -dc | pv -N "$2" \
  | kubectl -n "$1" exec -i "restore-$2" -- tar --numeric-owner --xattrs --acls -xpf - -C /data
kubectl -n "$1" exec "restore-$2" -- du -sh /data
kubectl -n "$1" delete pod "restore-$2" --wait
}
for p in nextcloud-app nextcloud-data-pvc pocket-id-data brain-data fuehrungsfunk-daten backup-pvc; do restore_pvc workspace "$p"; done
```

Größen mit `inventory/disk.txt` vergleichen. Das Hilfs-Image ist
`debian:stable-slim`, weil dessen GNU-tar die beim Backup gesetzten Optionen
(`--numeric-owner --xattrs --acls`) versteht. Busybox-tar aus Alpine verliert
sie, dann stimmen z. B. die Besitzrechte von Nextcloud (uid 33) nicht.
Stichprobe: `kubectl -n workspace exec deploy/nextcloud -- stat -c '%u %n' /var/www/html/config/config.php`
muss nach 6.6 `33` zeigen.

### 6.6 Hochfahren

```bash
kubectl -n workspace get cronjob -o name | xargs -r -n1 kubectl -n workspace patch --type merge -p '{"spec":{"suspend":false}}'
flux resume kustomization mentolder-prod mentolder-prod-website -n flux-system
flux get kustomizations -A --status-selector ready=false
kubectl -n workspace get deploy
```

Flux setzt die Replikazahlen aus Git wieder ein. Abgleich mit
`replicas-before.txt`: Abweichungen dürfen nur die optionalen Dienste betreffen.

Nextcloud nach dem Start: `kubectl -n workspace exec deploy/nextcloud -- su -s /bin/sh www-data -c "php occ maintenance:mode --off; php occ upgrade; php occ db:add-missing-indices; php occ files:scan --all"`.
Einen manuellen Lauf beider Backup-CronJobs anstoßen
(`kubectl -n workspace create job --from=cronjob/db-backup db-backup-manual`, dito
`pvc-backup`) und auf Erfolg prüfen.

### 6.7 Abnahme

Alle Prüfungen protokollieren. Erwartung jeweils HTTP 200/302 und gültiges
Zertifikat:

```bash
for h in web.mentolder.de auth.mentolder.de files.mentolder.de brett.mentolder.de brain.mentolder.de \
         studio.mentolder.de sessions.mentolder.de react.mentolder.de funk.mentolder.de traefik.mentolder.de; do
  printf '%-28s ' "$h"; curl -s -o /dev/null -w '%{http_code} ' "https://$h/"; \
  echo | openssl s_client -servername "$h" -connect "$h:443" 2>/dev/null | openssl x509 -noout -enddate
done
curl -s https://files.mentolder.de/status.php | jq '{installed,maintenance,versionstring}'
kubectl get certificates -A
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Manuell durch den Operator:

| ID | Prüfung |
|---|---|
| A1 | Login über Pocket ID (`auth.mentolder.de`) mit Bestandskonto, Weiterleitung zu Website und Nextcloud |
| A2 | Nextcloud: vorhandene Dateien sichtbar, Upload funktioniert |
| A3 | Talk-Anruf zwischen zwei Geräten (Signaling und coturn) |
| A4 | Website: Buchung/Kontaktformular sendet Mail (SMTP) |
| A5 | brett, brain, studio, Führungsfunk: Login und Bestandsdaten |
| A6 | Collabora öffnet ein Dokument aus Nextcloud |
| A7 | RustDesk-Relay erreichbar |
| A8 | Grafana-Login per OIDC, Alertmanager sendet Testalarm an `BACKUP_ALERT_EMAIL` |

`GATE`: Ergebnis A1 bis A8. Bei Fehlern: Phase 6 erneut ab 6.3 oder Rückbau
(siehe [Rückbau](#rückbau)).

---

### 6.8 Restbezüge zu Patrick lösen

Ziel: Der neue Cluster hängt an keinem Konto und keiner Identität von Patrick.
Stand der Analyse 2026-10-21 (Altcluster):

| Bezug | heute | Maßnahme |
|---|---|---|
| Tailnet | Knoten im Tailnet `p.korczewski@` | erledigt mit 5.1 (Tailnet `gekko32@github`) |
| ACME-Konto | ClusterIssuer `letsencrypt-prod` mit E-Mail `noreply-bachelorprojekt@mailbox.org` | erledigt in PR #20: E-Mail `quamain@web.de` (Gekko). Secret `letsencrypt-prod-key` **nicht** übernehmen (neuer Account-Key) |
| DNS-01 | Webhook `lego-solver`, Provider ipv64, Secret `ipv64-api-key` | **bewusst beibehalten** (Entscheidung Patrick, 2026-10-21): Die Zone `mentolder.de` bleibt in Patricks ipv64-Konto und wird dort gepflegt. Folge: Zertifikatserneuerung hängt an Patricks API-Key. Rotiert Patrick ihn, bekommt Gekko den neuen Wert für `ipv64-api-key` (Namespaces `workspace` und `cert-manager`) |
| Identität | `KC_USER1_EMAIL=patrick@korczewski.de`, oauth2-proxy `allowed-emails=patrick@korczewski.de`, Pocket-ID-Bootstrap-Admin `paddione` | erledigt in PR #20: `KC_USER1` = `gekko`/`quamain@web.de`, `KC_USER2` = `paddione`/`patrick@korczewski.de`. Die Passwörter mittauschen, siehe unten. Bootstrap-Admin auf Gekko umstellen |
| Datenbanken | Schemas/Skripte `bachelorprojekt`, `meetings` in `shared-db`; Repo-Embeddings aus `k1-embed` | beim Restore (6.4) nur mentolder-Daten zurückspielen; Embeddings-Tabellen von Bachelorprojekt nicht übernehmen |
| Dev-Tools | `brain`, `sessions-server`, `oauth2-proxy-session-hub` | in PR #20 entfernt, ziehen nach devmesh |
| Cluster-Zugang | Patricks Bachelorprojekt-CI hat ein Secret `FLEET_KUBECONFIG` für den **heutigen** fleet-Cluster (Gekkos Knoten), dazu die Cloud-Umgebung „mentolder-prod“ (`scripts/cloud-env/`) | Der Rebuild macht beide wertlos (neue Cluster-CA). Die neue Kubeconfig (`~/.kube/fleet`) bekommt nur Gekko. Patrick löscht die toten Secrets in Phase 9 |
| Node-Setup | `prod/cloud-init.yaml` lädt Skripte von `Paddione/Bachelorprojekt/main` | Skripte vendoren oder Zeilen entfernen, vor 5.3 |
| Image-Pulls | `ghcr-pull-secret`/`ghcr-auth` mit Patricks GitHub-Token | erledigt in 6.1: ersetzt durch einen `read:packages`-Token von `gekko32`, `ghcr-auth` entfällt |
| Review | `CODEOWNERS` nennt `@Paddione @gekko32` | **bewusst beibehalten**: gemeinsames Review, Gekko ist auf allen Pfaden eingetragen |

Passwörter zum Benutzertausch (`KC_USER1`/`KC_USER2`): Vor 6.1 in der
Secret-Datei tauschen, damit jedes Passwort beim richtigen Benutzer bleibt:

```bash
f="$PLAIN/secrets/workspace__workspace-secrets.json"
jq '.data |= (.KC_USER1_PASSWORD as $a | .KC_USER1_PASSWORD = .KC_USER2_PASSWORD | .KC_USER2_PASSWORD = $a)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
```

`GATE`: Operator bestätigt jede Zeile als erledigt oder bewusst beibehalten.
Prüfung:

```bash
flux get sources all -A | grep -i paddione            # leer
kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.spec.acme.email}'   # Gekkos Adresse
kubectl -n workspace get cm -o yaml | grep -ci 'korczewski'                    # 0 oder bewusst beibehalten
```

## Phase 7: Optionale Dienste

### 7.1 Kandidaten

Heute mit `replicas: 0` (Runbook `docs/runbooks/ai-services-scale-zero.md`):

| Dienst | Requests | Limits | Zusatz | Abhängigkeit |
|---|---|---|---|---|
| `whisper` | 2 CPU, 4 Gi | 8 CPU, 8 Gi | Modell-Download beim Start | zusammen mit `talk-transcriber` |
| `talk-transcriber` | 250m, 512 Mi | 2 CPU, 2 Gi | | `whisper` |
| `talk-recording` | 50m, 1 Gi | 4 CPU, 4 Gi | | Nextcloud Talk |
| `bge-embed` | 1 CPU, 1 Gi | 2 CPU, 4 Gi | PVC 2 Gi | |
| `bge-embed-bulk` | 1 CPU, 1 Gi | 2 CPU, 4 Gi | teilt Modell-PVC | |
| `bge-rerank` | 1 CPU, 1 Gi | 2 CPU, 2 Gi | PVC 2 Gi | |

### 7.2 Passung neu berechnen

Nach Phase 6 auf dem frischen Cluster messen, nicht die Altwerte übernehmen:

```bash
kubectl top nodes
kubectl get nodes -o json | jq -r '.items[]|"\(.metadata.name)\t\(.status.allocatable.cpu)\t\(.status.allocatable.memory)"'
kubectl describe nodes | grep -A5 'Allocated resources'
for h in 2 3 4; do ssh gekko-hetzner-$h/gekko 'echo "$(hostname) $(df -h / | awk "NR==2{print \$4}") frei"'; done
```

Bewertungsregel pro Dienst und Knoten:

- **passt**, wenn `allocatable − Summe Requests ≥ Request des Dienstes` **und**
  `allocatable − tatsächliche Nutzung ≥ 1,5 × Request` **und** freier Platz ≥
  PVC + 5 Gi.
- **knapp**, wenn nur die erste Bedingung erfüllt ist (Scheduler nimmt den Pod an,
  unter Last drohen OOM-Kill oder Eviction).
- **passt nicht** sonst.

### 7.3 Schätzung mit Altcluster-Werten (2026-10-20)

Knoten: je 4 vCPU, ca. 7,5 Gi allocatable. Requests 1,6/1,6/2,4 Gi,
tatsächliche Nutzung 4,6/3,8/4,6 Gi, Platte frei 13/13/27 GB.

| Dienst | Einschätzung |
|---|---|
| `bge-rerank` | passt (ein Knoten) |
| `bge-embed` | passt (ein Knoten) |
| `talk-recording` | passt, solange keine parallelen Aufnahmen laufen |
| `bge-embed-bulk` | knapp, nur zusätzlich zu `bge-embed`, wenn Bulk-Läufe nötig sind |
| `whisper` + `talk-transcriber` | knapp bis passt nicht: 4,5 Gi Request gegen ca. 3,7 Gi real freien RAM auf dem besten Knoten. Erst nach Upgrade eines Knotens auf 16 GB (z. B. Hetzner CX42/CPX41) oder mit `NUC_ROLE=agent` |
| alle gleichzeitig | passt nicht (8,5 Gi und 5,3 CPU Requests, Limits 24 Gi) |

Der frische Cluster braucht ohne Longhorn-Reste und Altlasten
erfahrungsgemäß weniger. Deshalb die Berechnung aus 7.2 maßgeblich machen.

### 7.4 Aktivieren

`GATE`: Tabelle aus 7.2 vorlegen, Operator wählt Dienste.
Aktivierung nur per PR: in `prod-fleet/mentolder/kustomization.yaml` unter
`replicas` `count: 0 → 1`. Nach dem Merge Readiness abwarten und für jeden
aktivierten Dienst `kubectl top pod` nach 15 Minuten Last festhalten.

---

### 7.5 Vaultwarden (Pflicht vor Phase 8)

Vaultwarden wurde mit T016559 aus fleet entfernt (Delete-Patches in
`prod-fleet/mentolder/kustomization.yaml`). Die Datenbank `vaultwarden`
(ca. 11 MB) liegt aber noch in `shared-db` und kommt mit dem Restore aus 6.4
zurück, samt der Konten darin. Die Secrets `VAULTWARDEN_DB_PASSWORD`,
`VAULTWARDEN_ADMIN_TOKEN` und `POCKET_ID_VAULTWARDEN_SECRET` sind in
`workspace-secrets` vorhanden.

Aktivieren per PR: die Delete-Patches für `vaultwarden` (Deployment, Service,
PVC `vaultwarden-data-pvc`, Ingress `workspace-ingress-vault`, NetworkPolicy,
Middleware) entfernen. Ressourcen: ca. 50m CPU und 128 Mi RAM, passt auf jeden
Knoten. Danach `https://vault.mentolder.de` prüfen und mit Gekkos Konto
anmelden. Existiert kein Konto, eines anlegen (Signups über `ADMIN_TOKEN` unter
`/admin` erlauben, danach wieder sperren).

## Phase 8: Vaultwarden, SOPS, Klartext vernichten

Erst nach bestandener Abnahme (Phase 6.7) und mit laufendem Vaultwarden (7.5).

**Mit Handover-Datei:** statt der Schleife in 8.1 die Datei direkt importieren
und danach nur die Gegenprobe ausführen:

```bash
bw import bitwardenjson "$PLAIN/handover.json"
```

Der Import legt den Ordner `mentolder-prod` an. Dann
`FOLDER=$(bw list folders | jq -r '.[]|select(.name=="mentolder-prod").id')`
setzen. Neu erzeugte Werte aus Phase 2.4 und 5.4 zusätzlich als
`mentolder-prod/generated` anlegen.

### 8.1 Nach Vaultwarden schreiben

```bash
bw config server "$VW_URL"
bw login "$VW_EMAIL"            # Operator gibt Master-Passwort und 2FA selbst ein
export BW_SESSION=$(bw unlock --raw)
bw sync
FOLDER=$(bw get template folder | jq --arg n "mentolder-prod/$(date +%F)" '.name=$n' | bw encode | bw create folder | jq -r .id)
```

Pro Kubernetes-Secret ein Eintrag vom Typ Secure Note:

- Name: `<namespace>/<secret-name>`.
- Pro Schlüssel ein verstecktes benutzerdefiniertes Feld (Typ 1).
- Werte über 5000 Zeichen (Zertifikate, Kubeconfig) als Anhang statt als Feld.

```bash
for f in "$PLAIN"/secrets/*.json; do
  name=$(jq -r '.metadata.namespace+"/"+.metadata.name' "$f")
  bw get template item | jq --arg n "$name" --arg fid "$FOLDER" --slurpfile s "$f" '
    .type=2 | .secureNote={type:0} | .name=$n | .folderId=$fid | .notes="mentolder-prod, Kubernetes Secret" |
    .fields=[$s[0].data|to_entries[]|{name:.key,value:(.value|@base64d),type:1}|select((.value|length)<5000)]' \
  | bw encode | bw create item > /dev/null
done
```

Zusätzliche Einträge (eigene Notes):

- `mentolder-prod/sops-age-key`: Inhalt von `$PLAIN/mentolder.agekey`. Das ist der
  wichtigste Eintrag. Ohne ihn sind die Repo-Secrets verloren.
- `mentolder-prod/k3s`: `K3S_TOKEN`, Kubeconfig als Anhang.
- `mentolder-prod/generated`: alle Werte aus `$PLAIN/generated.env`.
- `mentolder-prod/backup-passphrase`: Passphrase von `mentolder.agekey.age`, falls
  vergeben.

Gegenprobe ohne Werte auszugeben:

```bash
bw sync
bw list items --folderid "$FOLDER" | jq length
ls "$PLAIN/secrets" | wc -l
# Stichprobe: Hash jedes Feldes gegen die Quelle
for f in "$PLAIN"/secrets/*.json; do
  name=$(jq -r '.metadata.namespace+"/"+.metadata.name' "$f")
  a=$(jq -r '.data|to_entries|map(select((.value|@base64d|length)<5000))|map(.key+"="+(.value|@base64d))|sort|join("\n")' "$f" | sha256sum | cut -c1-8)
  b=$(bw list items --folderid "$FOLDER" --search "$name" | jq -r --arg n "$name" '.[]|select(.name==$n)|.fields|map(.name+"="+.value)|sort|join("\n")' | sha256sum | cut -c1-8)
  [ "$a" = "$b" ] || echo "ABWEICHUNG $name"
done
```

Erwartung: Anzahl Einträge = Anzahl Dateien + Zusatzeinträge, keine
`ABWEICHUNG`.

### 8.2 SOPS-Dateien erzeugen und Flux übergeben

```bash
cd ~/mentolder-ops/prod && git switch -c gekko/sops-secrets
for f in "$PLAIN"/secrets/*.json; do
  ns=$(jq -r .metadata.namespace "$f"); n=$(jq -r .metadata.name "$f")
  mkdir -p "secrets/$ns"
  yq -P '.' "$f" > "secrets/$ns/$n.sops.yaml"
  sops --encrypt --in-place "secrets/$ns/$n.sops.yaml"
done
(cd secrets && find . -name '*.sops.yaml' | sort | sed 's#^\./#  - #' | { echo 'apiVersion: kustomize.config.k8s.io/v1beta1'; echo 'kind: Kustomization'; echo 'resources:'; cat; } > kustomization.yaml)
# Pruefung: jede Datei verschluesselt, Entschluesselung klappt
if grep -rL '^sops:' secrets --include='*.sops.yaml' | grep -q .; then echo "UNVERSCHLUESSELT gefunden"; else echo "alle verschluesselt"; fi
sops --decrypt secrets/workspace/workspace-secrets.sops.yaml | yq '.data|keys|length'
```

Zusätzlich prüfen, dass kein Wert im Klartext im Arbeitsbaum steht (die
Base64-Werte dürfen nicht vorkommen):

```bash
jq -r '.data[]' "$PLAIN"/secrets/*.json | awk 'length>=12' > "$PLAIN/needles.txt"
git add secrets .sops.yaml && git grep --cached -l -F -f "$PLAIN/needles.txt" && echo "KLARTEXT IM INDEX" || echo "sauber"
```

PR öffnen, nach Review mergen. Danach:

```bash
flux reconcile kustomization mentolder-secrets -n flux-system --with-source
kubectl get secrets -A -l kustomize.toolkit.fluxcd.io/name=mentolder-secrets | wc -l
flux get kustomizations -A
```

Erwartung: Flux hat alle Secrets übernommen, keine Kustomization `False`, keine
Pod-Neustarts außer bei geänderten Werten (`kubectl get pods -A` vergleichen).

### 8.3 Klartext vernichten

```bash
find "$PLAIN" -type f -exec shred -u {} +
rmdir "$PLAIN"
rm -f ~/mentolder-ops/inputs.secret.env
bw lock; unset BW_SESSION
```

Handover-Datei vernichten (die Werte liegen jetzt in Vaultwarden):
`shred -u ~/mentolder-ops/handover.json.age /mnt/c/<pfad>/mentolder-handover-*.json.age 2>/dev/null`.

Bleiben dürfen: die age-verschlüsselten Backups und `mentolder.agekey.age`
(Passphrase in Vaultwarden). Die Backups nach 30 Tagen löschen, sofern der neue
Cluster stabil läuft und die nächtlichen Backups grün sind.

### 8.4 Rotation offener Altlasten

- Den GitHub-PAT (`GH_PAT`), der im Oktober 2026 im Chat sichtbar war, widerrufen.
  Er wird im neuen Layout nicht mehr gebraucht, weil der Render mit
  `GITHUB_TOKEN` läuft.
- `ghcr-auth`/`ghcr-pull-secret` löschen, sobald alle Pakete öffentlich sind.
- Das alte `K3S_TOKEN` ist mit dem Rebuild wertlos, nichts zu tun.

`GATE`: Abschlussbericht für Phase 8.

---

## Phase 9: Bachelorprojekt bereinigen

Erst wenn der neue Cluster **7 Tage** ohne Störung läuft und
`flux get sources all -A` keine URL mit `Paddione` mehr zeigt.

Diese Phase ändert `Paddione/Bachelorprojekt`. Patrick führt sie aus oder gibt
sie ausdrücklich frei, als Chore-PR im **Draft**. Auto-Merge mergt dort
Nicht-Drafts sofort.

### 9.1 Inventar erzeugen

```bash
cd ~/mentolder-ops/upstream && git switch main && git pull -q
git grep -l -i -E 'mentolder|fleet-gekko|gekko-hetzner' -- \
  ':!website/src' ':!apps' ':!packages' ':!docs/superpowers' ':!docs/archive' ':!**/node_modules/**' \
  | sort > ~/mentolder-ops/phase9-candidates.txt
wc -l ~/mentolder-ops/phase9-candidates.txt
```

### 9.2 Zu entfernen (Deploy-Pfad mentolder)

| Pfad | Grund |
|---|---|
| `flux/clusters/fleet-gekko/` | Flux-Einstieg des Altclusters inklusive Gekko-Mandant |
| `environments/mentolder.yaml`, `environments/fleet-mentolder.yaml` | Umgebungen liegen jetzt in mentolder-prod |
| `environments/sealed-secrets/fleet-mentolder.yaml`, `environments/certs/fleet-mentolder.pem` | Ersetzt durch SOPS in mentolder-prod |
| `environments/.secrets/fleet-mentolder.yaml`, `environments/.secrets/sealed-secrets-key.fleet.yaml` | git-crypt-Ciphertext ohne Abnehmer. Vorher prüfen, dass Vaultwarden alle Werte hat |
| `prod-mentolder/`, `prod-fleet/mentolder/`, `prod-fleet/website-mentolder/` | Overlays leben in mentolder-prod |
| `prod-fleet/{platform,coturn,office,rustdesk,components,website-common}/` | nur, wenn `git grep` keine devmesh-/korczewski-Referenz zeigt |
| mentolder-Targets in `scripts/flux-render-artifact.sh` und `.github/workflows/render-fleet-artifact.yml` | Render erfolgt in mentolder-prod |
| `scripts/export-mentolder-prod.sh`, `docs/handover/mentolder-gekko/` | Übergabe abgeschlossen |
| `scripts/hetzner/`, `scripts/fleet-dns-cutover.sh`, `scripts/fleet-membership-check.sh` | Knoten-Bootstrap jetzt in mentolder-prod (dieser Runbook) |
| `docs/runbooks/{ssh-zugang-fleet,cloud-env-fleet,ai-services-scale-zero}.md` | Betriebswissen in mentolder-prod |
| `tests/py/spec/fleet/` (mentolder-spezifische Verträge) | testen Artefakte, die es dort nicht mehr gibt |
| Taskfile-Tasks mit `ENV=mentolder` (z. B. `rustdesk:deploy`) | Deploy nicht mehr aus diesem Repo |

### 9.3 Bewusst behalten

- App-Quellcode und Image-Builds für Patricks eigene Umgebungen. mentolder-prod
  baut seit Phase 3.2 selbst und hängt nicht mehr daran.
- Brand-Inhalte unter `website/src` (Inhalt, kein Deploy).
- ADRs (`docs/adr/ADR-001`, `ADR-014` usw.) als Historie, mit einem Hinweis
  „abgelöst durch gekko32/mentolder-prod“.
- E2E-Tests gegen `mentolder.de`: mit Patrick klären (testen Prod, deployen nicht).

### 9.4 Prüfen und PR

Nach dem Entfernen müssen die Suiten grün bleiben:
`task test:changed`, `task workspace:validate`, Render-Workflow für devmesh. Dann
Draft-PR mit Typ `chore(fleet): …`, Freigabe durch Patrick.

`GATE`: Kandidatenliste und Diff-Statistik vorlegen.

---

## Phase 10: Ops-Instanz an Gekko übergeben

Gilt, wenn der Runbook nicht auf Gekkos Rechner lief (z. B. auf dem PK-Tablet).
Ziel: `gekko-ops` läuft 1:1 auf Gekkos Laptop (`DESKTOP-5VFUF9Q`), der
Ausführungsrechner behält nichts Sensibles. Erst nach Phase 8.

### 10.1 Aufräumen in `gekko-ops`

```bash
# kein Klartext mehr vorhanden (tmpfs wird nicht exportiert, trotzdem pruefen)
ls /run/user/$(id -u)/mentolder-plain 2>/dev/null && echo "PLAIN noch da, Phase 8.3 nachholen"
# GitHub-CLI muss als gekko32 angemeldet sein, sonst abmelden
gh auth status 2>&1 | grep -E 'Logged in to github.com account' || true
# verschluesselte Backups auf den NUC, nicht mitgeben
rsync -a ~/mentolder-ops/backup/ nuc/gekko:/srv/mentolder-backup/ && rm -rf ~/mentolder-ops/backup
# Verlauf leeren (enthaelt Hostnamen und Befehle, idealerweise keine Werte)
cat /dev/null > ~/.bash_history; history -c
# Tunnel und Control-Sockets schliessen
pkill -u "$(id -u)" -f 'ssh -f -N' || true; rm -f ~/.ssh/cm-*
```

Ist `gh` mit einem anderen Konto als `gekko32` angemeldet: `gh auth logout`.
Gekko meldet sich nach dem Import selbst an.

`GATE`: Ergebnis vorlegen.

### 10.2 Export (PowerShell auf dem Ausführungsrechner)

```powershell
wsl --shutdown
New-Item -ItemType Directory -Force C:\Transfer | Out-Null
wsl --export gekko-ops C:\Transfer\gekko-ops.tar
Get-Item C:\Transfer\gekko-ops.tar | Select-Object Name, Length
```

Das Archiv enthält den privaten SSH-Schlüssel und eine Cluster-Admin-
Kubeconfig. Nur verschlüsselt transportieren: 7-Zip mit AES-256 und Passwort
(`7z a -p -mhe=on gekko-ops.7z gekko-ops.tar`) oder ein verschlüsselter
USB-Stick. Das Passwort auf einem anderen Weg übergeben als das Archiv.

### 10.3 Import auf Gekkos Laptop

Voraussetzungen auf dem Laptop: WSL ≥ 2.4, `.wslconfig` wie in 0.2
(`networkingMode = Mirrored`), Tailscale angemeldet als `gekko32` (0.3).

```powershell
New-Item -ItemType Directory -Force C:\WSL\gekko-ops | Out-Null
wsl --import gekko-ops C:\WSL\gekko-ops C:\Transfer\gekko-ops.tar --version 2
Remove-Item C:\Transfer\gekko-ops.tar
wsl -d gekko-ops -- bash -lc 'whoami; sudo -n true && echo sudo-ok; kubectl --kubeconfig ~/.kube/fleet get nodes; for h in 2 3 4; do ssh gekko-hetzner-$h/gekko hostname; done; ssh nuc/gekko hostname'
```

`/etc/wsl.conf` bringt Default-User `gekko` und systemd mit. Erwartung:
`gekko`, `sudo-ok`, drei Knoten `Ready`, vier Hostnamen.

Danach auf dem Laptop:

- `gh auth login` als `gekko32`.
- `bw config server https://vault.mentolder.de && bw login`. Den SOPS-Schlüssel
  bei Bedarf aus dem Eintrag `ops/sops-age` holen. Er liegt bewusst nicht in der
  Instanz.
- Optional Claude Code in `gekko-ops` installieren
  (`npm i -g @anthropic-ai/claude-code`).

### 10.4 Ausführungsrechner bereinigen

```powershell
wsl --unregister gekko-ops
Remove-Item C:\Transfer -Recurse -Force
```

Zusätzlich:

- Handover-JSON und Transportkopien mit `shred -u` bzw. „Sicher löschen“ entfernen.
- Den Rechner in der Tailscale-Admin-Konsole aus dem Tailnet `gekko32@github`
  entfernen oder lokal `tailscale switch` zurück auf das eigene Konto und
  `tailscale logout` für das Gekko-Konto.
- Den Eintrag `nuc/gekko` und die `gekko-hetzner-*/gekko`-Einträge in der
  Windows-SSH-Config behalten oder entfernen, je nachdem, ob der Rechner weiter
  Zugriff haben soll.

`GATE`: Abschluss bestätigen.

---

## Rückbau

Bis zum Ende von Phase 6 ist ein Rückbau möglich:

1. Neuen Cluster stoppen (`k3s-uninstall.sh` auf allen Knoten).
2. k3s in der Altversion installieren (`v1.37.1+k3s1`, Stand 2026-10-20) mit dem
   alten Token aus `k3s-token-old.age`.
3. `k3s server --cluster-reset --cluster-reset-restore-path=<etcd-pre-rebuild>`
   auf `gekko-hetzner-2`, dann die anderen Knoten neu joinen.
4. Volumes wie in 6.5 zurückspielen (local-path-Pfade aus `pv-map.tsv`).
5. `flux resume` der in 4.2 suspendierten Kustomizations.

Nach Phase 8 ist der Rückweg nur noch über einen erneuten Restore aus Backup
möglich.

---

## Empfehlungen über den Auftrag hinaus

| ID | Empfehlung | Aufwand |
|---|---|---|
| E1 | etcd-Snapshots zusätzlich nach S3 (Hetzner Object Storage, k3s `etcd-s3`) | gering |
| E2 | `system-upgrade-controller` für k3s (Phase 5.5) und `kured` für Kernel-Reboots nach unattended-upgrades | gering |
| E3 | Backups zusätzlich auf den NUC (Off-site, `NUC_ROLE=backup`) mit monatlicher automatischer Restore-Probe (`db-restore-verify` existiert bereits für die DB) | mittel |
| E4 | Docker-Hub-Images (`fedirz/faster-whisper-server`, `nextcloud/*`) ebenfalls spiegeln, gegen Pull-Limits und verschwundene Tags | gering |
| E5 | Hetzner-Firewall vor ufw: 22 nur von bekannten IPs, 6443/etcd geschlossen | gering |
| E6 | Ein Knoten mit 16 GB RAM, wenn whisper/talk-transcriber dauerhaft laufen sollen (Phase 7.3) | Kosten |
| E7 | Renovate in mentolder-prod für Images, Helm-Charts und k3s-Version | mittel |
| E8 | Zweiter age-Empfänger (z. B. Patrick oder Offline-Schlüssel) in `.sops.yaml`, damit ein verlorener Vaultwarden-Zugang die Secrets nicht unbrauchbar macht | gering |

---

## Anhang A: Ist-Aufnahme 2026-10-20

| Punkt | Wert |
|---|---|
| Knoten | `gekko-hetzner-2/3/4`, Hetzner `cx33` (Netz `gekko-hetzner-ff`, `192.168.200.0/24`), je 4 vCPU, 8 GB RAM, 75 GB Platte, Ubuntu 24.04.5, k3s `v1.37.1+k3s1`, alle `control-plane,etcd` |
| Netz | privat `192.168.200.2–4` auf `enp7s0`, Tailnet `100.104.153.88`, `100.124.142.2`, `100.100.238.102` |
| Plattenplatz frei | 13 / 13 / 27 GB |
| RAM real belegt | 4,6 / 3,8 / 4,6 Gi |
| PVCs (local-path) | `nextcloud-data-pvc` 50 Gi, `shared-db-pvc` 25 Gi, `nextcloud-app` 2 Gi, `pocket-id-data`, `brain-data`, `fuehrungsfunk-daten`, `backup-pvc` je 1 Gi, Monitoring 13 Gi, `bge-*` 4 Gi |
| Flux | `flux-system` aus `Paddione/Bachelorprojekt` (`flux/clusters/fleet-gekko`), `fleet-manifests` aus `ghcr.io/paddione`; Workloads aus `gekko32/mentolder-prod` (Namespace `gekko-mentolder`) |
| Secrets | 20 SealedSecrets; ohne SealedSecret: `fuehrungsfunk`, `ntfy-tokens`, `pentest-internal-vault`, `ipv64-api-key`, `ghcr-pull-secret` (workspace), `letsencrypt-prod-key` |
| Backups | CronJobs `db-backup` (02:00), `pvc-backup` (03:00), `db-restore-verify` (So 03:30), Ziel Filen `/Backup` |
| Hetzner-Projekt | SSH-Keys `patrick@korczewski.de` und `gekko@mentolder-20260513` (= `gekko_ed25519`) hinterlegt, Image `ubuntu-26.04` verfügbar, keine Hetzner-Firewall, keine Volumes, Rebuild-/Delete-Schutz aus |
| SSH | Benutzer `gekko` mit `gekko_ed25519` und sudo ohne Passwort auf allen drei Knoten funktionsfähig, Port 22 öffentlich erreichbar |
