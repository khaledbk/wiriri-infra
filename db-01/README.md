# wiriri-prod-db-01 (10.130.18.5)

PostgreSQL (primary data store). Reached only over the private VPC from api-01 (.4) on `:5432`.
Full build steps in `../runbooks/wiriri-prod-db-01-setup-updated.md`.

- Bind PostgreSQL to the **private VPC IP only**; allow `:5432` only from `10.130.18.4/32` (api).
- Backend connects via `DATABASE_URL=postgresql://wiriri_app:***@10.130.18.5:5432/wiriri_prod` (Infisical).
- node-exporter on `10.130.18.5:9100` for the monitor box.

> Capture the live `docker-compose.yml` / postgres config here when convenient (read-only audit
> pending) so this dir mirrors actual state like web-01/api-01/storage-01.
