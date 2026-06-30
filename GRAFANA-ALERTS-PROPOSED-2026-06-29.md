# Wiriri production — capacity & health alert thresholds (PROPOSED)

> **STATUS: 🟡 PROPOSED — NOT IMPLEMENTED.** Reference only. No alert rules are live from this file.
> **Date:** 2026-06-29 · **Scope:** the 5-VM right-sized arch (`ARCHITECTURE-PROPOSED-2026-06-29.md`).
> Targets the existing Prometheus/Grafana on monitor-01 (VM5) and current exporters
> (node_exporter on every host, postgres_exporter on db-01, redis_exporter on api-01).

---

## 0. Two alert tiers — read this first

| Tier | Purpose | How to react |
|---|---|---|
| 🟡 **Capacity / trend** | "we're filling up / heating up" | **ticket, not a page.** Act when it stays amber ~2 weeks. These are the upgrade-decision signals. |
| 🔴 **Incident** | "something is breaking now" | **page on-call.** Fast `for:` windows. |

The five signals you asked about are the 🟡 trend tier. The 🔴 rules are the cheap must-haves alongside them.

> `instance` label = `<private-ip>:<port>`: VM1 `10.130.18.3:9100` · VM3 `10.130.18.4:9100` ·
> VM2 `10.130.18.5:9100` (+ `:9187` pg) · VM4 `10.130.18.7:9100` · VM5 `10.130.18.6:9100`.

---

## 1. The 5 capacity signals 🟡 (trend tier)

| # | Signal | Host(s) | Warn | Crit | `for` | Means / action |
|---|---|---|---|---|---|---|
| 1 | **CPU saturation** | VM1 edge, VM3 backend | >70% | >90% | 15m / 10m | the real user ceiling → split admin off VM1, then add vCPU/replica |
| 2 | **p95 latency** | edge (synthetic) | >800 ms | >1.5 s | 10m | UX degrading → needs exporter (see §3) |
| 3 | **Swap in use** | all (esp. VM4) | >128 MB | >50% of swap | 30m / 15m | RAM pressure is real (not just allocated) → raise caps or RAM |
| 4 | **Postgres connections** | VM2 | >70% of max | >85% | 15m | pool pressure → tune pool / bump DB |
| 5 | **MinIO disk** | VM4 | >70% | >85% | 30m | ~250–300 properties → grow disk / offload |

### PromQL

**1 — CPU per host (%)**
```promql
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle",
  instance=~"10.130.18.(3|4):9100"}[5m])))
# warn > 70 for 15m  ·  crit > 90 for 10m
```

**2 — p95 latency** *(needs an exporter — see §3; example with blackbox_exporter)*
```promql
histogram_quantile(0.95,
  sum by (le) (rate(probe_http_duration_seconds_bucket{job="blackbox-wiriri"}[5m])))
# warn > 0.8 for 10m  ·  crit > 1.5 for 10m
```

**3 — Swap actually used (bytes)**
```promql
node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes
# warn > 134217728 (128 MB) for 30m
# crit: (used / total) > 0.5 for 15m
(node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes)
  / (node_memory_SwapTotal_bytes > 0) > 0.5
```

**4 — Postgres connection ratio**
```promql
sum(pg_stat_activity_count{datname="wiriri_prod"}) / on() pg_settings_max_connections
# warn > 0.70 for 15m  ·  crit > 0.85 for 15m
```

**5 — MinIO disk usage (%)** *(root fs on VM4 holds `./minio/data`)*
```promql
100 * (1 - node_filesystem_avail_bytes{instance="10.130.18.7:9100", fstype!~"tmpfs|overlay", mountpoint="/host"}
  / node_filesystem_size_bytes{instance="10.130.18.7:9100", fstype!~"tmpfs|overlay", mountpoint="/host"})
# warn > 70 for 30m  ·  crit > 85 for 15m
```

---

## 2. Incident must-haves 🔴 (page tier)

| Alert | PromQL | Crit | `for` |
|---|---|---|---|
| **Host/exporter down** | `up{job="node"} == 0` | any | 2m |
| **Backend down** | `up{job=~"backend|api"} == 0` (or blackbox `probe_success==0` on `api.wiriri.com`) | 0 | 2m |
| **Edge site down** | blackbox `probe_success{instance="https://wiriri.com"} == 0` | 0 | 2m |
| **Disk almost full (any host)** | `100*(1-node_filesystem_avail_bytes{mountpoint="/host",fstype!~"tmpfs|overlay"}/node_filesystem_size_bytes{...}) > 90` | >90% | 10m |
| **RAM exhaustion** | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.08` | <8% avail | 10m |
| **Postgres down** | `pg_up == 0` | 0 | 2m |
| **Redis down** | `redis_up == 0` | 0 | 2m |
| **Prometheus TSDB filling (VM5)** | MinIO-disk query on `10.130.18.6:9100` `> 85` | >85% | 30m |

---

## 3. Gaps to close before these work fully

| Sev | Gap |
|---|---|
| 🟡 | **No request-latency metric today.** Signal #2 needs one of: `nginx-prometheus-exporter` (or nginx log → metrics) on VM1, **or** `blackbox_exporter` on VM5 doing synthetic probes of `wiriri.com` / `api.wiriri.com`. Blackbox is the quickest win and also powers the 🔴 up/down checks. |
| 🟡 | **imgproxy not yet a scrape target** (README §7 already notes this) — add it so VM4 RAM/latency is visible. |
| 🟢 | Confirm exporter `job` names in `prometheus.yml` match the PromQL above (`node`, `backend`, etc.) and adjust labels. |
| 🟢 | Wire a Grafana contact point (email/Telegram/Slack): 🔴 → page channel, 🟡 → tickets/digest channel. |

---

## 4. How to read them together (the upgrade decision)

- **Signal #1 or #2 amber for ~2 weeks** → you've hit the *user/CPU* ceiling → caching + split admin off VM1 first, hardware second.
- **Signal #5 amber** → you've hit the *property/storage* ceiling (~250–300 properties) → grow VM4 disk.
- **Signal #3 firing** → a box is under-sized for its workload → revisit its `mem_limit`s (see `ARCHITECTURE-PROPOSED-2026-06-29.md` §2) before buying RAM.
- **Signal #4** → comes much later; tune the pool before scaling the DB.

> Per repo convention: this is a `*-proposed` reference. Promote into Prometheus alert rules /
> Grafana provisioning via PR when scheduled. Nothing here is applied.
