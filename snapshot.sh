#!/bin/bash
# ckb-snapshot.sh — Create, sign, and upload a verifiable CKB chain snapshot
# Wyltek Industries / toastmanAu
#
# Usage: ./snapshot.sh [--upload] [--dry-run]
#
# Requirements:
#   - rclone configured with R2 remote (see README)
#   - gpg key set up (see README)
#   - CKB running as systemd service named 'ckb'

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CKB_DATA_DIR="${CKB_DATA_DIR:-/home/orangepi/.ckb/data/db}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/home/orangepi/snapshots}"
R2_REMOTE="${R2_REMOTE:-r2:ckb-snapshots}"          # rclone remote:bucket
GPG_KEY="${GPG_KEY:-}"                               # GPG key ID or email; empty = default
MAX_SNAPSHOTS="${MAX_SNAPSHOTS:-3}"                  # Keep N snapshots locally
CKB_SERVICE="${CKB_SERVICE:-ckb}"                    # systemd service name
CKB_RPC="${CKB_RPC:-http://localhost:8114}"          # CKB RPC endpoint
UPLOAD="${UPLOAD:-false}"
DRY_RUN="${DRY_RUN:-false}"

# ── Parse args ────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --upload)   UPLOAD=true ;;
    --dry-run)  DRY_RUN=true ;;
    --help)
      echo "Usage: $0 [--upload] [--dry-run]"
      echo "  --upload   Upload to Cloudflare R2 after creating snapshot"
      echo "  --dry-run  Show what would happen without doing it"
      exit 0
      ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "ERROR: $*" >&2; exit 1; }
run()  { if [[ "$DRY_RUN" == "true" ]]; then log "DRY-RUN: $*"; else "$@"; fi; }

# ── Get current block height from node ────────────────────────────────────────
get_tip_block() {
  curl -sf -X POST "$CKB_RPC" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"get_tip_block_number","params":[],"id":1}' \
    | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null \
    || echo "unknown"
}

# ── Main ──────────────────────────────────────────────────────────────────────
mkdir -p "$SNAPSHOT_DIR"

log "=== CKB Snapshot ==="
log "Data dir:    $CKB_DATA_DIR"
log "Snapshot dir: $SNAPSHOT_DIR"
log "Upload:      $UPLOAD"
log "Dry run:     $DRY_RUN"

# Get block height before stopping
log "Querying tip block height..."
TIP=$(get_tip_block)
log "Current tip: block $TIP"

DATE=$(date +%Y%m%d)
FILENAME="ckb-mainnet-snapshot-${DATE}-block${TIP}.tar.zst"
FILEPATH="$SNAPSHOT_DIR/$FILENAME"

# Stop CKB cleanly (RocksDB must be closed before archiving)
log "Stopping CKB service..."
run sudo systemctl stop "$CKB_SERVICE"
sleep 3  # Let RocksDB flush

# Verify DB is not locked
if [[ "$DRY_RUN" != "true" ]]; then
  if lsof "$CKB_DATA_DIR" 2>/dev/null | grep -q .; then
    sudo systemctl start "$CKB_SERVICE"
    die "CKB DB still locked — aborting. Service restarted."
  fi
fi

log "Creating snapshot: $FILENAME"
log "Compressing with zstd (fast, ~3:1 ratio)..."

run tar \
  --use-compress-program="zstd -T0 -3" \
  -cf "$FILEPATH" \
  -C "$(dirname "$CKB_DATA_DIR")" \
  "$(basename "$CKB_DATA_DIR")"

# Restart CKB immediately after archive starts (tar streams, node is safe to restart)
# Actually wait for tar to finish first for safety
log "Restarting CKB service..."
run sudo systemctl start "$CKB_SERVICE"

if [[ "$DRY_RUN" != "true" ]]; then
  SIZE=$(du -sh "$FILEPATH" | cut -f1)
  log "Snapshot size: $SIZE"
fi

# Generate SHA256 checksum
log "Generating checksum..."
run bash -c "cd '$SNAPSHOT_DIR' && sha256sum '$FILENAME' > '${FILENAME}.sha256'"

# GPG sign the checksum file
log "Signing checksum with GPG..."
if [[ -n "$GPG_KEY" ]]; then
  run gpg --batch --yes --local-user "$GPG_KEY" --detach-sign "${FILEPATH}.sha256"
else
  run gpg --batch --yes --detach-sign "${FILEPATH}.sha256"
fi

# Write metadata JSON
META_FILE="${FILEPATH%.tar.zst}.json"
if [[ "$DRY_RUN" != "true" ]]; then
  cat > "$META_FILE" << EOF
{
  "network": "mainnet",
  "block_height": $TIP,
  "date": "$DATE",
  "filename": "$FILENAME",
  "sha256": "$(cut -d' ' -f1 "${FILEPATH}.sha256")",
  "created_by": "toastmanAu/ckb-snapshot",
  "node_version": "$(ssh ckbnode 'ckb --version 2>/dev/null | head -1' 2>/dev/null || echo 'unknown')",
  "compressed_size_bytes": $(stat -c%s "$FILEPATH" 2>/dev/null || echo 0),
  "compression": "zstd-3",
  "instructions": {
    "download": "wget https://snapshots.wyltekindustries.com/$FILENAME",
    "verify": "sha256sum -c ${FILENAME}.sha256",
    "verify_sig": "gpg --verify ${FILENAME}.sha256.sig ${FILENAME}.sha256",
    "extract": "tar --use-compress-program=zstd -xf $FILENAME -C ~/.ckb/data/",
    "note": "Stop your CKB node before extracting. Start it after."
  }
}
EOF
  log "Metadata written: $META_FILE"
fi

# Upload to Cloudflare R2
if [[ "$UPLOAD" == "true" ]]; then
  log "Uploading to R2: $R2_REMOTE"
  
  # Upload snapshot
  run rclone copy "$FILEPATH" "$R2_REMOTE" \
    --progress \
    --transfers 4 \
    --s3-chunk-size 64M

  # Upload checksums + sig + metadata
  run rclone copy "${FILEPATH}.sha256"      "$R2_REMOTE"
  run rclone copy "${FILEPATH}.sha256.sig"  "$R2_REMOTE"
  if [[ -f "$META_FILE" ]]; then
    run rclone copy "$META_FILE" "$R2_REMOTE"
  fi

  # Update latest.json pointer
  if [[ "$DRY_RUN" != "true" ]]; then
    cat > "$SNAPSHOT_DIR/latest.json" << EOF
{
  "latest": "$FILENAME",
  "block_height": $TIP,
  "date": "$DATE",
  "sha256_url": "https://snapshots.wyltekindustries.com/${FILENAME}.sha256",
  "sig_url": "https://snapshots.wyltekindustries.com/${FILENAME}.sha256.sig",
  "snapshot_url": "https://snapshots.wyltekindustries.com/$FILENAME",
  "meta_url": "https://snapshots.wyltekindustries.com/${FILENAME%.tar.zst}.json"
}
EOF
    run rclone copy "$SNAPSHOT_DIR/latest.json" "$R2_REMOTE"
    log "Updated latest.json"
  fi

  log "Upload complete ✓"
fi

# Prune old local snapshots (keep MAX_SNAPSHOTS most recent)
if [[ "$DRY_RUN" != "true" ]]; then
  log "Pruning old snapshots (keeping $MAX_SNAPSHOTS)..."
  ls -t "$SNAPSHOT_DIR"/*.tar.zst 2>/dev/null \
    | tail -n "+$((MAX_SNAPSHOTS + 1))" \
    | while read -r old; do
        log "  Removing: $(basename "$old")"
        rm -f "$old" "${old}.sha256" "${old}.sha256.sig" "${old%.tar.zst}.json"
      done
fi

log "=== Done ==="
log "Snapshot: $FILENAME"
if [[ "$DRY_RUN" != "true" ]]; then
  log "Size:     $(du -sh "$FILEPATH" | cut -f1)"
  log "SHA256:   $(cut -d' ' -f1 "${FILEPATH}.sha256")"
fi
