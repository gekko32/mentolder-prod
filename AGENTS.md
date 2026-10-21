# AGENTS.md

Hinweise für KI-Agenten (Claude Code, Codex, Copilot u. a.) in diesem Repo.
Überblick und Index: [`README.md`](./README.md).

## Was dieses Repo ist

Die GitOps-Quelle der **Produktion** von mentolder.de. Jeder Merge nach `main`
wird gerendert, signiert und von Flux auf den Live-Cluster ausgerollt. Es gibt
keine Staging-Stufe dazwischen. Behandle jede Änderung als Produktionsänderung.

## Feste Regeln

1. **Nie direkt nach `main` pushen, nie selbst mergen.** Änderungen nur als
   Branch und Draft-PR. Gemergt wird von `@gekko32`. Flux akzeptiert nur
   signierte Commits auf `main`.
2. **Keine Secret-Werte** in Dateien, Commits, PR-Texten, Logs oder im Chat.
   Nur Schlüsselnamen, Anzahlen oder SHA-256-Präfixe (8 Zeichen).
3. **Secrets nur verschlüsselt.** Unter `secrets/` liegen ausschließlich
   SOPS-Dateien (`*.sops.yaml` mit `sops:`-Block). Klartext-Secrets nie
   committen, auch nicht kurzzeitig. Vor jedem Commit prüfen:
   `grep -rL '^sops:' secrets --include='*.sops.yaml'` muss leer sein.
4. **Eigene Images nie überschreiben:** `ghcr.io/gekko32/{brett,website,fuehrungsfunk}`
   bauen ihre eigenen Repos. Alle übrigen Images baut dieses Repo aus seinen Quellen
   (`build-images.yml`, `build-collabora.yml`, `build-downloads.yml`).
5. **Keine Referenzen auf `ghcr.io/paddione/*`** im Render, kein Kopieren von dort.
   Ein neues Image bekommt Quellen und Build-Job hier, einen Eintrag in `images.env`
   und einen `resolve`/`kustomize edit set image`-Schritt in `render.yml`.
6. **Datengebundene Werte nie neu erzeugen:** `*_DB_PASSWORD`, Postgres-Superuser,
   Nextcloud `secret`/`passwordsalt`/`instanceid`, Pocket-ID-Encryption-Key,
   OIDC-Client-Secrets, Signaling/TURN-Secrets. Sie passen zu vorhandenen Daten.
7. **Destruktive Cluster-Aktionen** (Löschen, Skalieren auf 0, Rebuild,
   Restore) nur auf ausdrückliche Anweisung des Operators und nach dem Runbook.

## Wie eine Änderung abläuft

1. Branch von `main`, Änderung im passenden Overlay. Basen in `k3d/` und
   `prod/` möglichst nicht anfassen, lieber per Patch im Overlay ändern.
2. Lokal rendern und prüfen:

   ```bash
   export WEBSITE_IMAGE_DIGEST=$(crane digest ghcr.io/gekko32/website:latest)
   export BRETT_IMAGE_DIGEST=$(crane digest ghcr.io/gekko32/brett:latest)
   export STUDIO_IMAGE_DIGEST=$(crane digest ghcr.io/gekko32/studio-server:latest)
   CI=true bash scripts/flux-render-artifact.sh --out /tmp/out
   grep -rc 'ghcr.io/paddione' /tmp/out   # muss 0 sein
   ```

   Das Validierungs-Gate am Ende muss grün sein.
3. Render-Diff gegen `main` erstellen und im PR zusammenfassen:
   was ändert sich im Cluster, welche Pods starten neu.
4. Draft-PR öffnen. Optional `render.yml` per `workflow_dispatch` auf dem
   Branch laufen lassen. Das pusht nur `branch-<name>` und berührt Flux nicht.

## Wo was hingehört

| Änderung | Ort |
|---|---|
| Domain, Knoten, Feature-Schalter, TURN | `environments/fleet-mentolder.yaml` (Variable vorher in `environments/schema.yaml` definieren) |
| Workspace-Dienst ein-/ausschalten | `prod-fleet/mentolder/kustomization.yaml`, Abschnitt `replicas` |
| Image-Version | `images.env` (leer = `:latest` folgen, `sha256:...` pinnt) |
| Image-Quellcode | `components/`, `docker/`, `k3d/talk-transcriber/`, `rustdesk-installer/` |
| neues Secret oder Secret-Wert | `secrets/<ns>/<name>.sops.yaml` per `sops` |
| neue Flux-Kustomization | `flux/clusters/fleet/` |
| Website | `prod-fleet/website-mentolder/` |

## Render-Details, die überraschen

- Variablen `${VAR}` werden per `envsubst` aus `environments/fleet-mentolder.yaml`
  gesetzt (Whitelist in `scripts/lib/render-subst-list.sh`). `$${VAR}` bleibt als
  Laufzeitvariable im Container stehen.
- `kustomize build` allein zeigt noch die `${VAR}`-Platzhalter. Werte erst im
  Render prüfen.
- Platzhalter-Digests (`sha256:1111…`, `sha256:2222…`) lassen den Render
  absichtlich scheitern.
- Office (Collabora) bekommt seine `COLLABORA_*`-Werte im Render-Skript, nicht aus
  der Umgebungsdatei.

## Zugriff und Werkzeuge

- Cluster-Zugang hat der Operator über die Ops-Instanz `gekko-ops` (WSL) mit
  Kubeconfig `~/.kube/fleet`. Agenten ohne diese Instanz arbeiten nur am Repo.
- Werkzeuge: `kustomize`, `flux`, `sops`, `age`, `yq`, `jq`, `crane`, `cosign`
  (Versionen siehe `versions.lock` in der Ops-Instanz).
- Für Betriebsabläufe (Neuaufbau, Backup, Restore) gilt
  [`docs/runbooks/fresh-cluster-rebuild.md`](./docs/runbooks/fresh-cluster-rebuild.md)
  mit seinen GATEs.
