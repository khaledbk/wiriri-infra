# wiriri-prod-monitor-01 Setup

## Server identity

| Item | Value |
|---|---|
| Server name | `wiriri-prod-monitor-01` |
| Role | Monitoring server |
| OS | Ubuntu 24.04 LTS |
| Private VPC IP | `10.130.18.6` |
| User | `tvacadmin` |
| Base directory | `/opt/wiriri` |

## Monitoring architecture

This server runs the central monitoring stack for the Wiriri production environment.

| Service | Purpose | Access |
|---|---|---|
| Caddy | Reverse proxy for Grafana | Public `80/443` |
| Grafana | Dashboards and visualization | Behind Caddy |
| Prometheus | Metrics collection and storage | Local-only |
| node_exporter | Monitor this VPS host | Private VPC only |

## Monitored targets

| Server | Private IP | Exporter | Port |
|---|---:|---|---:|
| `wiriri-prod-web-01` | `10.130.18.3` | node_exporter | `9100` |
| `wiriri-prod-api-01` | `10.130.18.4` | node_exporter | `9100` |
| `wiriri-prod-db-01` | `10.130.18.5` | node_exporter | `9100` |
| `wiriri-prod-monitor-01` | `10.130.18.6` | node_exporter | `9100` |
| `wiriri-prod-db-01` | `10.130.18.5` | postgres_exporter | `9187` |
| `wiriri-prod-api-01` | `10.130.18.4` | redis_exporter | `9121` |
| `wiriri-prod-monitor-01` | localhost | Prometheus | `9090` |

Current Prometheus status:

```text
7/7 targets up
```

## Directory structure

```text
/opt/wiriri
├── caddy/
│   └── Caddyfile
├── grafana/
├── prometheus/
│   └── prometheus.yml
└── docker-compose.yml
```

## Docker Compose

File:

```bash
/opt/wiriri/docker-compose.yml
```

Current recommended content:

```yaml
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: wiriri-prod-prometheus
    restart: unless-stopped
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=7d"
      - "--storage.tsdb.retention.size=8GB"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    ports:
      - "127.0.0.1:9090:9090"

  grafana:
    image: grafana/grafana:latest
    container_name: wiriri-prod-grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: CHANGE_THIS_GRAFANA_PASSWORD
      GF_SERVER_DOMAIN: monitor.wiriri.com
      GF_SERVER_ROOT_URL: https://monitor.wiriri.com
    volumes:
      - grafana_data:/var/lib/grafana
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      - prometheus

  caddy:
    image: caddy:2
    container_name: wiriri-prod-monitor-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - grafana

  node_exporter:
    image: prom/node-exporter:latest
    container_name: wiriri-prod-monitor-node-exporter
    restart: unless-stopped
    command:
      - "--path.rootfs=/host"
    pid: host
    volumes:
      - "/:/host:ro,rslave"
    ports:
      - "10.130.18.6:9100:9100"

volumes:
  prometheus_data:
  grafana_data:
  caddy_data:
  caddy_config:
```

Apply changes:

```bash
cd /opt/wiriri
docker compose up -d
```

## Caddy configuration

Temporary HTTP-only Caddyfile before DNS is ready:

```caddyfile
:80 {
    reverse_proxy grafana:3000
}
```

Final HTTPS Caddyfile after DNS points `monitor.wiriri.com` to this server:

```caddyfile
monitor.wiriri.com {
    reverse_proxy grafana:3000
}
```

File path:

```bash
/opt/wiriri/caddy/Caddyfile
```

Reload Caddy:

```bash
docker restart wiriri-prod-monitor-caddy
```

## Prometheus configuration

File:

```bash
/opt/wiriri/prometheus/prometheus.yml
```

Current content:

```yaml
global:
  scrape_interval: 60s
  evaluation_interval: 60s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets:
          - "localhost:9090"

  - job_name: "node"
    static_configs:
      - targets:
          - "10.130.18.3:9100" # wiriri-prod-web-01
          - "10.130.18.4:9100" # wiriri-prod-api-01
          - "10.130.18.5:9100" # wiriri-prod-db-01
          - "10.130.18.6:9100" # wiriri-prod-monitor-01

  - job_name: "postgres"
    static_configs:
      - targets:
          - "10.130.18.5:9187" # wiriri-prod-db-01 PostgreSQL

  - job_name: "redis"
    static_configs:
      - targets:
          - "10.130.18.4:9121" # wiriri-prod-api-01 Redis
```

Restart Prometheus after editing:

```bash
docker restart wiriri-prod-prometheus
```

## Verification commands

Check containers:

```bash
docker ps
```

Check listening ports:

```bash
ss -tulpn | grep -E "80|443|3000|9090|9100"
```

Expected bindings:

```text
0.0.0.0:80          Caddy
0.0.0.0:443         Caddy
127.0.0.1:3000      Grafana
127.0.0.1:9090      Prometheus
10.130.18.6:9100    monitor node_exporter
```

Check Grafana through Caddy:

```bash
curl -I http://localhost
```

Expected:

```text
HTTP/1.1 302 Found
Location: /login
Via: 1.1 Caddy
```

Check all Prometheus targets:

```bash
curl -s http://localhost:9090/api/v1/targets \
  | grep -o '"health":"[^"]*"' \
  | sort | uniq -c
```

Expected:

```text
7 "health":"up"
```

Detailed target list:

```bash
curl -s http://localhost:9090/api/v1/targets \
  | python3 -c 'import sys,json; data=json.load(sys.stdin);
for t in data["data"]["activeTargets"]:
    print(t["scrapeUrl"], t["health"], t.get("lastError",""))'
```

Expected:

```text
http://10.130.18.3:9100/metrics up
http://10.130.18.4:9100/metrics up
http://10.130.18.5:9100/metrics up
http://10.130.18.6:9100/metrics up
http://10.130.18.5:9187/metrics up
http://10.130.18.4:9121/metrics up
http://localhost:9090/metrics up
```

## Grafana setup

Open Grafana:

```text
http://MONITOR_PUBLIC_IP
```

Temporary access is via HTTP until DNS and HTTPS are configured.

Login:

```text
Username: admin
Password: the value set in GF_SECURITY_ADMIN_PASSWORD
```

Recommended first action: change the admin password after login.

### Add Prometheus datasource

In Grafana:

```text
Connections → Data sources → Add data source → Prometheus
```

Use this URL:

```text
http://prometheus:9090
```

Click:

```text
Save & test
```

Expected:

```text
Successfully queried the Prometheus API.
```

### Recommended dashboards

Import these dashboard IDs:

| Dashboard | Purpose |
|---|---|
| `1860` | Node Exporter Full |
| `9628` | PostgreSQL exporter dashboard |
| `763` or `11835` | Redis dashboard |

Grafana path:

```text
Dashboards → New → Import
```

Use the Prometheus datasource when prompted.

## Security notes

Current exposure:

| Port | Status |
|---:|---|
| `80` | Public via Caddy |
| `443` | Public via Caddy |
| `3000` | Localhost-only |
| `9090` | Localhost-only |
| `9100` | Private VPC only |
| `9187` | Private VPC only on DB |
| `9121` | Private VPC only on API |

Recommended CloudAxion firewall rules later:

| Port | Allow from |
|---:|---|
| `80` | Public, optional redirect only |
| `443` | Public or trusted admin IPs |
| `3000` | Block public |
| `9090` | Block public |
| `9100` | Only monitor private IP `10.130.18.6` |
| `9187` | Only monitor private IP `10.130.18.6` |
| `9121` | Only monitor private IP `10.130.18.6` |
| `5432` | Only API private IP `10.130.18.4` |

## Operational notes

Retention is intentionally light because this VPS is small:

```text
Prometheus retention time: 7 days
Prometheus retention size: 8GB
Scrape interval: 60s
```

If monitoring load grows, increase the monitor VPS disk and RAM before increasing retention.
