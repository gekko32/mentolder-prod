#!/usr/bin/env bash
# Runbook Phase 5 und 6 als Befehle. Laeuft in gekko-ops nach Phase 2.0
# (~/mentolder-ops/env.sh geladen: PLAIN, R, inputs.secret.env).
#
#   fleet.sh userdata <name> <datei>   cloud-init mit Einmal-Tailscale-Key rendern
#   fleet.sh rebuild                   5.2: alle Knoten neu aufsetzen (CONFIRM=rebuild)
#   fleet.sh wait                      5.3: warten bis jeder Knoten im Tailnet und fertig ist
#   fleet.sh k3s                       5.4: k3s HA installieren, Kubeconfig nach KUBECONFIG_OUT
#   fleet.sh secrets                   6.1: Namespaces, Secrets, GHCR-Pull-Secrets, sops-age
#   fleet.sh flux [flux-instance.yaml] 6.2: flux-operator und FluxInstance
#   fleet.sh restore-window            6.3: Workloads ausser shared-db auf 0, CronJobs pausieren
#   fleet.sh restore-db <backupdir>    6.4
#   fleet.sh restore-pvcs <backupdir>  6.5: jede gesicherte PVC, die es im neuen Cluster gibt
#   fleet.sh restore-done              6.6: CronJobs an, Flux wieder an
#   fleet.sh ssh <name> <befehl…>
#
# Umgebung: NODES (Knotenliste, Standard nodes.prod), OS_IMAGE, PRIVATE_CIDR,
# K3S_TOKEN (sonst aus der Handover-Datei), KUBECONFIG_OUT (Standard ~/.kube/fleet),
# SKIP_PVCS (Leerzeichen-getrennt, Standard "backup-pvc", Entscheidung 2026-10-20).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NODES=${NODES:-$HERE/nodes.prod}
OS_IMAGE=${OS_IMAGE:-ubuntu-26.04}
PRIVATE_CIDR=${PRIVATE_CIDR:-192.168.200.0/24}
KUBECONFIG_OUT=${KUBECONFIG_OUT:-$HOME/.kube/fleet}
STATE=${STATE:-$HOME/mentolder-ops/fleet-state/$(basename "$NODES")}
SKIP_PVCS=${SKIP_PVCS:-backup-pvc}
: "${PLAIN:?env.sh laden}"
mkdir -p "$STATE"
SSHO=(-i "$HOME/.ssh/gekko_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o UserKnownHostsFile="$HOME/.ssh/known_hosts.fleet" -o StrictHostKeyChecking=accept-new)

nodes() { grep -vE '^[[:space:]]*(#|$)' "$NODES"; }   # name private-ip public-ip role
init_ip() { nodes | awk '$4=="init"{print $2; exit}'; }
init_name() { nodes | awk '$4=="init"{print $1; exit}'; }
tsip() { cat "$STATE/$1.tsip"; }
nssh() { local n=$1; shift; ssh "${SSHO[@]}" "gekko@$(tsip "$n")" "$@"; }
ts_api() { curl -fsS -u "${TS_API_KEY:?TS_API_KEY fehlt}:" "$@"; }
log() { echo "$(date +%T) $*" >&2; }

ts_key() {  # Einmal-Key, getaggt, 1 h gueltig
  ts_api -X POST https://api.tailscale.com/api/v2/tailnet/-/keys -H 'Content-Type: application/json' \
    -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":false,\"preauthorized\":true,\"tags\":[\"tag:fleet\"]}}},\"expirySeconds\":3600,\"description\":\"node-$1\"}" \
    | jq -er .key
}

cmd_userdata() {  # <name> <datei>
  local name=$1 out=$2
  ( umask 077
    NODE_NAME=$name SSH_PUBKEY=$(cat ~/.ssh/gekko_ed25519.pub) TS_AUTHKEY=$(ts_key "$name") \
    PRIVATE_CIDR=$PRIVATE_CIDR EXTRA_RUNCMD=${EXTRA_RUNCMD:-} \
      envsubst '$NODE_NAME $SSH_PUBKEY $TS_AUTHKEY $PRIVATE_CIDR $EXTRA_RUNCMD' \
      < "$HERE/node-cloud-init.yaml.tmpl" > "$out" )
}

cmd_rebuild() {
  [ "${CONFIRM:-}" = rebuild ] || { echo "Destruktiv. Mit CONFIRM=rebuild aufrufen."; exit 1; }
  date +%s > "$STATE/rebuild.started"
  while read -r name _ _ _ <&3; do
    cmd_userdata "$name" "$PLAIN/userdata-$name.yaml"
    hcloud server rebuild "$name" --image "$OS_IMAGE" --user-data-from-file "$PLAIN/userdata-$name.yaml"
    shred -u "$PLAIN/userdata-$name.yaml"
  done 3< <(nodes)
}

cmd_wait() {  # Tailnet-Geraet (neuestes mit Hostname, tag:fleet) und cloud-init fertig
  local since; since=$(cat "$STATE/rebuild.started" 2>/dev/null || echo 0)
  while read -r name _ _ _ <&3; do
    local ip=""
    for _ in $(seq 1 90); do
      ip=$(ts_api https://api.tailscale.com/api/v2/tailnet/-/devices | jq -r --arg n "$name" --argjson s "$since" '
        [.devices[] | select(.hostname==$n and ((.tags//[])|index("tag:fleet")))
                    | select((.created|sub("\\.[0-9]+";"")|fromdateiso8601) >= $s)]
        | sort_by(.created) | last | .addresses[0] // empty')
      [ -n "$ip" ] && break; sleep 10
    done
    [ -n "$ip" ] || { log "$name: nicht im Tailnet"; exit 1; }
    echo "$ip" > "$STATE/$name.tsip"
    for _ in $(seq 1 60); do nssh "$name" test -f /var/lib/fleet-node-ready 2>/dev/null && break; sleep 10; done
    nssh "$name" 'test -f /var/lib/fleet-node-ready && cloud-init status | tail -1 && sudo -n ufw status | head -1'
    log "$name bereit ($ip)"
  done 3< <(nodes)
}

cmd_k3s() {
  local ver token server cfg
  # Kanal v1.37: der Altcluster lief auf v1.37.1 (latest), stable waere ein Downgrade (Probelauf 2026-10-21)
  ver=${K3S_VERSION:-$(curl -fsSL https://update.k3s.io/v1-release/channels | jq -r --arg c "${K3S_CHANNEL:-v1.37}" '.data[]|select(.id==$c).latest')}
  token=${K3S_TOKEN:-$(jq -r '.items[]|select(.name=="ops/k3s").fields[0].value' "$PLAIN/handover.json")}
  [ -n "$token" ] && [ "$token" != null ] || { echo "K3S_TOKEN fehlt"; exit 1; }
  server="https://$(init_ip):6443"
  echo "$ver" > "$STATE/k3s.version"
  while read -r name priv pub role <&3; do
    local ts iface
    ts=$(tsip "$name")
    iface=$(nssh "$name" "ip -o -4 addr show | awk '\$4 ~ \"^$priv/\" {print \$2}'")
    [ -n "$iface" ] || { log "$name: Interface fuer $priv nicht gefunden"; exit 1; }
    cfg="node-name: \"$name\"
node-ip: \"$priv\"
flannel-iface: \"$iface\"
tls-san: [\"$name\", \"$priv\", \"$pub\", \"$ts\"]
secrets-encryption: true
write-kubeconfig-mode: \"0600\"
etcd-snapshot-schedule-cron: \"0 */6 * * *\"
etcd-snapshot-retention: 20
kube-apiserver-arg: [\"audit-log-path=/var/log/k3s-audit.log\", \"audit-log-maxage=14\"]"
    if [ "$role" = init ]; then cfg="$cfg
cluster-init: true"; else cfg="$cfg
server: \"$server\""; fi
    printf '%s\n' "$cfg" | nssh "$name" 'sudo install -D -m600 /dev/stdin /etc/rancher/k3s/config.yaml'
    nssh "$name" "curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION='$ver' K3S_TOKEN='$token' sh -s - server" >/dev/null
    nssh "$name" 'sudo k3s kubectl wait --for=condition=Ready node/$(hostname) --timeout=300s'
    log "$name: k3s $ver ($role, $iface)"
  done 3< <(nodes)
  nssh "$(init_name)" 'sudo cat /etc/rancher/k3s/k3s.yaml' \
    | sed "s#https://127.0.0.1:6443#https://$(tsip "$(init_name)"):6443#" > "$KUBECONFIG_OUT"
  chmod 600 "$KUBECONFIG_OUT"
  KUBECONFIG=$KUBECONFIG_OUT kubectl get nodes -o wide
}

cmd_secrets() {
  local src="$PLAIN/secrets" dst="$PLAIN/secrets-final" f ns
  [ -s "$PLAIN/ghcr-token" ] || { echo "$PLAIN/ghcr-token fehlt (6.1)"; exit 1; }
  # Quelle bleibt unveraendert, damit der Lauf wiederholbar ist (Tausch nur einmal)
  rm -rf "$dst"; ( umask 077; cp -r "$src" "$dst" )
  f="$dst/workspace__workspace-secrets.json"
  jq '.data |= (.KC_USER1_PASSWORD as $a | .KC_USER1_PASSWORD = .KC_USER2_PASSWORD | .KC_USER2_PASSWORD = $a)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  for ns in workspace website workspace-office; do
    kubectl create secret docker-registry ghcr-pull-secret -n "$ns" --docker-server=ghcr.io \
      --docker-username=gekko32 --docker-password="$(cat "$PLAIN/ghcr-token")" --dry-run=client -o json > "$dst/${ns}__ghcr-pull-secret.json"
  done
  rm -f "$dst/flux-system__ghcr-auth.json" "$dst"/*__letsencrypt-prod-key.json
  # TLS des Prometheus-Operators: im Altcluster einmalig von kube-webhook-certgen
  # erzeugt, weder im Render noch in der Handover-Datei. Ohne das Secret startet
  # monitoring-operator nicht (Generalprobe 2026-10-21). Webhooks laufen mit
  # failurePolicy Ignore ohne caBundle, ein eigenes selbstsigniertes Paar genuegt.
  [ -f "$dst/monitoring__monitoring-admission.json" ] || {
    local t; t=$(mktemp -d -p "$PLAIN")
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 36500 \
      -subj /O=monitoring-admission-ca -keyout "$t/ca.key" -out "$t/ca" 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /O=monitoring-operator \
      -keyout "$t/key" -out "$t/csr" 2>/dev/null
    openssl x509 -req -in "$t/csr" -CA "$t/ca" -CAkey "$t/ca.key" -CAcreateserial -days 36500 -out "$t/cert" \
      -extfile <(printf 'subjectAltName=DNS:monitoring-operator,DNS:monitoring-operator.monitoring.svc') 2>/dev/null
    kubectl create secret generic monitoring-admission -n monitoring --from-file="$t/ca" --from-file="$t/cert" \
      --from-file="$t/key" --dry-run=client -o json > "$dst/monitoring__monitoring-admission.json"
    rm -rf "$t"; }
  for ns in $(for f in "$dst"/*.json; do jq -r .metadata.namespace "$f"; done | sort -u); do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  for f in "$dst"/*.json; do kubectl apply --server-side --field-manager=bootstrap -f "$f" >/dev/null; done
  # TLS aus dem Altcluster (Phase 4, backup.sh), damit zum Umschalten nichts neu ausgestellt werden muss
  if [ -n "${TLS_BACKUP:-}" ]; then
    age -d -i "$PLAIN/mentolder.agekey" "$TLS_BACKUP" | kubectl apply --server-side --force-conflicts --field-manager=bootstrap -f - >/dev/null
    log "TLS-Secrets aus $TLS_BACKUP eingespielt"
  fi
  kubectl create secret generic sops-age -n flux-system --from-file=age.agekey="$PLAIN/mentolder.agekey" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "$(ls "$dst"/*.json | wc -l) Secrets + sops-age eingespielt"
}

cmd_flux() {
  local inst=${1:-$HERE/../../flux/clusters/fleet/flux-instance.yaml}
  helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
    -n flux-system --create-namespace --wait >/dev/null
  kubectl apply -f "$inst"
  kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=600s
}

cmd_restore_window() {
  local d
  flux suspend kustomization mentolder-prod mentolder-prod-website -n flux-system
  for d in $(kubectl -n workspace get deploy -o name | grep -v '/shared-db$'); do kubectl -n workspace scale "$d" --replicas=0 >/dev/null; done
  kubectl -n workspace get cronjob -o name | xargs -r -n1 kubectl -n workspace patch --type merge -p '{"spec":{"suspend":true}}' >/dev/null
  kubectl -n workspace rollout status deploy/shared-db --timeout=300s
}

cmd_restore_done() {  # 6.6: CronJobs an, Flux setzt Replikazahlen aus Git wieder ein
  kubectl -n workspace get cronjob -o name | xargs -r -n1 kubectl -n workspace patch --type merge -p '{"spec":{"suspend":false}}' >/dev/null
  flux resume kustomization mentolder-prod mentolder-prod-website -n flux-system
  # resume allein wartet aufs Intervall (bis 10 min), erst reconcile setzt die Replikazahlen sofort
  flux reconcile kustomization mentolder-prod -n flux-system
  flux reconcile kustomization mentolder-prod-website -n flux-system
  flux get kustomizations -A --status-selector ready=false
}

dbnode() { kubectl -n workspace get pod -l app=shared-db -o jsonpath='{.items[0].spec.nodeName}'; }

cmd_restore_db() {  # Stream per SSH auf den DB-Knoten (kubectl exec ueber das Netz bricht bei grossen Streams ab)
  local b=${1:?backupdir}
  age -d -i "$PLAIN/mentolder.agekey" "$b/shared-db.sql.zst.age" | zstd -dc \
    | nssh "$(dbnode)" "sudo k3s kubectl -n workspace exec -i deploy/shared-db -c postgres -- sh -c 'psql -U \"\$POSTGRES_USER\" -d postgres -v ON_ERROR_STOP=0 -q -f -'" \
      > /dev/null 2> "$PLAIN/restore.err" || true
  grep -v -E 'already exists|current user cannot be dropped' "$PLAIN/restore.err" | head -20 || true
  nssh "$(dbnode)" "sudo k3s kubectl -n workspace exec deploy/shared-db -c postgres -- sh -c 'psql -U \"\$POSTGRES_USER\" -d postgres -Atc \"select datname, pg_database_size(datname) from pg_database where not datistemplate order by 1\"'"
}

cmd_restore_pvcs() {
  local b=${1:?backupdir} a base ns pvc node
  for a in "$b"/*.tar.zst.age; do
    base=$(basename "$a" .tar.zst.age); ns=${base%%__*}; pvc=${base#*__}
    case " $SKIP_PVCS shared-db-pvc " in *" $pvc "*) log "skip $ns/$pvc"; continue;; esac
    kubectl -n "$ns" get pvc "$pvc" >/dev/null 2>&1 || { log "skip $ns/$pvc (im neuen Cluster nicht vorhanden)"; continue; }
    kubectl -n "$ns" delete pod "restore-$pvc" --ignore-not-found --wait >/dev/null
    kubectl -n "$ns" run "restore-$pvc" --restart=Never --image=debian:stable-slim --overrides="{\"spec\":{\"containers\":[{\"name\":\"r\",\"image\":\"debian:stable-slim\",\"command\":[\"sleep\",\"86400\"],\"volumeMounts\":[{\"name\":\"d\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"d\",\"persistentVolumeClaim\":{\"claimName\":\"$pvc\"}}]}}" >/dev/null
    kubectl -n "$ns" wait --for=condition=Ready "pod/restore-$pvc" --timeout=180s >/dev/null
    node=$(kubectl -n "$ns" get pod "restore-$pvc" -o jsonpath='{.spec.nodeName}')
    kubectl -n "$ns" exec "restore-$pvc" -- sh -c 'find /data -mindepth 1 -delete'
    age -d -i "$PLAIN/mentolder.agekey" "$a" | zstd -dc \
      | nssh "$node" "sudo k3s kubectl -n $ns exec -i restore-$pvc -- tar --numeric-owner --xattrs --acls -xpf - -C /data"
    log "$ns/$pvc -> $node: $(kubectl -n "$ns" exec "restore-$pvc" -- du -sh /data | cut -f1)"
    kubectl -n "$ns" delete pod "restore-$pvc" --wait >/dev/null
  done
}

c=${1:-}; shift || true
case "$c" in
  userdata) cmd_userdata "$@";;
  rebuild) cmd_rebuild;;
  wait) cmd_wait;;
  k3s) cmd_k3s;;
  secrets) cmd_secrets;;
  flux) cmd_flux "$@";;
  restore-window) cmd_restore_window;;
  restore-db) cmd_restore_db "$@";;
  restore-pvcs) cmd_restore_pvcs "$@";;
  restore-done) cmd_restore_done;;
  ssh) nssh "$@";;
  *) sed -n '2,20p' "$0"; exit 1;;
esac
