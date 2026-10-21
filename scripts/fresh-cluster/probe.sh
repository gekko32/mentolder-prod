#!/usr/bin/env bash
# Runbook 4.5: Restore-Probe. Spielt den Dump in einen lokalen Postgres-Container
# (dasselbe Image wie shared-db) und vergleicht die Zeilenzahl jeder Tabelle mit
# dem Stand beim Dump (rows-<db>.txt aus backup.sh). Prueft jedes Volume-Archiv.
# Aufruf: probe.sh <backupdir>
set -euo pipefail
. ~/mentolder-ops/env.sh
B=${1:?backupdir}; fail=0
Q="select table_schema||'.'||table_name||' '||(xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_type='BASE TABLE' and table_schema not in ('pg_catalog','information_schema') order by 1;"
command -v docker >/dev/null || sudo apt-get install -y docker.io
sudo docker rm -f pgprobe >/dev/null 2>&1 || true
sudo docker run -d --name pgprobe -e POSTGRES_PASSWORD=probe "$(cat "$B/db-image.txt")" >/dev/null
until sudo docker exec pgprobe pg_isready -U postgres >/dev/null 2>&1; do sleep 2; done; sleep 3
age -d -i "$PLAIN/mentolder.agekey" "$B/shared-db.sql.zst.age" | zstd -dc \
  | sudo docker exec -i pgprobe psql -U postgres -q -v ON_ERROR_STOP=0 > /dev/null 2> "$PLAIN/probe.err" || true
# zulaessig: NOTICEs, bestehende Rollen, --clean auf den eigenen Benutzer
grep '^ERROR' "$PLAIN/probe.err" | grep -v -E 'already exists|current user cannot be dropped' && fail=1 || echo "DB: keine unerwarteten Fehler"
for f in "$B"/rows-*.txt; do
  db=$(basename "$f" .txt); db=${db#rows-}
  printf '%s\n' "$Q" | sudo docker exec -i pgprobe psql -U postgres -d "$db" -At > "$PLAIN/probe-rows-$db.txt"
  if diff -q "$f" "$PLAIN/probe-rows-$db.txt" >/dev/null; then
    echo "DB $db: $(wc -l < "$f") Tabellen, $(awk '{s+=$2}END{print s}' "$f") Zeilen identisch"
  else echo "DB $db: ABWEICHUNG"; diff "$f" "$PLAIN/probe-rows-$db.txt" | head -5; fail=1; fi
done
sudo docker rm -f pgprobe >/dev/null
for a in "$B"/*.tar.zst.age; do
  n=$(age -d -i "$PLAIN/mentolder.agekey" "$a" | zstd -dc | tar -tf - | wc -l)
  printf '%-55s %6s Eintraege\n' "$(basename "$a")" "$n"; [ "$n" -gt 0 ] || fail=1
done
age -d -i "$PLAIN/mentolder.agekey" "$B/workspace__nextcloud-app.tar.zst.age" | zstd -dc | tar -tf - | grep -cx './config/config.php' >/dev/null \
  && echo "nextcloud-app: config/config.php vorhanden" || { echo "nextcloud-app: config.php FEHLT"; fail=1; }
[ $fail -eq 0 ] && echo "PROBE OK" || { echo "PROBE FEHLGESCHLAGEN"; exit 1; }
