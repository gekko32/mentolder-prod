#!/usr/bin/env bash
# Exportiert alle Secrets der mentolder-Prod aus dem laufenden Cluster plus die
# Betriebswerte fuer den Neuaufbau in eine Bitwarden-/Vaultwarden-Importdatei
# (unverschluesseltes JSON, `bw import bitwardenjson <datei>`).
#
# Aufruf:
#   bash scripts/handover-export.sh [ausgabe.json]
#
# Umgebung (fehlende Werte werden verdeckt abgefragt, leer = weglassen):
#   KUBE_CONTEXT      Kontext des Altclusters (Standard: fleet)
#   GEKKO_SSH_KEY     privater Schluessel (Standard: ~/.ssh/gekko_ed25519)
#   TS_API_KEY, TS_AUTH_KEY, HCLOUD_TOKEN, NUC_TAILNET_IP
#
# Die Datei enthaelt Klartext. Nach dem Import in Vaultwarden vernichten
# (shred -u). Das Skript gibt nur Schluesselnamen und Anzahlen aus.
set -euo pipefail
umask 077

CTX=${KUBE_CONTEXT:-fleet}
OUT=${1:-mentolder-handover-$(date +%F).json}
KEY=${GEKKO_SSH_KEY:-$HOME/.ssh/gekko_ed25519}
NAMESPACES=(workspace website coturn rustdesk workspace-office monitoring cert-manager flux-system)
# Bitwarden begrenzt verschluesselte Feldwerte auf 5000 Zeichen, Notizen auf 10000.
FIELD_MAX=3000
NOTE_MAX=7000

for t in kubectl jq age-keygen openssl; do
  command -v "$t" >/dev/null || { echo "fehlt: $t" >&2; exit 1; }
done
[ -e "$OUT" ] && { echo "existiert bereits: $OUT" >&2; exit 1; }

ask() {
  local var=$1 prompt=$2
  # gesetzte Variable (auch leer) wird nicht abgefragt
  if [ -z "${!var+x}" ]; then read -r -s -p "$prompt (leer = weglassen): " "$var" || true; echo >&2; fi
}
ask TS_API_KEY "Tailscale API key"
ask TS_AUTH_KEY "Tailscale auth key"
ask HCLOUD_TOKEN "Hetzner Cloud API token"
NUC_TAILNET_IP=${NUC_TAILNET_IP:-100.87.136.73}

work=$(mktemp -d /dev/shm/handover.XXXXXX)
trap 'find "$work" -type f -exec shred -u {} + 2>/dev/null; rmdir "$work"' EXIT
uuid() { cat /proc/sys/kernel/random/uuid; }
FOLDER=$(uuid)

# 1. Kubernetes-Secrets (ohne generierte, Token, TLS: cert-manager stellt neu aus)
for ns in "${NAMESPACES[@]}"; do
  kubectl --context "$CTX" get secrets -n "$ns" -o json
done | jq -c '.items[]
  | select(.type|IN("kubernetes.io/service-account-token","helm.sh/release.v1","k3s.cattle.io/node-password","kubernetes.io/tls")|not)
  | select(.metadata.name|test("-generated$|-web-config$|-tls-assets-|-cluster-tls-config$|^prometheus-|^monitoring-admission$|^cert-manager-webhook-ca$|^sh\\.helm|^flux-operator-entitlement$")|not)
  | {ns:.metadata.namespace, name:.metadata.name, type,
     data:((.data//{})|to_entries|map(
       if (.value|@base64d|@base64) == .value
       then {key, value:(.value|@base64d), b64:false}
       else {key, value:.value, b64:true} end))}' > "$work/live.jsonl"

jq -c --arg f "$FOLDER" --argjson fmax "$FIELD_MAX" '
  def item($name; $notes; $fields):
    {id:null, organizationId:null, folderId:$f, type:2, reprompt:0, favorite:false,
     secureNote:{type:0}, collectionIds:null, name:$name, notes:$notes, fields:$fields};
  ("k8s/\(.ns)/\(.name)") as $base
  | item($base; "namespace=\(.ns)\nname=\(.name)\ntype=\(.type)";
         [.data[] | select((.value|length) <= $fmax)
          | {name:(.key + (if .b64 then ":base64" else "" end)), value, type:1, linkedId:null}]),
    (.data[] | select((.value|length) > $fmax)
     | item("\($base)#\(.key)\(if .b64 then ":base64" else "" end)"; .value; []))
' "$work/live.jsonl" > "$work/items.jsonl"

# 2. Betriebswerte fuer den Neuaufbau
age-keygen -o "$work/age.key" 2>/dev/null
AGE_PUB=$(grep -o 'age1[0-9a-z]*' "$work/age.key")
AGE_SECRET=$(grep '^AGE-SECRET-KEY-' "$work/age.key")
K3S_TOKEN=$(openssl rand -hex 32)

ops_item() {  # $1=name $2=notes, danach Paare name=wert (Wert leer = weglassen)
  local name=$1 notes=$2; shift 2
  local fields='[]' kv
  for kv in "$@"; do
    [ -n "${kv#*=}" ] || continue
    fields=$(jq -c --arg n "${kv%%=*}" --arg v "${kv#*=}" '. + [{name:$n, value:$v, type:1, linkedId:null}]' <<<"$fields")
  done
  jq -nc --arg f "$FOLDER" --arg n "$name" --arg notes "$notes" --argjson fields "$fields" \
    '{id:null, organizationId:null, folderId:$f, type:2, reprompt:0, favorite:false,
      secureNote:{type:0}, collectionIds:null, name:$n, notes:$notes, fields:$fields}'
}
{
  ops_item "ops/inputs" "Zugaenge fuer den Neuaufbau (Runbook Eingaben I1, I2, I5)" \
    "TAILSCALE_API_KEY=${TS_API_KEY:-}" "TAILSCALE_AUTH_KEY=${TS_AUTH_KEY:-}" \
    "HCLOUD_TOKEN=${HCLOUD_TOKEN:-}" "NUC_TAILNET_IP=$NUC_TAILNET_IP"
  ops_item "ops/sops-age" "SOPS-Schluessel des neuen Clusters. Ohne ihn sind die Repo-Secrets verloren." \
    "SOPS_AGE_PUBLIC=$AGE_PUB" "SOPS_AGE_KEY=$AGE_SECRET"
  ops_item "ops/k3s" "Token fuer den neuen k3s-Cluster (Runbook Phase 5.4)" "K3S_TOKEN=$K3S_TOKEN"
  if [ -r "$KEY" ]; then
    jq -nc --arg f "$FOLDER" --rawfile k "$KEY" --arg pub "$(cat "$KEY.pub" 2>/dev/null)" \
      '{id:null, organizationId:null, folderId:$f, type:2, reprompt:0, favorite:false,
        secureNote:{type:0}, collectionIds:null, name:"ops/ssh-gekko_ed25519", notes:$k,
        fields:[{name:"public", value:$pub, type:0, linkedId:null}]}'
  else
    echo "Hinweis: $KEY nicht lesbar, SSH-Schluessel nicht enthalten" >&2
  fi
} >> "$work/items.jsonl"

N_SECRETS=$(wc -l < "$work/live.jsonl")
jq -nc --arg f "$FOLDER" --arg ctx "$CTX" --arg date "$(date -Is)" --arg n "$N_SECRETS" \
  '{id:null, organizationId:null, folderId:$f, type:2, reprompt:0, favorite:false,
    secureNote:{type:0}, collectionIds:null, name:"README",
    notes:("mentolder-prod Handover\nerstellt: \($date)\nQuelle: Kontext \($ctx)\nKubernetes-Secrets: \($n)\n\n" +
           "k8s/<ns>/<name>: ein Secret, Felder = Schluessel. Suffix :base64 = Binaerwert.\n" +
           "k8s/<ns>/<name>#<key>: zu langer Wert, steht in den Notizen.\n" +
           "Import: bw import bitwardenjson <datei>. Danach Datei mit shred -u vernichten.\n" +
           "Zurueck in Secrets: scripts/handover-to-secrets.sh <datei> <zielordner>"),
    fields:[]}' >> "$work/items.jsonl"

jq -s --arg f "$FOLDER" '{encrypted:false, folders:[{id:$f, name:"mentolder-prod"}], items:.}' \
  "$work/items.jsonl" > "$OUT"

# Pruefung und Zusammenfassung ohne Werte
too_long=$(jq '[.items[] | select((.notes|length) > '"$NOTE_MAX"')] | length' "$OUT")
echo "geschrieben: $OUT ($(jq '.items|length' "$OUT") Eintraege, $N_SECRETS Kubernetes-Secrets)"
jq -r '.items[] | "\(.name)\t\(.fields|length) Felder"' "$OUT"
[ "$too_long" = 0 ] || echo "WARNUNG: $too_long Eintraege mit Notizen > $NOTE_MAX Zeichen, Vaultwarden-Import kann sie ablehnen" >&2
