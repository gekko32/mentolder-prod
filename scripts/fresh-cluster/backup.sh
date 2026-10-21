#!/usr/bin/env bash
# Runbook 4.3/4.4 als Skript. Aufruf: backup.sh <zielordner> [--live]
#   --live: Probelauf gegen den laufenden Cluster. Skaliert nichts herunter und
#           ueberspringt die Rohkopie von shared-db-pvc (bei laufender DB inkonsistent).
# Braucht: KUBECONFIG auf den Altcluster, R (age.pub), ssh-Zugang gekko-hetzner-N/gekko.
# Ohne --live: 4.2 (Einfrieren) muss erledigt sein; stoppt shared-db fuer die Rohkopie.
set -euo pipefail
. ~/mentolder-ops/env.sh
OUT=${1:?zielordner fehlt}; LIVE=${2:-}
[ -n "${R:-}" ] || { echo "R (age.pub) fehlt"; exit 1; }
mkdir -p "$OUT"; cd "$OUT"
EXCL="pocket_id_korczewski videovault pentest website_massage"   # Entscheidung 2026-10-20 (LOG.md)
log() { echo "$(date -Is) $*" | tee -a "$OUT/backup.log"; }

log "start live=${LIVE:-no}"
k() { kubectl -n workspace "$@"; }
k get deploy shared-db -o jsonpath='{.spec.template.spec.containers[0].image}' > db-image.txt
k exec deploy/shared-db -c postgres -- postgres --version > db-version.txt
k exec deploy/shared-db -c postgres -- sh -c 'psql -U "$POSTGRES_USER" -d postgres -Atc "select datname, pg_database_size(datname) from pg_database where not datistemplate order by 1"' > db-sizes.txt
args=""; for d in $EXCL; do args="$args --exclude-database=$d"; done
# Dump per SSH auf dem DB-Knoten: kubectl exec ueber den API-Tunnel bricht bei
# grossen Streams ab (websocket 1006, Dump abgeschnitten, Probelauf 2026-10-21).
DBNODE=$(k get pod -l app=shared-db -o jsonpath='{.items[0].spec.nodeName}')
t0=$(date +%s)
ssh -n -o BatchMode=yes "$DBNODE/gekko" "sudo k3s kubectl -n workspace exec deploy/shared-db -c postgres -- sh -c 'pg_dumpall -U \"\$POSTGRES_USER\" --clean --if-exists $args'" \
  | zstd -T0 -q | tee >(sha256sum > db.sha256) | age -r "$R" > shared-db.sql.zst.age
# Vollstaendigkeit: ein abgeschnittener Dump endet nicht mit dem Abschlusskommentar
age -d -i "$PLAIN/mentolder.agekey" shared-db.sql.zst.age | zstd -dc | tail -c 300 | grep -q 'PostgreSQL database cluster dump complete' \
  || { log "FEHLER: Dump unvollstaendig"; exit 1; }
log "db dump $(du -h shared-db.sql.zst.age | cut -f1) in $(( $(date +%s)-t0 ))s"

# Zeilenzahlen je Tabelle zum Dump-Zeitpunkt, Vergleichsbasis fuer probe.sh (4.5)
ROWQ="select table_schema||'.'||table_name||' '||(xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_type='BASE TABLE' and table_schema not in ('pg_catalog','information_schema') order by 1;"
for db in $(cut -d'|' -f1 db-sizes.txt); do
  case " $EXCL postgres " in *" $db "*) continue;; esac
  printf '%s\n' "$ROWQ" | ssh -o BatchMode=yes "$DBNODE/gekko" "sudo k3s kubectl -n workspace exec -i deploy/shared-db -c postgres -- sh -c 'psql -U \"\$POSTGRES_USER\" -d $db -At'" > "rows-$db.txt"
done
log "Zeilenzahlen: $(for f in rows-*.txt; do printf '%s=%s ' "${f#rows-}" "$(awk '{s+=$2}END{print s}' "$f")"; done)"

# TLS-Secrets (cert-manager) mitnehmen: Neuausstellung ueber ipv64 bleibt nach dem
# ersten Zertifikat am 403 beim Aufraeumen haengen (Generalprobe 2026-10-21).
kubectl get secret -A --field-selector type=kubernetes.io/tls -o json \
  | jq '{apiVersion:"v1", kind:"List", items:[.items[]|select(.metadata.namespace|IN("workspace","workspace-office","coturn","website"))
        |{apiVersion, kind, type, data, metadata:{name:.metadata.name, namespace:.metadata.namespace,
          labels:(.metadata.labels//{}), annotations:((.metadata.annotations//{})|with_entries(select(.key|startswith("cert-manager.io/"))))}}]}' \
  | age -r "$R" > tls-secrets.json.age
log "tls-secrets: $(age -d -i "$PLAIN/mentolder.agekey" tls-secrets.json.age | jq -r '[.items[]|.metadata.namespace+"/"+.metadata.name]|join(" ")')"

# Rohkopie von shared-db-pvc nur bei gestoppter DB (Wartungsfenster)
if [ "$LIVE" != --live ]; then
  k scale deploy shared-db --replicas=0
  k wait --for=delete pod -l app=shared-db --timeout=180s || true
  log "shared-db gestoppt"
fi

kubectl get pv -o json | jq -r '.items[]|select(.spec.claimRef.namespace|IN("workspace","monitoring"))
  |[.spec.claimRef.namespace,.spec.claimRef.name,(.spec.local.path//.spec.hostPath.path),.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]]|@tsv' > pv-map.tsv
want=0
while IFS=$'\t' read -r ns pvc path node; do
  case "$pvc" in bge-*|prometheus-*|alertmanager-*) continue;; esac
  if [ "$pvc" = shared-db-pvc ] && [ "$LIVE" = --live ]; then log "skip $pvc (live)"; continue; fi
  want=$((want+1)); t0=$(date +%s)
  if [ -s "${ns}__${pvc}.tar.zst.age" ] && [ -s "${ns}__${pvc}.sha256" ]; then log "$ns/$pvc schon vorhanden"; continue; fi
  # tar-Exit 1 = Datei waehrend des Lesens geaendert (laufende Dienste wie Grafana): Warnung, kein Abbruch
  ssh -n -o BatchMode=yes "$node/gekko" "sudo tar --numeric-owner --xattrs --acls --warning=no-file-changed -C '$path' -cpf - . || [ \$? -eq 1 ]" \
    | zstd -T0 -q | tee >(sha256sum > "${ns}__${pvc}.sha256") | age -r "$R" > "${ns}__${pvc}.tar.zst.age"
  log "$ns/$pvc $(du -h "${ns}__${pvc}.tar.zst.age" | cut -f1) in $(( $(date +%s)-t0 ))s"
done < pv-map.tsv
# etcd-Snapshot und altes k3s-Token fuer den Rueckbau (nur im Wartungsfenster)
if [ "$LIVE" != --live ]; then
  ssh -n -o BatchMode=yes gekko-hetzner-2/gekko 'sudo k3s etcd-snapshot save --name pre-rebuild >/dev/null && sudo sh -c "cat \$(ls -t /var/lib/rancher/k3s/server/db/snapshots/pre-rebuild-* | head -1)"' \
    | age -r "$R" > etcd-pre-rebuild.age
  ssh -n -o BatchMode=yes gekko-hetzner-2/gekko 'sudo cat /var/lib/rancher/k3s/server/token' | age -r "$R" > k3s-token-old.age
  log "etcd-Snapshot $(du -h etcd-pre-rebuild.age | cut -f1), altes Token gesichert"
fi

have=$(ls *.tar.zst.age | wc -l)
log "archive: $have von $want"; [ "$have" -eq "$want" ] || { log "FEHLER: Archive fehlen"; exit 1; }
log "fertig"
