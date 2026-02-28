#!/bin/bash
# verify-snapshot.sh — Verify a CKB snapshot before using it
# Usage: ./verify-snapshot.sh <snapshot.tar.zst> [gpg-key-fingerprint]

set -euo pipefail

SNAPSHOT="${1:-}"
EXPECTED_KEY="${2:-}"  # Optional: expected GPG key fingerprint

[[ -z "$SNAPSHOT" ]] && { echo "Usage: $0 <snapshot.tar.zst> [gpg-fingerprint]"; exit 1; }
[[ -f "$SNAPSHOT" ]]  || { echo "File not found: $SNAPSHOT"; exit 1; }

log() { echo "[verify] $*"; }
ok()  { echo "[  OK  ] $*"; }
fail(){ echo "[FAILED] $*" >&2; exit 1; }

# Check SHA256
SHA_FILE="${SNAPSHOT}.sha256"
SIG_FILE="${SNAPSHOT}.sha256.sig"

[[ -f "$SHA_FILE" ]] || fail "Missing checksum file: $SHA_FILE"

log "Verifying SHA256 checksum..."
sha256sum -c "$SHA_FILE" && ok "Checksum matches" || fail "Checksum mismatch — file corrupted or tampered"

# Check GPG signature if sig file present
if [[ -f "$SIG_FILE" ]]; then
  log "Verifying GPG signature..."
  GPG_OUT=$(gpg --verify "$SIG_FILE" "$SHA_FILE" 2>&1)
  echo "$GPG_OUT"

  if echo "$GPG_OUT" | grep -q "Good signature"; then
    ok "GPG signature valid"
    
    # Optionally verify it's from the expected key
    if [[ -n "$EXPECTED_KEY" ]]; then
      if echo "$GPG_OUT" | grep -qi "$EXPECTED_KEY"; then
        ok "Signed by expected key: $EXPECTED_KEY"
      else
        fail "Signed by UNKNOWN key — expected $EXPECTED_KEY"
      fi
    fi
  else
    fail "GPG signature invalid"
  fi
else
  log "No .sig file found — skipping GPG verification (checksum only)"
fi

ok "Snapshot verified: $SNAPSHOT"
log "Safe to extract with: tar --use-compress-program=zstd -xf '$SNAPSHOT' -C ~/.ckb/data/"
