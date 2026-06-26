# Wiriri Production Storage VPS Setup Guide

This guide documents the setup of the dedicated MinIO storage server for Wiriri.

Storage server:

```text
Hostname: wiriri-prod-storage-01
Private IP: 10.130.18.7
Purpose: User-uploaded images/files stored in Tunisia
Storage engine: MinIO
```

The goal is to keep user-uploaded images and personal files on a dedicated Tunisian VPS instead of storing them on the API, web, DB, or monitor servers.

---

## 1. Target architecture

```text
User browser
   ↓
https://api.wiriri.com
   ↓
wiriri-prod-api-01
   ↓ private VPC
MinIO on wiriri-prod-storage-01
   ↓
/opt/wiriri/minio/data
```

The application should store only file metadata in PostgreSQL.

PostgreSQL should store:

```text
id
owner_user_id
bucket
object_key
original_filename
mime_type
size_bytes
checksum_sha256
width
height
visibility
created_at
deleted_at
```

The actual image/file bytes live in MinIO.

---

## 2. Server information

| Item | Value |
|---|---|
| Hostname | `wiriri-prod-storage-01` |
| OS | Ubuntu 24.04 LTS |
| Private IP | `10.130.18.7` |
| MinIO API | `http://10.130.18.7:9000` |
| MinIO Console | `http://10.130.18.7:9001` |
| Node exporter | `10.130.18.7:9100` |

---

## 3. Firewall rules

Create a separate CloudAxion firewall:

```text
wiriri-prod-storage-fw
```

Attach it only to:

```text
wiriri-prod-storage-01
```

### Inbound rules

| Protocol | Port | Source | Purpose |
|---|---:|---|---|
| TCP | `22` | Your public IP `/32` | SSH |
| TCP | `9000` | `10.130.18.4/32` | API VPS → MinIO API |
| TCP | `9100` | `10.130.18.6/32` | Prometheus node exporter |

Optional, temporary only:

| Protocol | Port | Source | Purpose |
|---|---:|---|---|
| TCP | `9001` | Your public IP `/32` | MinIO Console |

Recommended: do **not** expose `9001` publicly. Use an SSH tunnel instead.

### Outbound rules

Allow all outbound.

---

## 4. Initial server setup

SSH into the storage VPS:

```bash
ssh tvacadmin@STORAGE_PUBLIC_IP
```

Set hostname:

```bash
sudo hostnamectl set-hostname wiriri-prod-storage-01
exec bash
hostname
```

Update packages:

```bash
sudo apt update
sudo apt -y upgrade
sudo apt install -y ca-certificates curl gnupg lsb-release htop unzip openssl
```

---

## 5. Install Docker

```bash
curl -fsSL https://get.docker.com | sudo sh

sudo usermod -aG docker tvacadmin
newgrp docker

docker --version
docker compose version
```

---

## 6. Create MinIO folders

```bash
sudo mkdir -p /opt/wiriri/minio/data
sudo mkdir -p /opt/wiriri/minio/config
sudo chown -R tvacadmin:tvacadmin /opt/wiriri
chmod 700 /opt/wiriri/minio/data
```

Directory layout:

```text
/opt/wiriri
├── docker-compose.yml
└── minio
    ├── config
    └── data
```

---

## 7. Generate MinIO credentials

Generate strong values:

```bash
openssl rand -base64 32
openssl rand -base64 48
```

Use:

```text
MINIO_ROOT_USER=wiriri_minio_admin
MINIO_ROOT_PASSWORD=<long random password>
```

Do not use the root MinIO credentials in the backend application. They are only for administration.

---

## 8. Docker Compose for MinIO

Create:

```bash
nano /opt/wiriri/docker-compose.yml
```

Use:

```yaml
services:
  minio:
    image: quay.io/minio/minio:latest
    container_name: wiriri-prod-minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: "wiriri_minio_admin"
      MINIO_ROOT_PASSWORD: "CHANGE_THIS_LONG_RANDOM_PASSWORD"
    volumes:
      - ./minio/data:/data
      - ./minio/config:/root/.minio
    ports:
      - "10.130.18.7:9000:9000"
      - "10.130.18.7:9001:9001"

  node_exporter:
    image: prom/node-exporter:latest
    container_name: wiriri-prod-storage-node-exporter
    restart: unless-stopped
    command:
      - "--path.rootfs=/host"
    pid: host
    uts: host
    volumes:
      - "/:/host:ro,rslave"
    ports:
      - "10.130.18.7:9100:9100"
```

Replace:

```text
CHANGE_THIS_LONG_RANDOM_PASSWORD
```

with the generated MinIO root password.

Start services:

```bash
cd /opt/wiriri
docker compose up -d
docker ps
```

Expected containers:

```text
wiriri-prod-minio
wiriri-prod-storage-node-exporter
```

---

## 9. Test MinIO health

On storage VPS:

```bash
curl -I http://10.130.18.7:9000/minio/health/live
```

Expected:

```text
HTTP/1.1 200 OK
```

Check logs:

```bash
docker logs wiriri-prod-minio --tail=80
```

---

## 10. Test access from API VPS

From `wiriri-prod-api-01`:

```bash
curl -I http://10.130.18.7:9000/minio/health/live
```

Expected:

```text
HTTP/1.1 200 OK
```

If this fails, verify the storage firewall allows:

```text
TCP 9000 from 10.130.18.4/32
```

---

## 11. Install MinIO client

On `wiriri-prod-storage-01`:

```bash
mkdir -p ~/bin
curl -L https://dl.min.io/client/mc/release/linux-amd64/mc -o ~/bin/mc
chmod +x ~/bin/mc
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

mc --version
```

Configure root admin alias:

```bash
mc alias set wiriri http://10.130.18.7:9000 wiriri_minio_admin 'MINIO_ROOT_PASSWORD'
```

Verify:

```bash
mc admin info wiriri
```

---

## 12. Create buckets

Create production buckets:

```bash
mc mb wiriri/wiriri-prod-images
mc mb wiriri/wiriri-prod-private
```

Make them private:

```bash
mc anonymous set none wiriri/wiriri-prod-images
mc anonymous set none wiriri/wiriri-prod-private
```

List buckets:

```bash
mc ls wiriri
```

Expected:

```text
wiriri-prod-images/
wiriri-prod-private/
```

---

## 13. Create backend MinIO policy

Do not use `s3:StatObject`; MinIO does not support that policy action. For stat/head operations, clients normally need `s3:GetObject`.

Create the policy file:

```bash
cat > /tmp/wiriri-backend-minio-policy.json <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::wiriri-prod-images",
        "arn:aws:s3:::wiriri-prod-private"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::wiriri-prod-images/*",
        "arn:aws:s3:::wiriri-prod-private/*"
      ]
    }
  ]
}
POLICY
```

Create policy:

```bash
mc admin policy create wiriri wiriri-backend-minio /tmp/wiriri-backend-minio-policy.json
```

Expected:

```text
Created policy `wiriri-backend-minio` successfully.
```

---

## 14. Create backend MinIO user

Generate a backend user password:

```bash
openssl rand -base64 48
```

Create user:

```bash
mc admin user add wiriri wiriri_backend_minio 'GENERATED_BACKEND_MINIO_PASSWORD'
```

Attach policy:

```bash
mc admin policy attach wiriri wiriri-backend-minio --user wiriri_backend_minio
```

Verify:

```bash
mc admin user info wiriri wiriri_backend_minio
```

---

## 15. Test backend MinIO user

Create a second alias:

```bash
mc alias set wiriri-backend http://10.130.18.7:9000 wiriri_backend_minio 'BACKEND_MINIO_PASSWORD'
```

Test upload/read/delete:

```bash
echo "hello minio" > /tmp/test.txt

mc cp /tmp/test.txt wiriri-backend/wiriri-prod-images/test/test.txt
mc cat wiriri-backend/wiriri-prod-images/test/test.txt
mc rm wiriri-backend/wiriri-prod-images/test/test.txt
```

Expected:

```text
hello minio
```

---

## 16. Backend Infisical environment variables

Add to backend `prod` environment:

```env
S3_ENDPOINT=http://10.130.18.7:9000
S3_REGION=us-east-1
S3_ACCESS_KEY=wiriri_backend_minio
S3_SECRET_KEY=BACKEND_MINIO_PASSWORD
S3_BUCKET_IMAGES=wiriri-prod-images
S3_BUCKET_PRIVATE=wiriri-prod-private
S3_FORCE_PATH_STYLE=true
```

Most S3 SDKs need path-style access for MinIO:

```text
forcePathStyle: true
```

Example object keys:

```text
users/<user_id>/images/<uuid>.webp
listings/<listing_id>/<uuid>.jpg
identity-documents/<user_id>/<uuid>.jpg
```

Avoid predictable public paths for private/sensitive images.

---

## 17. Access MinIO Console safely

MinIO Console runs on:

```text
http://10.130.18.7:9001
```

Recommended: do not expose the console publicly. Use SSH tunnel.

From your laptop:

```bash
ssh -L 9001:10.130.18.7:9001 tvacadmin@STORAGE_PUBLIC_IP
```

Keep the SSH session open.

Open in browser:

```text
http://localhost:9001
```

Login with:

```text
Username: wiriri_minio_admin
Password: MinIO root password
```

### Do not publicly expose console unless protected

If you expose the console, use:

```text
HTTPS
IP restriction
strong password
ideally VPN or SSH tunnel
```

---

## 18. Monitoring

The storage VPS exposes node exporter on:

```text
10.130.18.7:9100
```

Add to Prometheus on `wiriri-prod-monitor-01`:

```yaml
  - job_name: "node"
    static_configs:
      - targets:
          - "10.130.18.3:9100" # web
          - "10.130.18.4:9100" # api
          - "10.130.18.5:9100" # db
          - "10.130.18.6:9100" # monitor
          - "10.130.18.7:9100" # storage
```

Reload Prometheus:

```bash
cd /opt/wiriri
docker compose restart prometheus
```

Check targets in Grafana/Prometheus.

---

## 19. Backup strategy

A single MinIO VPS is not enough without backups.

Recommended backup destination:

```text
Another Tunisian VPS or attached backup disk in Tunisia
```

Minimum backup plan:

```text
Daily backup of /opt/wiriri/minio/data
Daily backup of /opt/wiriri/docker-compose.yml
Daily backup of MinIO config/policies
Regular restore test
```

Simple rsync example to a backup VPS:

```bash
rsync -aH --delete /opt/wiriri/minio/data/ backup-user@BACKUP_PRIVATE_IP:/backups/wiriri/minio/data/
rsync -aH /opt/wiriri/docker-compose.yml backup-user@BACKUP_PRIVATE_IP:/backups/wiriri/minio/
```

For larger volumes, use snapshots or object replication.

---

## 20. Rotate MinIO root password

If the root password was pasted into chat or shared insecurely, rotate it.

Generate new password:

```bash
openssl rand -base64 48
```

Edit:

```bash
nano /opt/wiriri/docker-compose.yml
```

Change:

```yaml
MINIO_ROOT_PASSWORD: "NEW_LONG_RANDOM_PASSWORD"
```

Restart:

```bash
cd /opt/wiriri
docker compose up -d minio
```

Update root alias:

```bash
mc alias set wiriri http://10.130.18.7:9000 wiriri_minio_admin 'NEW_LONG_RANDOM_PASSWORD'
```

Verify:

```bash
mc ls wiriri
```

The backend should keep using `wiriri_backend_minio`, not the root user.

---

## 21. Final verification checklist

- [ ] `wiriri-prod-storage-01` hostname set correctly
- [ ] MinIO API bound to `10.130.18.7:9000`
- [ ] MinIO Console bound to `10.130.18.7:9001`
- [ ] Node exporter bound to `10.130.18.7:9100`
- [ ] Storage firewall allows `9000` from `10.130.18.4/32`
- [ ] Storage firewall allows `9100` from `10.130.18.6/32`
- [ ] Buckets created:
  - `wiriri-prod-images`
  - `wiriri-prod-private`
- [ ] Buckets are private
- [ ] Backend MinIO user exists:
  - `wiriri_backend_minio`
- [ ] Backend policy attached:
  - `wiriri-backend-minio`
- [ ] Backend user upload/read/delete test passes
- [ ] Backend Infisical has S3/MinIO env variables
- [ ] MinIO root password rotated if it was exposed
- [ ] Backup strategy is defined

### CDN extension checklist (§22)
- [ ] Read-only imgproxy user `wiriri_imgproxy_ro` + policy (GetObject/ListBucket on images only)
- [ ] imgproxy container running on `10.130.18.7:8080`
- [ ] `IMGPROXY_KEY` / `IMGPROXY_SALT` generated and in Infisical (3 stages)
- [ ] Storage firewall allows `8080` from `10.130.18.3/32` (web-01 edge)
- [ ] `cdn.wiriri.com` vhost on web-01 serves `/img/*` (imgproxy) + presigned passthrough
- [ ] Smoke test: signed `/img/` URL → 200 + `X-Cache-Status`; presigned PUT/GET round-trips

---

## 22. CDN extension — imgproxy + `cdn.wiriri.com`  (added 2026-06-26)

> This section extends the MinIO-only runbook above with the **image CDN** layer (decided after
> the original build). Design: `docs/spec/SPEC-2026-06-26-storage-minio-cdn.md`. Config to apply:
> `wiriri-infra/cdn/` + `wiriri-infra/storage-01/docker-compose.cdn-proposed.yml` +
> `wiriri-infra/web-01/nginx/default.conf.cdn-proposed`.

**Why:** MinIO is a pure object store — no on-the-fly resize/WebP (Cloudinary did that). imgproxy
adds transforms; the existing **web-01 nginx** is the public edge + cache. MinIO/imgproxy stay
private; only `cdn.wiriri.com` (→ web-01:443) is public.

### 22.1 Read-only MinIO user for imgproxy (do NOT reuse the backend rw user or root)

```bash
cat > /tmp/wiriri-imgproxy-ro-policy.json <<'POLICY'
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": ["s3:GetObject","s3:ListBucket"],
    "Resource": ["arn:aws:s3:::wiriri-prod-images","arn:aws:s3:::wiriri-prod-images/*"] } ] }
POLICY
mc admin policy create wiriri wiriri-imgproxy-ro /tmp/wiriri-imgproxy-ro-policy.json
mc admin user add wiriri wiriri_imgproxy_ro "$(openssl rand -base64 36)"   # save the secret
mc admin policy attach wiriri wiriri-imgproxy-ro --user wiriri_imgproxy_ro
```

### 22.2 imgproxy service (storage-01)
Add the `imgproxy` service from `wiriri-infra/storage-01/docker-compose.cdn-proposed.yml`. It reads an
on-box `imgproxy.env` (see `wiriri-infra/cdn/.env.example`): `IMGPROXY_KEY`/`IMGPROXY_SALT`
(`openssl rand -hex 32` / `-hex 16`) + the `wiriri_imgproxy_ro` creds. Source-locked to
`s3://wiriri-prod-images/`, strips EXIF, `MAX_SRC_RESOLUTION=30`. Bound to `10.130.18.7:8080` (private).

```bash
cd /opt/wiriri && docker compose up -d imgproxy && curl -sI http://10.130.18.7:8080/health
```

### 22.3 Firewall
Add to the storage firewall (only change needed — `:9000` from web-01 is already open):

| Protocol | Port | Source | Purpose |
|---|---:|---|---|
| TCP | `8080` | `10.130.18.3/32` | web-01 edge → imgproxy |

### 22.4 Edge (web-01)
Apply `wiriri-infra/web-01/nginx/default.conf.cdn-proposed` (replaces the cdn stub: adds the cache
zone + `/img/*`→imgproxy and presigned `/<bucket>/*`→MinIO passthrough), mount `./nginx/cache`,
then `nginx -t` and reload. TLS already covers `cdn.wiriri.com` (shared `wiriri.com` SAN cert).

### 22.5 Upload/read model (aligns the §1 diagram with the spec)
- **Public images:** backend mints a **presigned PUT** (signed against `https://cdn.wiriri.com`); the
  browser uploads direct to MinIO. Reads go through `cdn.wiriri.com/img/...` (imgproxy, cached).
- **ID/KYC (private):** backend **proxies/streams** (authz + audit) — never presigned to cdn.
- **Invoices/PDFs:** backend mints a short-TTL **presigned GET** via `cdn.wiriri.com`.
- DB stores the `FileObject` metadata row (key, not URL) — unchanged from §1.

### 22.6 Monitoring
Add imgproxy to Prometheus on monitor-01 (it exposes Prometheus metrics when
`IMGPROXY_PROMETHEUS_BIND` is set, or scrape `:8080/health` for liveness).
