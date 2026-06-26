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

## Remaining steps to go live
1. **[owner] Firewall** — CloudAxion: allow web-01 (`10.130.18.3`) → storage-01 `:8080`.
2. **[owner] Infisical** — store `IMGPROXY_KEY` / `IMGPROXY_SALT` (from `/opt/wiriri/imgproxy.env`) in all 3 stages; the backend needs them to sign `/img/` URLs.
3. **nginx** — swap web-01 to `../web-01/nginx/default.conf.cdn-proposed` (adds cache zone + new cdn block), mount `./nginx/cache:/var/cache/nginx`, `nginx -t` then reload. (Do after step 1.)
4. **Smoke test** — `GET https://cdn.wiriri.com/img/<signed>/rs:fill:400/<src>` → 200 + `X-Cache-Status`; a backend presigned PUT/GET round-trips.

> All changes are **read-only-first**: validate `nginx -t` and a throwaway object before flipping app reads.
