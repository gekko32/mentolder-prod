# mentolder-prod

Willkommen! Dies ist die Betriebsquelle der mentolder-Produktion
(`mentolder.de`) — also der Ort, an dem alles liegt, was den
mentolder-Stack im Cluster ausrollt.

Die schweren Basen (`k3d/`, `prod/`, Render-Skripte) bleiben bewusst in
[Paddione/Bachelorprojekt](https://github.com/Paddione/Bachelorprojekt).
Dieses Repo legt nur die mentolder-Schicht darüber und checkt die Basis
bei der in [`UPSTREAM_REF`](./UPSTREAM_REF) gepinnten Revision aus.
So bleibt die Produktion nachvollziehbar: ein Pin, ein Render, ein Artefakt.

## Was wo liegt

| Pfad | Zweck |
|---|---|
| `prod-mentolder/` | Kustomize-Overlay auf `prod/` (Backup, PVC, brett, whisper, talk-transcriber) |
| `prod-fleet/mentolder/` | Fleet-Overlay (Sessions, Studio, Brain, Monitoring) |
| `prod-fleet/website-mentolder/` | Website-Overlay (`web.mentolder.de`) |
| `environments/mentolder.yaml`, `environments/fleet-mentolder.yaml` | Umgebungsvariablen für mentolder |
| `flux/` | `OCIRepository` + Kustomizations (`mentolder-prod*`, Namespace `gekko-mentolder`) |
| `docs/SETUP.md` | Einrichtung des Repos (Protection, Artefakt, Signaturen) |
| `.github/workflows/render.yml` | Baut und signiert das Deploy-Artefakt |
| `UPSTREAM_REF` | Gepinnte Bachelorprojekt-Revision |
| `images.env` | Gepinnte Image-Digests (leer = `:latest` folgen) |

## Wie es läuft

1. **Ändern:** per Pull Request nach `main`. Doku, `UPSTREAM_REF` und
   `images.env` brauchen keinen Review; alles unter `flux/`, `.github/`,
   `prod-mentolder/`, `prod-fleet/` und `environments/` schon
   (siehe [`CODEOWNERS`](./.github/CODEOWNERS)).
2. **Rendern:** [`.github/workflows/render.yml`](./.github/workflows/render.yml)
   checkt Upstream bei `UPSTREAM_REF` aus, legt diese Dateien darüber und
   rendert mit `scripts/flux-render-artifact.sh --only mentolder,website-mentolder`.
   Das Ergebnis wird als `ghcr.io/gekko32/mentolder-manifests:latest`
   gepusht und per cosign (keyless) signiert.
3. **Ausrollen:** Der Cluster zieht das Artefakt über ein `OCIRepository`
   mit cosign-Verifikation auf
   `gekko32/mentolder-prod/.github/workflows/render.yml@refs/heads/main`.

**Upstream-Update:** `UPSTREAM_REF` auf die neue Revision setzen, PR
öffnen, Render muss grün sein — fertig.

## Flux-Definitionen (`flux/`)

`flux/` enthält `OCIRepository` und die Kustomizations für mentolder.
Alle Objekte laufen im Namespace `gekko-mentolder` als
`gekko-mentolder-deploy` (erzwungen per ValidatingAdmissionPolicy in
Bachelorprojekt). Die Namen sind bewusst neu (`mentolder-prod*`).

Zwei Dinge bleiben absichtlich draußen und in
Paddione/Bachelorprojekt: die SealedSecrets
(`flux-sealed-secrets-mentolder`) und die Plattform. `mentolder-prod`
hängt per `dependsOn` davon ab und reconcilt erst danach.

Der Cluster liest dieses Verzeichnis über das `GitRepository`
`gekko-mentolder-prod` und die Kustomization `gekko-mentolder-flux`
(beide in `flux-system`, angelegt von Bachelorprojekt).

## Betrieb

- **Automatik:** Jeder Merge nach `main` rendert und rollt aus
  (Repo-Variable `FLUX_ENABLED=true`). Zusätzlich prüft der Workflow alle
  20 Minuten, ob es neue Images `website:latest` oder `gekko32/brett:latest`
  gibt, und rendert dann neu.
- **Von Hand:** *Actions → Render mentolder artifact → Run workflow*.
- **Status im Cluster:** `flux get kustomizations -n gekko-mentolder`.

## Was nicht hier liegt

| Teil | Ort |
|---|---|
| Basen, Render-Skripte | Paddione/Bachelorprojekt bei `UPSTREAM_REF` |
| SealedSecrets (`flux-sealed-secrets-mentolder`) | Paddione/Bachelorprojekt |
| Plattform (Traefik, cert-manager, coturn) | Paddione/Bachelorprojekt |
| Images `ghcr.io/paddione/*` | CI von Paddione/Bachelorprojekt |
| Entwicklungswerkzeuge | nicht in Prod (dotfiles bzw. Dev-Cluster) |
