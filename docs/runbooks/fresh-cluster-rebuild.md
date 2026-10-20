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
| I0 | Handover-Datei | `mentolder-handover-<datum>.json` aus `scripts/handover-export.sh` (siehe [Phase 2.0](#20-handover-datei)). Enthält alle Secrets und I1, I2 und I5 | ja |
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

Fehlt es: `winget install --id Tailscale.Tailscale -e`, dann im Tray anmelden
(gleiches Tailnet wie die Knoten). Prüfen: `tailscale status` listet
`gekko-hetzner-2/3/4`.

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
wsl -d gekko-ops -- bash -c "whoami; sudo -n true && echo sudo-ok; systemctl is-system-running || true"
```

Erwartung: `gekko`, `sudo-ok`, `running` oder `degraded`.
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

Danach anmelden: `gh auth login` (I4), `hcloud context create gekko` (I1).

`GATE`: Werkzeugliste und SSH-Verifikation zeigen.

---

## Phase 1: Ist-Aufnahme (nur lesend)

### 1.1 Kubeconfig des Altclusters

```bash
mkdir -p ~/.kube
ssh gekko-hetzner-2/gekko 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's#https://127.0.0.1:6443#https://gekko-hetzner-2:6443#' > ~/.kube/fleet-old
chmod 600 ~/.kube/fleet-old
export KUBECONFIG=~/.kube/fleet-old
kubectl get nodes -o wide
```

`gekko-hetzner-2` muss über das Tailnet (MagicDNS) auflösen. Sonst die
Tailnet-IP aus `tailscale status` einsetzen.

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

Auf dem Ausführungsrechner:

```bash
PLAIN=/run/user/$(id -u)/mentolder-plain; install -d -m700 "$PLAIN"
mv /mnt/c/<pfad>/mentolder-handover-*.json "$PLAIN/handover.json"
bash scripts/handover-to-secrets.sh "$PLAIN/handover.json" "$PLAIN/secrets"
jq -r '.items[]|select(.name=="ops/sops-age").fields[]|select(.name=="SOPS_AGE_KEY").value' "$PLAIN/handover.json" > "$PLAIN/mentolder.agekey"
jq -r '.items[]|select(.name=="ops/sops-age").fields[]|select(.name=="SOPS_AGE_PUBLIC").value' "$PLAIN/handover.json" > ~/mentolder-ops/age.pub
```

Damit sind 2.1 und 2.2 erledigt, weiter mit 2.3. Die Originaldatei auf dem
Transportmedium danach mit `shred -u` vernichten.

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

### 3.2 Images nach `ghcr.io/gekko32` spiegeln

Der GHCR-Namespace entspricht dem GitHub-Account. Also `ghcr.io/gekko32/*`,
nicht `ghcr.io/gekko`.

Image-Liste aus dem Render ableiten, nicht von Hand pflegen:

```bash
kustomize build prod-fleet/mentolder prod-fleet/website-mentolder 2>/dev/null | yq -r '.. | .image? | select(.)' \
  | grep '^ghcr.io/paddione/' | sed 's/@sha256.*//' | sort -u > images-mirror.txt
cat images-mirror.txt
```

Stand 2026-10-20 im Cluster: `collabora-code`, `downloads-content`,
`einvoice-sidecar`, `mcp-node`, `mentolder-web`, `studio-server` und
`talk-transcriber` unter `ghcr.io/paddione/`. `brett`, `website` und
`fuehrungsfunk` liegen schon unter `gekko32`.

Neuer Workflow `.github/workflows/mirror-images.yml`:

- Trigger: `schedule` (stündlich), `workflow_dispatch`, Push auf `images-mirror.txt`.
- `permissions: packages: write, contents: read`.
- Pro Zeile: `crane copy ghcr.io/paddione/<name>:<tag> ghcr.io/gekko32/<name>:<tag>`
  für `latest` und den Tag des aktuell gerenderten Digests. `crane copy` erhält
  den Digest, cosign-Signaturen gegebenenfalls zusätzlich kopieren
  (`cosign copy`).
- Danach `render.yml` per `workflow_dispatch` anstoßen, falls sich ein Digest
  geändert hat.

Im Overlay alle `ghcr.io/paddione/*` per Kustomize-`images:` auf
`ghcr.io/gekko32/*` umschreiben. Verifikation:
`kustomize build … | grep -c 'ghcr.io/paddione'` muss `0` ergeben.

**Manueller Schritt (GitHub-UI, keine API):** Jedes neue Paket ist zunächst
privat. Für jedes Paket unter
`https://github.com/users/gekko32/packages/container/<name>/settings` die
Sichtbarkeit auf **Public** setzen. Danach entfallen `ghcr-pull-secret` und
`ghcr-auth` im neuen Cluster.

`GATE`: Operator bestätigt, dass alle Pakete öffentlich sind
(`crane manifest ghcr.io/gekko32/<name>:latest` ohne Login für jede Zeile).

Restabhängigkeit: Neue App-Versionen entstehen weiter in der CI von
`Paddione/Bachelorprojekt` (`ghcr.io/paddione/*`). Der Mirror kopiert sie nur.
Phase 9 darf die App-Builds deshalb nicht entfernen.

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
B=~/mentolder-ops/backup/$(date +%F); mkdir -p "$B"; R=$(cat ~/mentolder-ops/age.pub)
kubectl -n workspace exec deploy/shared-db -- sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}" --clean --if-exists' \
  | zstd -T0 | tee >(sha256sum > "$B/db.sha256") | age -r "$R" > "$B/shared-db.sql.zst.age"
kubectl -n workspace exec deploy/shared-db -- sh -c 'psql -U "${POSTGRES_USER:-postgres}" -Atc "select datname, pg_database_size(datname) from pg_database where not datistemplate"' > "$B/db-sizes.txt"
```

Den Benutzernamen gegebenenfalls aus dem Deployment lesen
(`kubectl -n workspace get deploy shared-db -o yaml | grep -A1 POSTGRES_USER`).
Die Postgres-Version festhalten:
`kubectl -n workspace exec deploy/shared-db -- postgres --version > "$B/db-version.txt"`.

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
  ssh "$node/gekko" "sudo tar --numeric-owner --xattrs --acls -C '$path' -cpf - ." \
    | pv -N "$pvc" | zstd -T0 | tee >(sha256sum > "$B/${ns}__${pvc}.sha256") | age -r "$R" > "$B/${ns}__${pvc}.tar.zst.age"
done < "$B/pv-map.tsv"
```

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
PGMAJOR=$(grep -oE '[0-9]+' "$B/db-version.txt" | head -1)
sudo docker run -d --name pgprobe -e POSTGRES_PASSWORD=probe "postgres:$PGMAJOR"
until sudo docker exec pgprobe pg_isready -U postgres >/dev/null 2>&1; do sleep 2; done
sudo docker exec -i pgprobe psql -U postgres -v ON_ERROR_STOP=0 < "$PLAIN/probe.sql" > /dev/null 2> "$PLAIN/probe.err"
sudo docker exec pgprobe psql -U postgres -Atc "select datname, pg_database_size(datname) from pg_database where not datistemplate"
sudo docker rm -f pgprobe; shred -u "$PLAIN/probe.sql"
```

Erwartung: dieselben Datenbanken wie in `db-sizes.txt`, Größen im Bereich ±10 %.
Fehler in `probe.err` sind nur zulässig für bereits existierende Rollen
(`role "postgres" already exists`).

Für jede Volume-Datei: `age -d … | zstd -dc | tar -tf - | wc -l` (lesbar,
Dateianzahl > 0). Nextcloud-App muss `config/config.php` enthalten.

Zweite Kopie: das komplette `$B` auf ein zweites Ziel kopieren (NUC bei
`NUC_ROLE=backup`: `rsync -a "$B" nuc/gekko:/srv/mentolder-backup/`, sonst
Windows-Laufwerk oder Filen).

`GATE`: Ab hier ist der Weg destruktiv. Vorlegen: Liste der Backup-Dateien mit
Größe und SHA-256-Präfix, Ergebnis der Restore-Probe, Ort der Zweitkopie.
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

Vorher korrigieren (per API mit `TS_API_KEY` oder in der Admin-Konsole):

1. In der Policy ergänzen: `"tagOwners": {"tag:fleet": ["autogroup:admin"]}`.
2. Neuen Auth-Key anlegen: reusable, **nicht** ephemeral, pre-approved, Tag
   `tag:fleet`. Getaggte Geräte haben keinen Key-Ablauf.
3. Den alten Key `kW8beSCrcC21CNTRL` widerrufen.

```bash
curl -s -u "$TS_API_KEY:" -X POST https://api.tailscale.com/api/v2/tailnet/-/keys \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":false,"preauthorized":true,"tags":["tag:fleet"]}}},"expirySeconds":7776000,"description":"fleet-nodes"}' | jq -r .key
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
chmod 600 ~/.kube/fleet; export KUBECONFIG=~/.kube/fleet
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
Workloads und Certificates anlegt:

```bash
for f in "$PLAIN"/secrets/*.json; do jq -r .metadata.namespace "$f"; done | sort -u | xargs -n1 -I{} kubectl create namespace {} --dry-run=client -o yaml | kubectl apply -f -
for f in "$PLAIN"/secrets/*.json; do kubectl apply --server-side --field-manager=bootstrap -f "$f"; done
kubectl create secret generic sops-age -n flux-system --from-file=age.agekey="$PLAIN/mentolder.agekey"
```

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
kubectl -n "$1" run "restore-$2" --restart=Never --image=alpine:3 --overrides="{\"spec\":{\"containers\":[{\"name\":\"r\",\"image\":\"alpine:3\",\"command\":[\"sleep\",\"86400\"],\"volumeMounts\":[{\"name\":\"d\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"d\",\"persistentVolumeClaim\":{\"claimName\":\"$2\"}}]}}"
kubectl -n "$1" wait --for=condition=Ready "pod/restore-$2" --timeout=180s
kubectl -n "$1" exec "restore-$2" -- sh -c 'find /data -mindepth 1 -delete'
age -d -i "$PLAIN/mentolder.agekey" "$B/${1}__${2}.tar.zst.age" | zstd -dc | pv -N "$2" \
  | kubectl -n "$1" exec -i "restore-$2" -- tar --numeric-owner -xpf - -C /data
kubectl -n "$1" exec "restore-$2" -- du -sh /data
kubectl -n "$1" delete pod "restore-$2" --wait
}
for p in nextcloud-app nextcloud-data-pvc pocket-id-data brain-data fuehrungsfunk-daten backup-pvc; do restore_pvc workspace "$p"; done
```

Größen mit `inventory/disk.txt` vergleichen.

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

- App-Quellcode und Image-Builds (`website`, `mentolder-web`, `studio-server`,
  `talk-transcriber`, `einvoice-sidecar`, `downloads-content`, `mcp-node`,
  `collabora-code`). Der Mirror aus Phase 3.2 kopiert von dort. Entfernen erst,
  wenn mentolder-prod eigene Builds hat.
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
