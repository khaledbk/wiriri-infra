# cdn.wiriri.com — image CDN (MinIO + imgproxy, no Cloudflare)

Self-hosted media CDN: **nginx (web-01 edge) → imgproxy (storage-01) → MinIO (storage-01)**,
all over the private VPC. Replaces Cloudinary. Full design: `../../docs/spec/SPEC-2026-06-26-storage-minio-cdn.md`.

## Pieces in this folder
| File | What | Goes where |
|------|------|-----------|
| `nginx-cdn.conf` | the new `cdn.wiriri.com` server block (imgproxy + presigned passthrough) | replaces the cdn stub in `../web-01/nginx/default.conf` (full merged file: `../web-01/nginx/default.conf.cdn-proposed`) |
| `imgproxy.compose.yml` | imgproxy service fragment | add to storage-01 compose (merged: `../storage-01/docker-compose.cdn-proposed.yml`) |
| `.env.example` | imgproxy key/salt + read-only MinIO creds | on-box `.env` (values from Infisical) |

## Status (2026-06-26)
- ✅ MinIO live on storage-01; buckets `wiriri-prod-images` / `wiriri-prod-private`, backend user `wiriri_backend_minio` + policy, `S3_*` env in Infisical.
- ✅ TLS cert already covers `cdn.wiriri.com` (certbot webroot, shared `wiriri.com` SAN cert).
- ✅ web-01 → MinIO `:9000` firewall already open.
- ✅ **imgproxy read-only user `wiriri_imgproxy_ro`** + policy created (GetObject/ListBucket on images only).
- ✅ **imgproxy DEPLOYED + VALIDATED** on `10.130.18.7:8080` (`docker-compose.imgproxy.yml`): `/health` 200, signed transform 200, unsigned 403. Keys in `/opt/wiriri/imgproxy.env` (600).
- ✅ **Firewall** — CloudAxion `:8080 from 10.130.18.3/32` added; web-01 reaches imgproxy + MinIO.
- ✅ **cdn.wiriri.com nginx vhost LIVE** (`../web-01/nginx/default.conf`): `/img/*`→imgproxy (edge-cached) + presigned passthrough. Validated 2026-06-26: cdn `/img` 200, `X-Cache MISS→HIT`, unsigned 403, other sites unaffected. (proxy_cache is in-container/ephemeral; add a host mount for persistence later.)

## Remaining to finish cluster S (app phase)
1. **[owner] Infisical** — store `IMGPROXY_KEY` / `IMGPROXY_SALT` (from `/opt/wiriri/imgproxy.env`) in all 3 stages; the **backend** needs them to sign `/img/` URLs.
2. **Backend `StorageModule`** — presign (signed vs `cdn.wiriri.com`), resolver builds `/img/` URLs, ID/KYC proxy, invoice presign. Then the **presigned PUT/GET passthrough** gets its real validation (a backend-minted round-trip).
3. **webapp uploader** + CSP/remotePatterns/seo → cdn.
4. **Backfill** property images (dry-run + owner approval), flip, decommission Cloudinary.

> All changes are **read-only-first**: validate `nginx -t` and a throwaway object before flipping app reads.
