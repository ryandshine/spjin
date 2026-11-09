#!/usr/bin/env bash
# PDFin restore — restores a backup archive INTO the existing volumes of the PDFin container.
# Usage: scripts/restore.sh /data/backups/pdfin/pdfin-<ver>-<ts>.tar.gz
# Destructive for current volume CONTENT (volumes themselves are kept). Asks for confirmation.
# Takes a safety --hot backup of the current state first.
set -euo pipefail
ARC="${1:?archive path}"; [[ -f "$ARC" ]] || { echo "no such file $ARC" >&2; exit 1; }
[[ -f "$ARC.sha256" ]] && sha256sum -c "$ARC.sha256"
CTR=$(docker ps -a --filter label=com.docker.compose.service=stirling-pdf --format '{{.Names}}' | grep -v smoke | head -1)
[[ -n "$CTR" ]] || { echo "PDFin container not found" >&2; exit 1; }
IMG=$(docker inspect -f '{{.Config.Image}}' "$CTR")
echo "Container: $CTR  Image: $IMG"; echo "Archive  : $ARC"
echo "Archive was made from version: $(basename "$ARC" | cut -d- -f2). Use the same image version (STIRLING_VERSION) when restoring."
read -r -p "Replace current PDFin data with this archive? type RESTORE: " a; [[ "$a" == RESTORE ]] || { echo aborted; exit 1; }
"$(dirname "$0")/backup.sh" --hot "$(dirname "$ARC")/pre-restore" || true
docker stop -t 60 "$CTR" >/dev/null
docker run --rm --network none --entrypoint sh --volumes-from "$CTR" -v "$(cd "$(dirname "$ARC")" && pwd):/backup:ro" "$IMG" -c '
  set -e
  for d in /configs /storage /customFiles /pipeline /usr/share/tessdata /logs; do find "$d" -mindepth 1 -delete; done
  tar xzf "/backup/'"$(basename "$ARC")"'" -C /
  chown -R 1000:1000 /configs /storage /customFiles /pipeline /logs'
docker start "$CTR" >/dev/null
echo "restored; waiting for health..."
for i in $(seq 1 40); do s=$(docker inspect -f '{{.State.Health.Status}}' "$CTR"); [[ $s == healthy ]] && break; sleep 5; done; echo "health=$s"
