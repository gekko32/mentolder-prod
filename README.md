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
| `docs/SETUP.md` | Schritt-für-Schritt-Einrichtung vor der Umstellung |
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

Der Cluster liest dieses Verzeichnis erst, wenn Bachelorprojekt ein
`GitRepository` auf dieses Repo plus eine `Kustomization` mit
`path: ./flux` anlegt.

> **Umstellung — bitte in dieser Reihenfolge:** alte `flux-mentolder*`
> suspendieren und mit `kustomize.toolkit.fluxcd.io/prune: disabled`
> absichern, neue Kustomizations reconcilen lassen, erst dann die alten
> entfernen. Ein Entfernen mit `prune: true` löscht sonst die Workloads.

## Einschalten

Der Workflow läuft bei `push` nur mit der Repo-Variablen
`FLUX_ENABLED=true`. `workflow_dispatch` läuft immer — gut zum
Ausprobieren ohne den Automatik-Betrieb einzuschalten.

## Noch offen

- `workspace-brett` ist privat. Entweder das Paket öffentlich machen,
  `gekko32/mentolder-prod` unter *Package settings → Manage Actions
  access* Lesezugriff geben oder `BRETT_IMAGE_DIGEST` in
  [`images.env`](./images.env) pinnen.

## Nächster Schritt

Weiter geht es mit der [Einrichtung vor der Umstellung](./docs/SETUP.md) —
vier kurze Schritte, danach ist der Betrieb bereit.
