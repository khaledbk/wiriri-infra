# Wiriri production — right-sizing proposal (5-VM architecture)

> **STATUS: 🟡 PROPOSED — NOT IMPLEMENTED.** Reference only. Nothing in this file is live.
> **Confirmed by:** CEO (2026-06-29) · **Author of this draft:** infra audit (read-only) · **Date:** 2026-06-29
> **Supersedes sizing of:** the current 5× (1 vCPU / 1 GB) hosts captured in `README.md` §2.
> Apply during a **fresh deploy**; pair with the live compose files as `*-proposed` per repo convention.

---

## 0. What this proposes

1. Move from the current 1 GB hosts to the **CEO-confirmed 5-VM sizing** (below).
2. Add **`mem_limit` / `mem_reservation`** to every container (none today).
3. Add a **swapfile + `vm.swappiness`** per VM as an OOM safety net.

**Scope assumption:** host **15 properties now → max 100 in year 1**. Capacity is comfortable at
that scale (see §4); the real open items remain backups + single-node resilience (out of scope here —
backups handled by the cloud provider per CEO).

---

## 1. Proposed VM sizing (CEO-confirmed)

| VM | vCPU | RAM | Disk | Assigned role | Maps to today |
|----|------|-----|------|---------------|---------------|
| **VM1** | 1 | 2 GB | 25 GB | Edge: nginx (+geoip2) · webapp · admin | web-01 (.3) |
| **VM2** | 1 | 2 GB | 30 GB | PostgreSQL | db-01 (.5) |
| **VM3** | 1 | 2 GB | 25 GB | NestJS backend · Redis | api-01 (.4) |
| **VM4** | 1 | 1 GB | 40 GB | MinIO · imgproxy | storage-01 (.7) |
| **VM5** | 1 | 1 GB | 20 GB | Prometheus · Grafana | monitor-01 (.6) |
| **Σ** | 5 | 8 GB | 140 GB | | |

Placement rule applied: **2 GB VMs → RAM-hungry apps** (edge/db/backend); **largest disk → MinIO**
(storage is disk-bound, not RAM-bound). Network model unchanged: single public door on VM1,
private VPC, per-host firewalls, Infisical secrets.

---

## 2. Per-container memory caps (PROPOSED)

Compose keys: `mem_limit` (hard cap) + `mem_reservation` (soft target). Assumes Compose v2 (not Swarm).

### VM1 — Edge (2 GB / 25 GB)
| Container | `mem_limit` | `mem_reservation` | Note |
|---|---|---|---|
| nginx | 192m | 96m | + CDN cache to disk |
| webapp (Next.js SSR) | 900m | 512m | main consumer |
| admin (Next.js SSR) | 384m | 192m | 3–5 users/day → hard cap |
| node_exporter | 64m | — | |
| **Σ caps** | **~1540m** | | ~500m left for OS/docker daemon |

### VM2 — PostgreSQL (2 GB / 30 GB)
| Container | `mem_limit` | `mem_reservation` | Note |
|---|---|---|---|
| postgres | 1400m | 768m | tune `shared_buffers≈512MB`, `effective_cache_size≈1GB` |
| postgres_exporter | 64m | — | |
| node_exporter | 64m | — | |
| **Σ caps** | **~1528m** | | DB box → low swappiness (§3) |

### VM3 — Backend + Redis (2 GB / 25 GB)
| Container | `mem_limit` | `mem_reservation` | Note |
|---|---|---|---|
| backend (NestJS) | 1024m | 640m | Node + BullMQ queues |
| redis | 384m | 192m | set `maxmemory 256mb` + `maxmemory-policy allkeys-lru` |
| redis_exporter | 64m | — | |
| node_exporter | 64m | — | |
| **Σ caps** | **~1536m** | | ~500m headroom |

### VM4 — Storage (1 GB / 40 GB) — tightest box
| Container | `mem_limit` | `mem_reservation` | Note |
|---|---|---|---|
| minio | 512m | 256m | |
| imgproxy | 320m | 160m | also `IMGPROXY_WORKERS=2`, `IMGPROXY_MAX_CLIENTS=4` to bound RAM |
| node_exporter | 48m | — | |
| **Σ caps** | **~880m** | | only ~140m OS slack → swap is the safety net |

### VM5 — Monitor (1 GB / 20 GB)
| Container | `mem_limit` | `mem_reservation` | Note |
|---|---|---|---|
| prometheus | 512m | 256m | `--storage.tsdb.retention.time=15d` to bound the 20 GB |
| grafana | 256m | 128m | |
| node_exporter | 64m | — | |
| **Σ caps** | **~832m** | | |

---

## 3. Swap + sysctl (PROPOSED)

| VM | RAM | Swapfile | `vm.swappiness` | Rationale |
|----|-----|----------|-----------------|-----------|
| VM1 edge | 2 GB | 2 GB | 10 | absorb SSR/build spikes |
| VM2 db | 2 GB | 1 GB | **1** | Postgres should swap only in emergency |
| VM3 app | 2 GB | 2 GB | 10 | Node spikes |
| VM4 storage | 1 GB | 2 GB | 20 | tightest RAM → biggest safety net |
| VM5 monitor | 1 GB | 2 GB | 10 | Prometheus compaction spikes |

Reference swapfile setup (per VM, run once — **not executed here**):

```bash
sudo fallocate -l 2G /swapfile          # 1G on VM2
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf   # 1 on VM2, 20 on VM4
sudo sysctl --system
```

---

## 4. Capacity rationale (15 → 100 properties, year 1)

| Metric | 15 properties (now) | 100 properties (year 1) | Headroom |
|---|---|---|---|
| Images (~28/property) | ~413 | ~2,800 | — |
| MinIO @ 5 MB cap (worst) | ~2 GB | ~14 GB | — |
| + private bucket (KYC/PDF) | — | ~5–8 GB | — |
| **MinIO total worst-case** | | **~20–22 GB / 40 GB** | ✅ ~45% free |
| Postgres data | <100 MB | a few hundred MB / 30 GB | ✅ huge |
| webapp/admin/backend RAM | — | fits 2 GB VMs + caps | ✅ |
| Traffic | low | low (early marketplace) | 🟢 trivial for 2 vCPU SSR |

→ The 8 GB / 140 GB arch is **more than enough** for the year-1 target.
*(The scraped 102 MB for 15 properties is Airbnb's compressed delivery; planning number is your
own 5 MB-capped originals. imgproxy generates resized/WebP variants on the fly, edge-cached on VM1,
not re-stored in MinIO.)*

---

## 5. Open items / flags

| Sev | Item |
|---|---|
| 🟡 | **VM4 is the squeeze** — minio+imgproxy on 1 GB leaves ~140 MB slack; imgproxy worker/client caps + 2 GB swap keep it safe. First box to upsize if it thrashes. |
| 🟡 | **MinIO growth past year 1** — at 5 MB cap and >250 properties the 40 GB tightens; plan disk growth/offload then, not now. |
| 🟢 | Pin `:latest` images (MinIO/imgproxy/exporters) and add healthchecks during this fresh deploy. |
| 🟢 | Pair every `mem_limit` with `mem_reservation` so the OOM killer picks the right victim. |
| ⚪ | Backups (DB + objects): handled by cloud provider per CEO — out of scope for this doc. |

---

## 6. Apply order (when deployed — not today)

Lowest risk → highest: **VM2 Postgres → VM4 MinIO/imgproxy → VM3 backend/Redis → VM1 edge/apps → VM5 monitor.**
Bring data layers up and verify reads before cutting the edge (VM1) over.

> Per repo convention: this is a `*-proposed` reference. Promote values into the live
> `*/docker-compose.yml` via PR (read-only-first on prod) when scheduled.
