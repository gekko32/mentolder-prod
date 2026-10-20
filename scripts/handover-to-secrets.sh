#!/usr/bin/env bash
# Wandelt die Handover-Datei aus handover-export.sh zurueck in
# Kubernetes-Secret-Manifeste (eine Datei pro Secret, Klartext).
#
# Aufruf:
#   bash scripts/handover-to-secrets.sh <handover.json> <zielordner>
#
# Den Zielordner auf tmpfs legen (z. B. /run/user/$(id -u)/mentolder-plain/secrets).
set -euo pipefail
umask 077

IN=${1:?handover.json fehlt}
DIR=${2:?zielordner fehlt}
install -d -m700 "$DIR"

jq -c '
  [.items[] | select(.name|startswith("k8s/"))] as $all
  | $all[] | select(.name|contains("#")|not)
  | (.name|ltrimstr("k8s/")|split("/")) as [$ns, $name]
  | (.notes|capture("type=(?<t>.*)").t) as $type
  | ([.fields[] | {key:.name, value:.value}]
     + [$all[] | select(.name|startswith("k8s/\($ns)/\($name)#"))
        | {key:(.name|split("#")[1]), value:.notes}]) as $kv
  | {apiVersion:"v1", kind:"Secret", type:$type,
     metadata:{name:$name, namespace:$ns},
     data:($kv | map(
       if (.key|endswith(":base64")) then {key:(.key|rtrimstr(":base64")), value}
       else {key, value:(.value|@base64)} end) | from_entries)}
' "$IN" | while read -r s; do
  f="$DIR/$(jq -r '.metadata.namespace + "__" + .metadata.name' <<<"$s").json"
  printf '%s\n' "$s" > "$f"
done
echo "$(find "$DIR" -name '*.json' | wc -l) Secrets nach $DIR geschrieben"
