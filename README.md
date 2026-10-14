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
| `environments/sealed-secrets/fleet-mentolder.yaml` | SealedSecrets (an den Cluster-Schluessel gebunden) |
| `UPSTREAM_REF` | gepinnte Bachelorprojekt-Revision |
| `images.env` | gepinnte Image-Digests |

## Ablauf

1. Aenderung hier per PR nach `main`.
2. `.github/workflows/render.yml` checkt upstream bei `UPSTREAM_REF` aus, legt diese Dateien darueber,
   rendert mit `scripts/flux-render-artifact.sh --only mentolder,website-mentolder,sealed-secrets-mentolder`,
   pusht `ghcr.io/gekko32/mentolder-manifests:latest` und signiert es per cosign (keyless).
3. Der Cluster zieht das Artefakt ueber ein `OCIRepository` mit cosign-Verifikation auf
   `gekko32/mentolder-prod/.github/workflows/render.yml@refs/heads/main`.

Upstream-Update: `UPSTREAM_REF` auf die neue Revision setzen, PR, Render muss gruen sein.

## Einschalten

Der Workflow laeuft bei `push` nur mit der Repo-Variable `FLUX_ENABLED=true`. `workflow_dispatch`
laeuft immer.

## Offen

- `workspace-brett` ist privat. Entweder das Paket oeffentlich machen, `gekko32/mentolder-prod`
  unter *Package settings → Manage Actions access* Lesezugriff geben oder `BRETT_IMAGE_DIGEST` pinnen.
