#!/bin/bash
# setup-r2.sh — Configure rclone for Cloudflare R2 snapshot hosting
# Run this once on the snapshot host (ckbnode or Pi 5)

set -euo pipefail

echo "=== Cloudflare R2 Setup for CKB Snapshots ==="
echo ""
echo "You'll need from Cloudflare Dashboard → R2 → Manage R2 API Tokens:"
echo "  - Account ID"
echo "  - Access Key ID"
echo "  - Secret Access Key"
echo "  - Bucket name (create one called 'ckb-snapshots')"
echo ""

read -rp "Account ID: " ACCOUNT_ID
read -rp "Access Key ID: " ACCESS_KEY
read -rsp "Secret Access Key: " SECRET_KEY
echo ""
read -rp "Bucket name [ckb-snapshots]: " BUCKET
BUCKET="${BUCKET:-ckb-snapshots}"

# Install rclone if needed
if ! command -v rclone &>/dev/null; then
  echo "Installing rclone..."
  curl https://rclone.org/install.sh | sudo bash
fi

# Write rclone config
mkdir -p ~/.config/rclone
cat >> ~/.config/rclone/rclone.conf << EOF

[r2]
type = s3
provider = Cloudflare
access_key_id = $ACCESS_KEY
secret_access_key = $SECRET_KEY
endpoint = https://${ACCOUNT_ID}.r2.cloudflarestorage.com
acl = public-read
EOF

echo ""
echo "Testing connection..."
rclone ls "r2:$BUCKET" && echo "✓ R2 connection working" || echo "✗ Check credentials"

echo ""
echo "Next steps:"
echo "  1. In Cloudflare R2, enable 'Public Bucket' on $BUCKET"
echo "  2. Set up custom domain: snapshots.wyltekindustries.com → $BUCKET.r2.dev"
echo "  3. Add CNAME in DNS: snapshots → $BUCKET.<account-id>.r2.dev"
echo "  4. Test: curl https://snapshots.wyltekindustries.com/latest.json"
