# CKB Snapshot — Wyltek Industries

Verifiable, GPG-signed CKB mainnet chain snapshots for fast node deployment.

**Latest snapshot:** https://snapshots.wyltekindustries.com/latest.json

---

## Why this exists

Syncing a CKB node from genesis takes 3-7 days on an SBC. This service provides weekly snapshots so you can be up in hours, not days — without trusting raw chain data blindly.

Every snapshot is:
- ✅ SHA256 checksummed
- ✅ GPG signed by toastmanAu (`<your-key-fingerprint-here>`)
- ✅ Accompanied by a metadata JSON with block height + node version

---

## Quick start

```bash
# 1. Get latest snapshot info
curl https://snapshots.wyltekindustries.com/latest.json

# 2. Download snapshot + verification files
wget https://snapshots.wyltekindustries.com/ckb-mainnet-snapshot-YYYYMMDD-blockXXXXXXX.tar.zst
wget https://snapshots.wyltekindustries.com/ckb-mainnet-snapshot-YYYYMMDD-blockXXXXXXX.tar.zst.sha256
wget https://snapshots.wyltekindustries.com/ckb-mainnet-snapshot-YYYYMMDD-blockXXXXXXX.tar.zst.sha256.sig

# 3. Import signing key (one time)
gpg --keyserver keys.openpgp.org --recv-keys <YOUR-KEY-ID>

# 4. Verify (checksum + signature)
./verify-snapshot.sh ckb-mainnet-snapshot-*.tar.zst

# 5. Stop your node, extract, restart
systemctl stop ckb
tar --use-compress-program=zstd -xf ckb-mainnet-snapshot-*.tar.zst -C ~/.ckb/data/
systemctl start ckb
```

---

## Even faster: assume_valid_target

If you're doing a fresh sync, add this to `ckb.toml` to skip script verification
for old blocks (PoW is still verified — this is safe, same as Bitcoin's assumevalid):

```toml
[sync]
assume_valid_target = "0x<recent-block-hash>"
```

Get a recent block hash from: https://explorer.nervos.org

With this set, a full sync takes hours instead of days — no snapshot needed.

---

## Verify the signing key

```bash
gpg --keyserver keys.openpgp.org --recv-keys <YOUR-KEY-ID>
gpg --fingerprint <YOUR-KEY-ID>
# Expected: <YOUR-FINGERPRINT>
```

Cross-check the fingerprint via:
- Nervos Nation Telegram: @NervosNation
- GitHub: https://github.com/toastmanAu

---

## Self-hosting

Want to run your own snapshot service?

```bash
git clone https://github.com/toastmanAu/ckb-snapshot
cd ckb-snapshot
cp snapshot.sh /home/orangepi/ckb-snapshot/
bash setup-r2.sh   # Configure Cloudflare R2
# Install systemd timer for weekly automation
```

---

## Storage & frequency

| What | Detail |
|------|--------|
| Frequency | Weekly (Sunday 2am) |
| Compression | zstd-3 (~30-35% of raw size) |
| Raw DB size | ~80-120GB (grows with chain) |
| Compressed | ~30-45GB |
| Kept online | Last 3 snapshots |
| Hosting | Cloudflare R2 (free egress) |

---

*Wyltek Industries — https://wyltekindustries.com*
