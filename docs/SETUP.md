# Einrichtung vor der Umstellung

Reihenfolge. Jeder Schritt ist unabhaengig pruefbar. Befehle mit `gh` laufen als Repo-Admin (gekko32).

## 1. Branch-Protection auf `main` (gekko32)

```bash
gh api -X PUT repos/gekko32/mentolder-prod/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

Private Repos brauchen dafuer GitHub Pro/Team. Sonst: Settings → Branches fehlt die Option, dann das
Repo oeffentlich stellen oder den Plan wechseln.

Danach kann niemand mehr direkt nach `main` pushen, auch gekko32 nicht. `CODEOWNERS` verlangt fuer
`flux/`, `.github/workflows/` und `UPSTREAM_REF` einen Review von `@Paddione`.

## 2. Deploy Key fuer das GitRepository

```bash
ssh-keygen -t ed25519 -N '' -C 'flux gekko-mentolder-prod' -f ./gekko-mentolder-deploy
gh repo deploy-key add ./gekko-mentolder-deploy.pub -R gekko32/mentolder-prod -t flux-fleet
ssh-keyscan github.com > ./known_hosts 2>/dev/null
kubectl --context fleet -n flux-system create secret generic gekko-mentolder-git-auth \
  --from-file=identity=./gekko-mentolder-deploy --from-file=known_hosts=./known_hosts
shred -u ./gekko-mentolder-deploy ./gekko-mentolder-deploy.pub ./known_hosts
```

Der Key ist read-only (Standard bei `gh repo deploy-key add`, ohne `--allow-write`).

## 3. Lesezugriff auf das Artefakt

Variante A, Paket bleibt privat: gekko32-Token mit nur `read:packages` erzeugen.

```bash
kubectl --context fleet create namespace gekko-mentolder --dry-run=client -o yaml | kubectl --context fleet apply -f -
kubectl --context fleet -n gekko-mentolder create secret docker-registry gekko-ghcr-auth \
  --docker-server=ghcr.io --docker-username=gekko32 --docker-password="$GHCR_READ_TOKEN"
```

Variante B: Paket `mentolder-manifests` oeffentlich machen und `secretRef` in `flux/oci-source.yaml` entfernen.

## 4. Commit-Signaturen (optional, F2)

Oeffentliche Schluessel (GPG) in ein Secret `gekko-mentolder-git-verify` legen und am `GitRepository`
`spec.verify: {mode: head, secretRef: {name: gekko-mentolder-git-verify}}` setzen. Commits auf `main`
muessen dann signiert sein.
