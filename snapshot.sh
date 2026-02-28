#!/bin/bash
# ckb-snapshot.sh — Stream CKB chain snapshot directly to Cloudflare R2
# Wyltek Industries / toastmanAu
#
# Usage: ./snapshot.sh [--dry-run]
#
# No local disk needed — streams tar | zstd | rclone directly to R2.
# SHA256 is computed inline via tee + sha256sum during the pipe.
# GPG signs the checksum after upload.
#
# Requirements:
#   - rclone configured with r2 remote (run setup-r2.sh)
#   - gpg key set up and published
#   - zstd installed (apt install zstd)
#   - CKB running as systemd service

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CKB_DATA_DIR="${CKB_DATA_DIR:-/home/orangepi/ckb/data/db}"
CKB_DATA_PARENT="${CKB_DATA_PARENT:-/home/orangepi/ckb/data}"  # parent dir for tar -C
CKB_DATA_NAME="${CKB_DATA_NAME:-db}"                            # subdir name inside parent
R2_REMOTE="${R2_REMOTE:-r2:ckb-snapshots}"
R2_PUBLIC_URL="${R2_PUBLIC_URL:-https://snapshots.wyltekindustries.com}"
GPG_KEY="${GPG_KEY:-}"                    # GPG key ID/email; empty = default key
CKB_SERVICE="${CKB_SERVICE:-ckb}"
CKB_RPC="${CKB_RPC:-http://192.168.68.87:8114}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"           # 1=fast, 19=max; 3 is good balance
ZSTD_THREADS="${ZSTD_THREADS:-0}"       # 0 = auto (all cores)
TMP_DIR="${TMP_DIR:-/tmp/ckb-snapshot}" # only used for tiny metadata files
DRY_RUN="${DRY_RUN:-false}"

# ── Parse args ────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --help)
      echo "Usage: $0 [--dry-run]"
      echo "  Streams CKB chain DB directly to Cloudflare R2 — no local disk required."
      echo "  Set env vars to override defaults (see top of script)."
      exit 0 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "ERROR: $*" >&2; cleanup; exit 1; }

cleanup() {
  # Restart CKB if it was stopped and something went wrong
  if [[ "${CKB_STOPPED:-false}" == "true" ]]; then
    log "Restarting CKB after error..."
    sudo systemctl start "$CKB_SERVICE" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT ERR

mkdir -p "$TMP_DIR"

# ── Get tip block height ──────────────────────────────────────────────────────
log "=== CKB Snapshot → R2 Stream ==="
log "Querying CKB tip block..."
TIP=$(curl -sf -X POST "$CKB_RPC" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"get_tip_block_number","params":[],"id":1}' \
  | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null) \
  || { log "WARNING: Could not query RPC, using 'unknown' for block height"; TIP="unknown"; }

DATE=$(date +%Y%m%d)
FILENAME="ckb-mainnet-snapshot-${DATE}-block${TIP}.tar.zst"
SHA_FILE="$TMP_DIR/${FILENAME}.sha256"
META_FILE="$TMP_DIR/${FILENAME%.tar.zst}.json"

log "Block height: $TIP"
log "Filename:     $FILENAME"
log "Destination:  $R2_REMOTE/$FILENAME"
log "Dry run:      $DRY_RUN"
log ""

if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY RUN — would stream: tar $CKB_DATA_PARENT/$CKB_DATA_NAME | zstd -$ZSTD_LEVEL | rclone rcat $R2_REMOTE/$FILENAME"
  log "Estimated size: ~$(du -sh "$CKB_DATA_DIR" 2>/dev/null | cut -f1 || echo '?') raw → ~35% compressed"
  exit 0
fi

# ── Stop CKB cleanly ──────────────────────────────────────────────────────────
log "Stopping CKB ($CKB_SERVICE)..."
sudo systemctl stop "$CKB_SERVICE"
CKB_STOPPED=true
sleep 3

# Verify no lock files
if lsof "$CKB_DATA_DIR" 2>/dev/null | grep -q .; then
  die "CKB DB still locked after stop — aborting"
fi
log "CKB stopped cleanly ✓"

# ── Stream: tar → zstd → tee(sha256) → rclone rcat ──────────────────────────
log "Streaming to R2... (this will take a while)"
log "Pipeline: tar | zstd -T${ZSTD_THREADS} -${ZSTD_LEVEL} | tee sha256 | rclone rcat"

SHA256_VALUE=""

# Use a named pipe for SHA256 so we can compute it inline without buffering to disk
FIFO="$TMP_DIR/sha256_fifo"
mkfifo "$FIFO"

# Start sha256sum reading from the fifo in background
sha256sum "$FIFO" > "$TMP_DIR/sha256_raw" &
SHA_PID=$!

# Run the main pipeline, tee-ing to both rclone and the fifo
tar \
  --use-compress-program="zstd -T${ZSTD_THREADS} -${ZSTD_LEVEL}" \
  -cf - \
  -C "$CKB_DATA_PARENT" \
  "$CKB_DATA_NAME" \
  | tee "$FIFO" \
  | rclone rcat "$R2_REMOTE/$FILENAME" \
    --s3-chunk-size 64M \
    --transfers 1 \
    --no-traverse \
    2>&1 | while IFS= read -r line; do log "  rclone: $line"; done

# Wait for sha256sum to finish
wait $SHA_PID
# sha256sum on the fifo names it as the fifo path — fix that
SHA256_VALUE=$(awk '{print $1}' "$TMP_DIR/sha256_raw")

log "Upload complete ✓"
log "SHA256: $SHA256_VALUE"

# ── Restart CKB immediately ───────────────────────────────────────────────────
log "Restarting CKB..."
sudo systemctl start "$CKB_SERVICE"
CKB_STOPPED=false
log "CKB restarted ✓"

# ── Write and upload checksum ─────────────────────────────────────────────────
echo "$SHA256_VALUE  $FILENAME" > "$SHA_FILE"
log "Uploading checksum..."
rclone copyto "$SHA_FILE" "$R2_REMOTE/${FILENAME}.sha256" --no-traverse

# ── GPG sign the checksum ─────────────────────────────────────────────────────
log "Signing checksum with GPG..."
if [[ -n "$GPG_KEY" ]]; then
  gpg --batch --yes --local-user "$GPG_KEY" --detach-sign "$SHA_FILE"
else
  gpg --batch --yes --detach-sign "$SHA_FILE"
fi
rclone copyto "${SHA_FILE}.sig" "$R2_REMOTE/${FILENAME}.sha256.sig" --no-traverse
log "Signature uploaded ✓"

# ── Write and upload metadata JSON ────────────────────────────────────────────
NODE_VER=$(ssh ckbnode 'ckb --version 2>/dev/null | head -1' 2>/dev/null || echo "unknown")

cat > "$META_FILE" << EOF
{
  "network": "mainnet",
  "block_height": ${TIP//unknown/0},
  "block_height_str": "$TIP",
  "date": "$DATE",
  "filename": "$FILENAME",
  "sha256": "$SHA256_VALUE",
  "created_by": "toastmanAu/ckb-snapshot",
  "node_version": "$NODE_VER",
  "compression": "zstd-${ZSTD_LEVEL}",
  "method": "streaming-r2",
  "urls": {
    "snapshot": "${R2_PUBLIC_URL}/${FILENAME}",
    "sha256":   "${R2_PUBLIC_URL}/${FILENAME}.sha256",
    "sig":      "${R2_PUBLIC_URL}/${FILENAME}.sha256.sig"
  },
  "instructions": {
    "download": "wget ${R2_PUBLIC_URL}/${FILENAME}",
    "verify":   "sha256sum -c ${FILENAME}.sha256",
    "verify_sig": "gpg --verify ${FILENAME}.sha256.sig ${FILENAME}.sha256",
    "extract":  "tar --use-compress-program=zstd -xf ${FILENAME} -C ~/.ckb/data/",
    "note":     "Stop your CKB node before extracting. Start it after."
  }
}
EOF

rclone copyto "$META_FILE" "$R2_REMOTE/${FILENAME%.tar.zst}.json" --no-traverse

# ── Update latest.json ────────────────────────────────────────────────────────
cat > "$TMP_DIR/latest.json" << EOF
{
  "latest":        "$FILENAME",
  "block_height":  ${TIP//unknown/0},
  "date":          "$DATE",
  "snapshot_url":  "${R2_PUBLIC_URL}/${FILENAME}",
  "sha256_url":    "${R2_PUBLIC_URL}/${FILENAME}.sha256",
  "sig_url":       "${R2_PUBLIC_URL}/${FILENAME}.sha256.sig",
  "meta_url":      "${R2_PUBLIC_URL}/${FILENAME%.tar.zst}.json"
}
EOF

rclone copyto "$TMP_DIR/latest.json" "$R2_REMOTE/latest.json" --no-traverse
log "Updated latest.json ✓"

# ── Prune old R2 snapshots (keep 3) ──────────────────────────────────────────
log "Pruning old R2 snapshots (keeping 3 most recent)..."
rclone ls "$R2_REMOTE" --include "*.tar.zst" 2>/dev/null \
  | awk '{print $2}' \
  | sort \
  | head -n -3 \
  | while read -r old; do
      log "  Deleting: $old"
      rclone delete "$R2_REMOTE/$old" 2>/dev/null || true
      rclone delete "$R2_REMOTE/${old}.sha256" 2>/dev/null || true
      rclone delete "$R2_REMOTE/${old}.sha256.sig" 2>/dev/null || true
      rclone delete "$R2_REMOTE/${old%.tar.zst}.json" 2>/dev/null || true
    done

# ── Done ─────────────────────────────────────────────────────────────────────
log ""
log "=== Snapshot complete ==="
log "File:    $FILENAME"
log "SHA256:  $SHA256_VALUE"
log "URL:     ${R2_PUBLIC_URL}/${FILENAME}"
log "Latest:  ${R2_PUBLIC_URL}/latest.json"
