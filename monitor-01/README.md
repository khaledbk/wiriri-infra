# wiriri-prod-monitor-01 (10.130.18.6)

Prometheus + Grafana. Scrapes node-exporter on every VPS `:9100` (web .3, api .4, db .5,
monitor .6, storage .7) plus redis-exporter (api `:9121`). Add **imgproxy** as a scrape
target once it's deployed on storage-01.

Full build steps in `../runbooks/wiriri-prod-monitor-01-setup.md`.

> Capture the live `docker-compose.yml` / prometheus.yml here when convenient (read-only audit
> pending) so this dir mirrors actual state.
