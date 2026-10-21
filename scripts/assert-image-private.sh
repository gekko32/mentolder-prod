#!/usr/bin/env bash
# scripts/assert-image-private.sh <paket> <tag> [allow-missing]
# Bricht ab, wenn ghcr.io/gekko32/<paket>:<tag> ohne Anmeldung lesbar ist (Paket oeffentlich).
# Prueft per anonymem Pull statt Packages-API, weil GITHUB_TOKEN diese API nicht lesen darf.
# Sichtbarkeit laesst sich nur in der Web-UI aendern (Paket-Einstellungen > Danger Zone).
set -euo pipefail
pkg="$1" tag="$2" mode="${3:-}"
repo="gekko32/${pkg}"
token="$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null \
  | sed -nE 's/.*"token":"([^"]+)".*/\1/p' || true)"
code="$(curl -s -o /dev/null -w '%{http_code}' -I \
  ${token:+-H "Authorization: Bearer ${token}"} \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
  "https://ghcr.io/v2/${repo}/manifests/${tag}")"
case "$code" in
  200)
    echo "FATAL: ghcr.io/${repo}:${tag} ist anonym lesbar (oeffentlich). Paket auf Private stellen." >&2
    exit 1 ;;
  401|403)
    echo "ok: ghcr.io/${repo} ist nicht anonym lesbar (HTTP ${code})." ;;
  404)
    if [[ "$mode" == "allow-missing" ]]; then
      echo "ok: ghcr.io/${repo}:${tag} existiert noch nicht."
    else
      echo "FATAL: ghcr.io/${repo}:${tag} nicht gefunden (HTTP 404)." >&2
      exit 1
    fi ;;
  *)
    echo "FATAL: unerwarteter HTTP-Status ${code} fuer ghcr.io/${repo}:${tag}." >&2
    exit 1 ;;
esac
