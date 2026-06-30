# Payments mock — LIVE test env (`payments.wiriri.com`)

> **STATUS: 🟢 LIVE / IMPLEMENTED — 2026-06-30.** This is **not** a proposal. Every change
> listed here is applied on the running prod fleet right now. It is a **temporary pre-prod
> test environment**, scheduled for teardown (see §6).
> **Purpose:** route the real prod payment journey to a self-hosted **mock Konnect gateway**
> so the full book → pay → webhook → redirect flow can be exercised end-to-end **without real
> charges**. Backend was on Konnect *sandbox* before this; it now points at the mock.
> **Operator TL;DR:** the repo's committed configs do **NOT** reflect these changes — see the
> **sync status** in §5. Use §6 to fully revert.

---

## 1. What it is

| | |
|---|---|
| Public URL | `https://payments.wiriri.com` (→ web-01 edge → mock on monitor-01) |
| Mock service | `wiriri-payment-gateway` (Express/TS, in-memory, no DB, no auth) — mimics Konnect's API |
| Host | **monitor-01** `10.130.18.6` (chosen: idle, no prod app/data on it, disposable) |
| Container | `wiriri-prod-payments-mock` · image `wiriri-prod-payments-mock:dev` (`node:24.18-alpine`) |
| Test cards | success `4242 4242 4242 4242` · decline `4000 0000 0000 0002` · pre-auth-refused `4000 0000 0000 0003` |
| Disclaimer | every pay/success page shows *"Environnement de test — paiement fictif (dev)… contact@wiriri.com"* |

Traffic path: `Internet → web-01:443 (nginx edge) → VPC → monitor-01:4000 (mock)`. The mock's
webhook/redirect calls go back out to `https://api.wiriri.com` and `https://wiriri.com`.

---

## 2. Source code change (repo `wiriri-payment-gateway`)

Two edits to `src/index.ts`, then `npm run build` (regenerated `dist/index.js`):

1. **`PUBLIC_BASE_URL` env** (default `http://localhost:PORT`) — used to build the returned
   `payUrl` instead of a hardcoded `localhost`. Without this the browser would be sent to
   `localhost` behind the public domain.
2. **Dev disclaimer footer** added to the pay page + both success pages.

The `ClicToPay-logo.png` is baked into the image (tsc doesn't copy assets; `express.static`
serves it from the app dir at runtime).

---

## 3. Live changes applied, per system

### 3.1 monitor-01 (`10.130.18.6`) — the mock
Build context lives at `~tvacadmin/payments-mock/` on the box: `index.js` (built), `package.json`,
`package-lock.json`, `ClicToPay-logo.png`, `Dockerfile`.

```dockerfile
# ~tvacadmin/payments-mock/Dockerfile
FROM node:24.18-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY index.js ./index.js
COPY ClicToPay-logo.png ./ClicToPay-logo.png
EXPOSE 4000
CMD ["node","index.js"]
```

```bash
# build + run (as tvacadmin, Docker already present on the box)
cd ~/payments-mock
docker build -t wiriri-prod-payments-mock:dev .
docker run -d --name wiriri-prod-payments-mock --restart unless-stopped --memory=128m \
  -p 10.130.18.6:4000:4000 \
  -e PUBLIC_BASE_URL=https://payments.wiriri.com \
  -e BACKEND_URL=https://api.wiriri.com \
  -e FRONTEND_URL=https://wiriri.com \
  wiriri-prod-payments-mock:dev
```
Bound to the **private IP only** (`10.130.18.6:4000`), `--memory=128m` (no swap on the box).

### 3.2 monitor-fw (CloudAxion firewall) — **rule created**
| Direction | Type | Proto | Port | Source | Note |
|---|---|---|---|---|---|
| Inbound | Custom | TCP | **4000** | **`10.130.18.3/32`** (web-01) | only the edge may reach the mock |

> A 4000 rule was first added to **web-fw by mistake and removed**; the correct rule is on
> **monitor-fw** only.

### 3.3 web-01 (`10.130.18.3`) — TLS + edge
**TLS cert expanded** (shared Let's Encrypt cert, lineage `wiriri.com`), via one-shot
`certbot/certbot` container (no host certbot on this box):

```bash
docker run --rm \
  -v /opt/wiriri/certbot/conf:/etc/letsencrypt \
  -v /opt/wiriri/certbot/www:/var/www/certbot \
  certbot/certbot certonly --webroot -w /var/www/certbot --cert-name wiriri.com \
  -d wiriri.com -d www.wiriri.com -d api.wiriri.com -d admin.wiriri.com -d cdn.wiriri.com -d payments.wiriri.com \
  --expand --non-interactive --agree-tos --no-eff-email
```
SAN now: `admin, api, cdn, payments, wiriri, www`. Expires **2026-09-28**.

**nginx** (`/opt/wiriri/nginx/default.conf`, mounted into `wiriri-prod-nginx`):
- added `payments.wiriri.com` to the `:80` server_name (for ACME + 301→https);
- appended a `:443` vhost: `payments.wiriri.com` → `proxy_pass http://10.130.18.6:4000`.
- **Backup kept on-box:** `/opt/wiriri/nginx/default.conf.bak-payments-1782795900`.

> ⚠️ **Bind-mount gotcha (operators read this):** `default.conf` is a **single-file** bind
> mount. Editing it with `sed -i`/editors replaces the inode, so `nginx -s reload` keeps the
> **old** config. After editing this file you must **`docker restart wiriri-prod-nginx`**
> (not just reload) — or edit in place preserving the inode.

### 3.4 Infisical + backend (`api-01` `10.130.18.4`) — the cutover
- **Infisical** project `backend` (`d628874b-b431-492c-bb96-0b3282df2f65`), env **prod**:
  `KONNECT_BASE_URL` : `https://api.sandbox.konnect.network` → **`https://payments.wiriri.com`**.
  `PAYMENT_GATEWAY` unchanged (`konnect`).
- **api-01:** regenerated `/opt/wiriri/backend/.env` via `bash /opt/wiriri/backend/get-env.sh`
  (guarded: only the KONNECT line changed), then `docker compose up -d --force-recreate backend`.
  **Backup kept on-box:** `/opt/wiriri/backend/.env.bak-konnect-1782796228`.
- Backend `env_file: ./backend/.env` is read at **create** → a recreate (not restart) is required.

### 3.5 DNS — no change
`payments.wiriri.com` already resolved to `102.207.250.149` (web-01) before this work.

---

## 4. Verification (done 2026-06-30)
- `https://payments.wiriri.com/health` → `200`, **TLS verify = 0** (valid cert).
- `POST /api/v2/payments/init-payment` → `payUrl` = `https://payments.wiriri.com/payment/<ref>`.
- Pay page renders: ClicToPay UI + disclaimer + `contact@wiriri.com` + logo asset `200`.
- Mock reachable from web-01 over the VPC; **not** reachable from elsewhere (firewall).
- Backend recreated cleanly (`Nest application successfully started`, port 4001).
- No collateral: `wiriri.com / api / admin / cdn` all respond normally.
- **Remaining human check:** one real browser booking → pay (`4242…`) → webhook → success page.

---

## 5. Repo ⇄ live SYNC STATUS — **OUT OF SYNC (by design, temporary)**

These changes are **live-on-box only**. The committed repo does not contain them:

| Repo file / area | Live state | Synced? |
|---|---|---|
| `web-01/nginx/default.conf` | live has the `payments` `:80` server_name + `:443` proxy block | ❌ drift |
| `monitor-01/` (repo has only README) | live runs `wiriri-prod-payments-mock` container + `~/payments-mock` build | ❌ not represented |
| `NETWORK.md` / `README.md` §8 firewall matrix | live monitor-fw has extra `4000 ← 10.130.18.3/32` | ❌ not listed |
| TLS / `README.md` §10 | cert SAN now includes `payments.wiriri.com` | ❌ not noted |
| Infisical backend/prod `KONNECT_BASE_URL` | now the mock (was sandbox) | ⚠️ values aren't stored in repo; flagged here |

**This document is the only record of the drift.** It is intentional and temporary. After a clean
teardown (§6) the live fleet returns to matching the committed repo — the only residual would be
the cert SAN if you choose not to shrink it (§6.5, cosmetic). The repo's `*-proposed` migration
files are unrelated and out of scope here.

---

## 6. TEARDOWN — full revert (run in this order)

Reverse of apply: stop sending prod payments to the mock **first**, then peel back the edge,
then the mock, then the firewall.

### 6.1 Backend → back to Konnect sandbox (api-01)
```bash
# on your workstation (Infisical CLI, logged in):
infisical secrets set KONNECT_BASE_URL=https://api.sandbox.konnect.network \
  --projectId d628874b-b431-492c-bb96-0b3282df2f65 --env prod
# on api-01:
bash /opt/wiriri/backend/get-env.sh
cd /opt/wiriri && docker compose up -d --force-recreate backend
docker exec wiriri-prod-backend printenv KONNECT_BASE_URL   # expect sandbox
# (fallback: restore /opt/wiriri/backend/.env.bak-konnect-1782796228 then recreate)
```

### 6.2 Edge nginx (web-01) — remove the payments vhost
```bash
cd /opt/wiriri/nginx
cp default.conf.bak-payments-1782795900 default.conf   # restores :80 server_name + drops :443 block
docker restart wiriri-prod-nginx                        # restart (NOT reload) — bind-mount gotcha
docker exec wiriri-prod-nginx nginx -t
```

### 6.3 Mock (monitor-01)
```bash
docker rm -f wiriri-prod-payments-mock
docker rmi wiriri-prod-payments-mock:dev
rm -rf ~/payments-mock
```

### 6.4 monitor-fw — delete the rule
CloudAxion → Network → `wiriri-prod-monitor-fw` → Inbound → delete `Custom TCP 4000 ← 10.130.18.3/32`.

### 6.5 TLS cert (OPTIONAL, cosmetic)
Leaving `payments.wiriri.com` in the SAN is harmless. To shrink it back to the 5 original names,
reissue the `wiriri.com` lineage without `payments` (same `certbot/certbot` container, list only
the 5 names, `--force-renewal`), then `docker restart wiriri-prod-nginx`.

### 6.6 Verify teardown
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://payments.wiriri.com/health   # expect TLS/301/404, not the mock
curl -s -o /dev/null -w "%{http_code}\n" https://api.wiriri.com/              # expect 200
ssh tvacadmin@10.130.18.4 'docker exec wiriri-prod-backend printenv KONNECT_BASE_URL'  # sandbox
```

After §6 the fleet matches the committed repo again (modulo §6.5). Delete this file or move it to
an archive once teardown is confirmed.
