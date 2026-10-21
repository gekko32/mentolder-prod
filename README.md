# mentolder-prod

Willkommen! Dies ist die Betriebsquelle der mentolder-Produktion
(`mentolder.de`). Hier liegt alles, was den mentolder-Stack auf dem Cluster
`gekko-hetzner-2/3/4` ausrollt: Manifeste, Umgebungswerte, verschlüsselte
Secrets und die Flux-Definitionen.

Das Repo ist eigenständig. Die Basen sind vendored (siehe
[`VENDORED_FROM`](./VENDORED_FROM)), die Images liegen unter
`ghcr.io/gekko32/*` und die Secrets SOPS-verschlüsselt unter `secrets/`. Im
Deploy-Pfad gibt es keinen Bezug mehr auf Paddione/Bachelorprojekt.
Kurz gesagt: ein Repo, ein Render, ein signiertes Artefakt.

Hinweise für KI-Agenten stehen in [`AGENTS.md`](./AGENTS.md).

## Index

### Manifeste

| Pfad | Zweck |
|---|---|
| [`k3d/`](./k3d) | Basis-Manifeste des Workspace-Stacks (Nextcloud, Pocket ID, shared-db, brett, CronJobs, …), vendored |
| [`prod/`](./prod) | Prod-Basis darüber (Ingress, Zertifikate, Traefik, Monitoring, Patches), vendored |
| [`prod-mentolder/`](./prod-mentolder) | mentolder-Overlay auf `prod/` (Backup, PVC, whisper, talk-transcriber) |
| [`prod-fleet/platform/`](./prod-fleet/platform) | Cluster-Plattform: cert-manager, Traefik-Basis, Issuer |
| [`prod-fleet/components/`](./prod-fleet/components) | Kustomize-Komponenten (z. B. `fleet-common`) |
| [`prod-fleet/mentolder/`](./prod-fleet/mentolder) | Workspace-Overlay (Sessions, Studio, Brain, Führungsfunk, Replikazahlen, Image-Mapping) |
| [`prod-fleet/website-mentolder/`](./prod-fleet/website-mentolder) | Website (`web.mentolder.de`) |
| [`prod-fleet/website-common/`](./prod-fleet/website-common) | gemeinsame Website-Teile |
| [`prod-fleet/coturn/`](./prod-fleet/coturn) | TURN/Janus für Nextcloud Talk (hostNetwork auf `TURN_NODE`) |
| [`prod-fleet/office/`](./prod-fleet/office) | Collabora (`office.mentolder.de`) |
| [`prod-fleet/rustdesk/`](./prod-fleet/rustdesk) | RustDesk-Relay hbbs/hbbr |

### Werte, Secrets, Images

| Pfad | Zweck |
|---|---|
| [`environments/fleet-mentolder.yaml`](./environments/fleet-mentolder.yaml) | Umgebungswerte, die der Render einsetzt (Domains, Knoten, TURN, Features) |
| [`environments/mentolder.yaml`](./environments/mentolder.yaml) | älteres Profil, nur noch Referenz |
| [`environments/schema.yaml`](./environments/schema.yaml) | Schema aller Variablen und Secret-Schlüssel (`required`, `generate`) |
| [`environments/versions.yaml`](./environments/versions.yaml) | Versionsstände |
| [`secrets/`](./secrets) | Kubernetes-Secrets, SOPS/age-verschlüsselt (`<namespace>/<name>.sops.yaml`) |
| [`.sops.yaml`](./.sops.yaml) | SOPS-Regel (age-Empfänger) |
| [`images.env`](./images.env) | gepinnte Digests aller eigenen Images (leer = `:latest` folgen) |
| [`components/`](./components), [`docker/`](./docker), [`k3d/talk-transcriber/`](./k3d/talk-transcriber), [`rustdesk-installer/`](./rustdesk-installer) | Quellen der eigenen Images (vendored, siehe `VENDORED_FROM`) |

### Flux, CI, Skripte

| Pfad | Zweck |
|---|---|
| [`flux/clusters/fleet/`](./flux/clusters/fleet) | Flux-Einstieg: FluxInstance, OCIRepository, Kustomizations, Receiver |
| [`flux/*.yaml`](./flux) | alte Definitionen (Namespace `gekko-mentolder`), entfallen nach dem Rebuild (Runbook Phase 9) |
| [`.github/workflows/render.yml`](./.github/workflows/render.yml) | rendert und signiert das Artefakt `ghcr.io/gekko32/mentolder-manifests` |
| [`.github/workflows/build-images.yml`](./.github/workflows/build-images.yml) | baut mentolder-web, studio-server, einvoice-sidecar, talk-transcriber |
| [`.github/workflows/build-collabora.yml`](./.github/workflows/build-collabora.yml) | baut collabora-code |
| [`.github/workflows/build-downloads.yml`](./.github/workflows/build-downloads.yml) | baut den RustDesk-Installer (`downloads-content`, privat, nur manuell) |
| [`scripts/`](./scripts) | Render (`flux-render-artifact.sh`), Umgebungsauflösung, Guards |
| [`.github/CODEOWNERS`](./.github/CODEOWNERS) | Pfade mit Review-Pflicht |

### Doku

| Pfad | Zweck |
|---|---|
| [`docs/SETUP.md`](./docs/SETUP.md) | Einrichtung des Repos (Protection, Artefakt, Signaturen) |
| [`docs/runbooks/fresh-cluster-rebuild.md`](./docs/runbooks/fresh-cluster-rebuild.md) | Neuaufbau des Clusters inkl. Backup, Restore, Übergabe |
| [`docs/runbooks/ai-services-scale-zero.md`](./docs/runbooks/ai-services-scale-zero.md) | KI-Dienste ein- und ausschalten |

## Wie es läuft

1. **Ändern:** per Pull Request nach `main`. Pfade mit Wirkung im Cluster
   brauchen den Review von `@gekko32` (siehe [`CODEOWNERS`](./.github/CODEOWNERS)).
   Commits auf `main` müssen signiert sein (Gekkos GPG-Schlüssel oder Merge
   über die GitHub-Weboberfläche), sonst lehnt Flux sie ab.
2. **Rendern:** [`render.yml`](./.github/workflows/render.yml) rendert mit
   `scripts/flux-render-artifact.sh` sechs Komponenten (platform, coturn,
   office, rustdesk, mentolder, website-mentolder), pusht
   `ghcr.io/gekko32/mentolder-manifests:latest` und signiert per cosign
   (keyless). Läufe auf Branches pushen nur `branch-<name>`.
3. **Ausrollen:** Flux im Cluster zieht das Artefakt über das
   `OCIRepository` `mentolder-manifests` mit cosign-Prüfung auf
   `render.yml@refs/heads/main`. Secrets kommen aus `secrets/` (Git),
   entschlüsselt mit `flux-system/sops-age`.

```
PR -> main (signiert) -> render.yml -> ghcr.io/gekko32/mentolder-manifests:latest (cosign)
                                                   |
Flux (flux/clusters/fleet) <------- OCIRepository --+
   |-- mentolder-secrets  (./secrets, SOPS)
   |-- platform -> coturn, office, rustdesk, mentolder-prod, mentolder-prod-website
```

## Betrieb

- **Automatik:** Jeder Merge nach `main` rendert und rollt aus (Repo-Variable
  `FLUX_ENABLED=true`). Alle 20 Minuten prüft `render.yml`, ob eines der
  eigenen Images (`images.env`) ein neues `:latest` hat.
- **Images:** Alle Images unter `ghcr.io/gekko32` entstehen aus Quellen in
  diesem Repo bzw. in den Repos website, brett und fuehrungsfunk. Der Render
  pinnt jedes Image per Digest.
- **Von Hand rendern:** *Actions → Render mentolder artifact → Run workflow*.
- **Status:** `flux get kustomizations -A`, `flux get sources all -A`.
- **Secret ändern:** `sops secrets/<ns>/<name>.sops.yaml`, PR, Merge.
  Klartextwerte liegen in Gekkos Vaultwarden.
- **Upstream-Stand übernehmen:** gezielt vendoren und in `VENDORED_FROM`
  vermerken. Render-Diff gegen vorher prüfen.

## Repo-Secrets und -Variablen

| Name | Art | Zweck |
|---|---|---|
| `FLUX_ENABLED` | Variable | `true` = Render auch bei Push auf `main` |
| `FLUX_WEBHOOK_URL`, `FLUX_WEBHOOK_TOKEN` | Secret, optional | sofortiger Reconcile über den Receiver `flux-webhook` |
| `RUSTDESK_CLIENT_CONFIG_STRING`, `RUSTDESK_UNATTENDED_PASSWORD` | Secret | werden in `build-downloads.yml` in den Installer eingebacken |

## Was nicht hier liegt

| Teil | Ort |
|---|---|
| Website, brett, Führungsfunk | eigene Repos von gekko32 |
| Klartext-Secrets, SOPS-Schlüssel | Gekkos Vaultwarden |
| Entwicklungswerkzeuge, Dev-/Staging-Umgebungen | nicht in Prod |
