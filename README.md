# mentolder-prod

Betriebsquelle der mentolder-Produktion. Die Basen (`k3d/`, `prod/`, Render-Skripte) bleiben in
[Paddione/Bachelorprojekt](https://github.com/Paddione/Bachelorprojekt) und werden bei der in
`UPSTREAM_REF` gepinnten Revision ausgecheckt.

## Inhalt

| Pfad | Zweck |
|---|---|
| `prod-mentolder/` | Kustomize-Overlay auf `prod/` (Backup, PVC, brett, whisper, talk-transcriber) |
| `prod-fleet/mentolder/` | Fleet-Overlay (Sessions, Studio, Brain, Monitoring) |
| `prod-fleet/website-mentolder/` | Website-Overlay |
| `environments/mentolder.yaml`, `fleet-mentolder.yaml` | Umgebungsvariablen |
| `UPSTREAM_REF` | gepinnte Bachelorprojekt-Revision |
| `images.env` | gepinnte Image-Digests |

## Ablauf

1. Aenderung hier per PR nach `main`.
2. `.github/workflows/render.yml` checkt upstream bei `UPSTREAM_REF` aus, legt diese Dateien darueber,
   rendert mit `scripts/flux-render-artifact.sh --only mentolder,website-mentolder`,
   pusht `ghcr.io/gekko32/mentolder-manifests:latest` und signiert es per cosign (keyless).
3. Der Cluster zieht das Artefakt ueber ein `OCIRepository` mit cosign-Verifikation auf
   `gekko32/mentolder-prod/.github/workflows/render.yml@refs/heads/main`.

Upstream-Update: `UPSTREAM_REF` auf die neue Revision setzen, PR, Render muss gruen sein.

## Flux-Definitionen (`flux/`)

`flux/` enthaelt `OCIRepository` und Kustomizations fuer mentolder. Alle Objekte liegen im Namespace `gekko-mentolder` und laufen als `gekko-mentolder-deploy`
(erzwungen per ValidatingAdmissionPolicy in Bachelorprojekt). Die Namen sind bewusst neu
(`mentolder-prod*`). Die SealedSecrets (`flux-sealed-secrets-mentolder`) und die Plattform bleiben in
Paddione/Bachelorprojekt, `mentolder-prod` haengt per `dependsOn` davon ab.
Sie werden erst angewendet, wenn der Cluster dieses Verzeichnis liest: dazu legt Bachelorprojekt ein
`GitRepository` auf dieses Repo plus eine `Kustomization` mit `path: ./flux` an.

Umstellung (nicht vorher): alte `flux-mentolder*` suspendieren und mit
`kustomize.toolkit.fluxcd.io/prune: disabled` absichern, neue Kustomizations reconcilen lassen, erst dann
die alten entfernen. Ein Entfernen mit `prune: true` loescht sonst die Workloads.

## Einschalten

Der Workflow laeuft bei `push` nur mit der Repo-Variable `FLUX_ENABLED=true`. `workflow_dispatch`
laeuft immer.

## Offen

- `workspace-brett` ist privat. Entweder das Paket oeffentlich machen, `gekko32/mentolder-prod`
  unter *Package settings → Manage Actions access* Lesezugriff geben oder `BRETT_IMAGE_DIGEST` pinnen.
