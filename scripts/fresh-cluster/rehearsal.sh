#!/usr/bin/env bash
# Generalprobe fuer Phase 5/6 auf Wegwerf-Servern, ohne die Produktion zu beruehren.
#   rehearsal.sh up     Netz, Firewall (ausgehend kein SMTP) und 3 Server rh-fleet-2..4
#   rehearsal.sh down   alles wieder entfernen (Server, Netz, Firewall, Tailnet-Geraete)
# Danach: NODES=$STATE_DIR/nodes PRIVATE_CIDR=192.168.210.0/24 fleet.sh wait|k3s|…
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NET=rh-fleet-net; FW=rh-fleet-fw; CIDR=192.168.210.0/24
TYPE=${TYPE:-cx33}; LOC=${LOC:-nbg1}; OS_IMAGE=${OS_IMAGE:-ubuntu-26.04}
STATE_DIR=$HOME/mentolder-ops/fleet-state/rehearsal; mkdir -p "$STATE_DIR"
: "${PLAIN:?env.sh laden}"
LABEL=purpose=rehearsal

up() {
  hcloud network describe $NET >/dev/null 2>&1 || {
    hcloud network create --name $NET --ip-range $CIDR --label $LABEL >/dev/null
    hcloud network add-subnet $NET --type cloud --network-zone eu-central --ip-range $CIDR >/dev/null; }
  hcloud firewall describe $FW >/dev/null 2>&1 || {
    cat > "$STATE_DIR/fw.json" <<'J'
[
 {"direction":"in","protocol":"tcp","port":"22","source_ips":["0.0.0.0/0","::/0"]},
 {"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0","::/0"]},
 {"direction":"in","protocol":"tcp","port":"443","source_ips":["0.0.0.0/0","::/0"]},
 {"direction":"in","protocol":"udp","port":"41641","source_ips":["0.0.0.0/0","::/0"]},
 {"direction":"in","protocol":"icmp","source_ips":["0.0.0.0/0","::/0"]},
 {"direction":"out","protocol":"tcp","port":"1-24","destination_ips":["0.0.0.0/0","::/0"]},
 {"direction":"out","protocol":"tcp","port":"26-464","destination_ips":["0.0.0.0/0","::/0"]},
 {"direction":"out","protocol":"tcp","port":"466-586","destination_ips":["0.0.0.0/0","::/0"]},
 {"direction":"out","protocol":"tcp","port":"588-2524","destination_ips":["0.0.0.0/0","::/0"]},
 {"direction":"out","protocol":"tcp","port":"2526-65535","destination_ips":["0.0.0.0/0","::/0"]},
 {"direction":"out","protocol":"udp","port":"1-65535","destination_ips":["0.0.0.0/0","::/0"]},
 {"direction":"out","protocol":"icmp","destination_ips":["0.0.0.0/0","::/0"]}
]
J
    hcloud firewall create --name $FW --rules-file "$STATE_DIR/fw.json" --label $LABEL >/dev/null; }
  date +%s > "$STATE_DIR/rebuild.started"
  : > "$STATE_DIR/nodes.tmp"
  for i in 2 3 4; do
    n=rh-fleet-$i
    if ! hcloud server describe $n >/dev/null 2>&1; then
      NODES=/dev/null PRIVATE_CIDR=$CIDR "$HERE/fleet.sh" userdata $n "$PLAIN/userdata-$n.yaml"
      hcloud server create --name $n --type "$TYPE" --location "$LOC" --image "$OS_IMAGE" \
        --network $NET --firewall $FW --label $LABEL --without-ipv6 \
        --user-data-from-file "$PLAIN/userdata-$n.yaml" >/dev/null
      shred -u "$PLAIN/userdata-$n.yaml"
    fi
    j=$(hcloud server describe $n -o json)
    role=join; [ $i = 2 ] && role=init
    printf '%s %s %s %s\n' $n "$(jq -r '.private_net[0].ip' <<<"$j")" "$(jq -r '.public_net.ipv4.ip' <<<"$j")" $role >> "$STATE_DIR/nodes.tmp"
  done
  mv "$STATE_DIR/nodes.tmp" "$STATE_DIR/nodes"
  mkdir -p "$HOME/mentolder-ops/fleet-state/nodes" && cp "$STATE_DIR/rebuild.started" "$HOME/mentolder-ops/fleet-state/nodes/"
  cat "$STATE_DIR/nodes"
}

down() {
  for i in 2 3 4; do hcloud server delete rh-fleet-$i 2>/dev/null || true; done
  hcloud firewall delete $FW 2>/dev/null || true
  hcloud network delete $NET 2>/dev/null || true
  if [ -n "${TS_API_KEY:-}" ]; then
    curl -fsS -u "$TS_API_KEY:" https://api.tailscale.com/api/v2/tailnet/-/devices \
      | jq -r '.devices[]|select(.hostname|startswith("rh-fleet-"))|.id' \
      | while read -r id; do curl -fsS -o /dev/null -u "$TS_API_KEY:" -X DELETE "https://api.tailscale.com/api/v2/device/$id" && echo "tailnet: $id entfernt"; done
  fi
  rm -rf "$HOME/mentolder-ops/fleet-state/nodes" "$STATE_DIR"
  hcloud server list -l $LABEL -o noheader
}

case "${1:-}" in up) up;; down) down;; *) sed -n '2,5p' "$0"; exit 1;; esac
