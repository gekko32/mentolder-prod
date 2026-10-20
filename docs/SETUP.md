# Einrichtung

Die Umstellung ist seit 2026-10-14 abgeschlossen. Diese Seite hält fest,
wie das Repo eingerichtet ist, falls es neu aufgesetzt werden muss.
Befehle mit `gh` laufen als Repo-Admin (gekko32).

- [x] 1. Repo öffentlich stellen
- [x] 2. Branch-Protection auf `main`
- [x] 3. Artefakt prüfen
- [ ] 4. Commit-Signaturen (optional, F2)

## 1. Repo öffentlich stellen (gekko32)

*Settings → General → Danger Zone → Change visibility → Public.*

Warum das sicher ist: Der Inhalt von `environments/mentolder.yaml`
(Adresse, Telefon, USt-ID) ist in Paddione/Bachelorprojekt bereits
öffentlich, die Sealed Secrets sind verschlüsselt. Danach liest Flux das
Repo per HTTPS ohne Secret — es gibt keinen Deploy Key zu verwalten.

## 2. Branch-Protection auf `main` (gekko32)

```bash
gh api -X PUT repos/gekko32/mentolder-prod/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

Danach kann niemand mehr direkt nach `main` pushen, auch gekko32 nicht.
[`CODEOWNERS`](../.github/CODEOWNERS) verlangt nur für `flux/`,
`.github/`, `prod-mentolder/`, `prod-fleet/` und `environments/` einen
Review. PRs, die nur `images.env`, `VENDORED_FROM` oder Doku ändern,
können ohne Review gemergt werden.

## 3. Artefakt

Das Paket `mentolder-manifests` ist öffentlich, der Cluster braucht kein
Registry-Secret. Nach dem ersten Render-Lauf liegt es unter
`ghcr.io/gekko32/mentolder-manifests:latest` (plus `sha-<SHA>`- und
`img-<Hash>`-Tags) und ist per cosign signiert.

## 4. Commit-Signaturen (optional, F2)

Öffentliche Schlüssel (GPG) in ein Secret `gekko-mentolder-git-verify`
legen und am `GitRepository` `spec.verify: {mode: head, secretRef: {name:
gekko-mentolder-git-verify}}` setzen. Commits auf `main` müssen dann
signiert sein. Praktisch als zweiter Schritt, wenn die ersten drei sitzen.
