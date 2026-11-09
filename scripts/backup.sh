#!/usr/bin/env bash
# PDFin backup — archives every Stirling-PDF volume (configs incl. H2 DB, storage, customFiles, pipeline, tessdata, logs).
# Usage: scripts/backup.sh [--hot] [BACKUP_DIR]
#   default: stop container briefly (~1 min) for a consistent H2 copy, then start it again.
#   --hot  : no downtime; relies on Stirling's own DB backups in /configs/backup/db for consistency.
# Never deletes volumes. Keeps the newest $KEEP archives.
set -euo pipefail
HOT=0; [[ "${1:-}" == "--hot" ]] && { HOT=1; shift; }
DEST="${1:-/data/backups/pdfin}"; KEEP="${KEEP:-14}"
CTR=$(docker ps -a --filter label=com.docker.compose.service=stirling-pdf \
      --format '{{.Names}} {{.Label "com.docker.compose.project"}}' | grep -v smoke | head -1 | awk '{print $1}')
[[ -n "$CTR" ]] || { echo "PDFin container not found" >&2; exit 1; }
IMG=$(docker inspect -f '{{.Config.Image}}' "$CTR")
VER=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMG" 2>/dev/null || echo unknown)
TS=$(date +%Y%m%d-%H%M%S); NAME="pdfin-${VER}-${TS}.tar.gz"
mkdir -p "$DEST"; [[ -w "$DEST" ]] || { echo "$DEST not writable (sudo mkdir -p $DEST && sudo chown $USER $DEST)" >&2; exit 1; }

was_running=$(docker inspect -f '{{.State.Running}}' "$CTR")
if [[ $HOT == 0 && "$was_running" == true ]]; then echo "stopping $CTR for consistent backup"; docker stop -t 60 "$CTR" >/dev/null; fi
restart(){ [[ $HOT == 0 && "$was_running" == true ]] && docker start "$CTR" >/dev/null && echo "started $CTR"; }
trap restart EXIT

# Reuse the app image (already local) as the tar helper; mounts are read-only.
docker run --rm --network none --entrypoint tar --volumes-from "$CTR:ro" -v "$DEST:/backup" "$IMG" \
  czf "/backup/$NAME" /configs /storage /customFiles /pipeline /usr/share/tessdata /logs
docker inspect "$CTR" --format '{{json .Mounts}}' > "$DEST/${NAME%.tar.gz}.mounts.json"
sha256sum "$DEST/$NAME" > "$DEST/$NAME.sha256"
echo "backup: $DEST/$NAME ($(du -h "$DEST/$NAME" | cut -f1))"
ls -1t "$DEST"/pdfin-*.tar.gz | tail -n +$((KEEP+1)) | while read -r f; do rm -f "$f" "$f.sha256" "${f%.tar.gz}.mounts.json"; echo "pruned $f"; done
