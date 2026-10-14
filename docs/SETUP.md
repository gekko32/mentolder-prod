# Einrichtung vor der Umstellung

Reihenfolge. Befehle mit `gh` laufen als Repo-Admin (gekko32).

## 1. Repo oeffentlich stellen (gekko32)

Settings → General → Danger Zone → Change visibility → Public. Der Inhalt von `environments/mentolder.yaml`
(Adresse, Telefon, USt-ID) ist in Paddione/Bachelorprojekt bereits oeffentlich, die Sealed Secrets sind
verschluesselt. Danach liest Flux das Repo per HTTPS ohne Secret, es gibt keinen Deploy Key.

## 2. Branch-Protection auf `main` (gekko32)

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

Danach kann niemand mehr direkt nach `main` pushen, auch gekko32 nicht. `CODEOWNERS` verlangt fuer
`flux/`, `.github/workflows/` und `UPSTREAM_REF` einen Review von `@Paddione`.

## 3. Artefakt

Das Paket `mentolder-manifests` ist oeffentlich, der Cluster braucht kein Registry-Secret.

## 4. Commit-Signaturen (optional, F2)

Oeffentliche Schluessel (GPG) in ein Secret `gekko-mentolder-git-verify` legen und am `GitRepository`
`spec.verify: {mode: head, secretRef: {name: gekko-mentolder-git-verify}}` setzen. Commits auf `main`
muessen dann signiert sein.
