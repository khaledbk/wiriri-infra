# Wiriri Production Database VPS Setup

This document records the setup steps and verified state for the **Wiriri production database server**.

> Infrastructure name: `wiriri`
>
> Application database convention:
>
> - Database: `tvac_prod`
> - User: `tvac_user`

---

## Server identity

| Item | Value |
|---|---|
| Resource name | `wiriri-prod-db-01` |
| Purpose | PostgreSQL + PostGIS |
| OS | Ubuntu 24.04.3 LTS |
| User | `tvacadmin` |
| Private VPC IP | `10.130.18.5` |
| API private VPC IP | `10.130.18.4` |
| Firewall strategy | CloudAxion Firewall later; UFW inactive locally |
| PostgreSQL version | PostgreSQL 16.14 |
| Database name | `tvac_prod` |
| Database user | `tvac_user` |

---

## 1. Connect to the VPS

From your local machine:

```bash
ssh tvacadmin@DB_PUBLIC_IP
```

Replace `DB_PUBLIC_IP` with the public IPv4 of `wiriri-prod-db-01`.

---

## 2. Verify server identity

Run:

```bash
whoami
hostname
lsb_release -a
ip addr show ens3 | grep "inet "
df -h
free -h
sudo ufw status
```

Verified output summary:

```text
User: tvacadmin
Hostname: wiriri-prod-db-01
OS: Ubuntu 24.04.3 LTS
Private VPC IP: 10.130.18.5
UFW: inactive
```

---

## 3. Resource note

Observed initial server size:

```text
RAM: ~1 GB
Disk: ~20 GB
```

This is acceptable for setup/testing, but before real production launch, recommended minimum is:

```text
2 CPU
4 GB RAM
40–60 GB disk minimum
```

PostgreSQL should not run production traffic for long on only 1 GB RAM.

---

## 4. Update server and install base tools

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y curl wget git unzip htop fail2ban ca-certificates gnupg lsb-release
```

Check if reboot is needed:

```bash
test -f /var/run/reboot-required && echo "REBOOT NEEDED" || echo "NO REBOOT NEEDED"
```

If needed:

```bash
sudo reboot
```

Then reconnect.

---

## 5. Install PostgreSQL

Ubuntu 24.04 installs PostgreSQL 16 by default.

```bash
sudo apt install -y postgresql postgresql-contrib
```

Check status:

```bash
sudo systemctl status postgresql --no-pager
```

Check version:

```bash
sudo -u postgres psql -c "SELECT version();"
```

Verified PostgreSQL version:

```text
PostgreSQL 16.14 (Ubuntu 16.14-0ubuntu0.24.04.1)
```

---

## 6. Install PostGIS

Install PostGIS packages for PostgreSQL 16:

```bash
sudo apt update
sudo apt install -y postgis postgresql-16-postgis-3 postgresql-16-postgis-3-scripts
```

Verify packages:

```bash
dpkg -l | grep postgis
```

---

## 7. Create production database and user

Open PostgreSQL shell:

```bash
sudo -u postgres psql
```

Inside `psql`, create the production database:

```sql
CREATE DATABASE tvac_prod;
```

If an incorrect database was created, for example `wiriri_prod`, remove it:

```sql
DROP DATABASE IF EXISTS wiriri_prod;
```

Create the app user:

```sql
CREATE USER tvac_user WITH ENCRYPTED PASSWORD 'CHANGE_THIS_STRONG_PASSWORD';
```

Grant access to the database:

```sql
GRANT CONNECT ON DATABASE tvac_prod TO tvac_user;
```

Connect to the new database:

```sql
\c tvac_prod
```

Enable PostGIS extensions:

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
```

Grant schema permissions:

```sql
GRANT USAGE ON SCHEMA public TO tvac_user;
GRANT CREATE ON SCHEMA public TO tvac_user;
```

Grant permissions on existing tables and sequences:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO tvac_user;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO tvac_user;
```

Grant permissions on future tables and sequences:

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO tvac_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO tvac_user;
```

Exit:

```sql
\q
```

---

## 8. Verify local PostgreSQL login

From `wiriri-prod-db-01`, test local connection.

Use `PGPASSWORD` with single quotes if the password contains special characters like `!`.

```bash
PGPASSWORD='YOUR_DB_PASSWORD' psql -h 127.0.0.1 -U tvac_user -d tvac_prod -c "SELECT current_database(), current_user;"
```

Verified result:

```text
 current_database | current_user
------------------+--------------
 tvac_prod        | tvac_user
```

---

## 9. Configure PostgreSQL private networking

PostgreSQL should listen only on localhost and the private VPC IP.

Edit:

```bash
sudo nano /etc/postgresql/16/main/postgresql.conf
```

Set:

```conf
listen_addresses = '127.0.0.1,10.130.18.5'
```

Then edit `pg_hba.conf`:

```bash
sudo nano /etc/postgresql/16/main/pg_hba.conf
```

Add:

```conf
host    tvac_prod    tvac_user    10.130.18.4/32    scram-sha-256
```

This allows:

```text
Database: tvac_prod
User: tvac_user
Source: wiriri-prod-api-01 private IP 10.130.18.4 only
```

Restart PostgreSQL:

```bash
sudo systemctl restart postgresql
```

Check listening sockets:

```bash
ss -tulpn | grep 5432
```

Expected:

```text
127.0.0.1:5432
10.130.18.5:5432
```

---

## 10. Test PostgreSQL from API VPS

Connect to the API server:

```bash
ssh tvacadmin@102.207.250.152
```

Install PostgreSQL client if needed:

```bash
sudo apt update
sudo apt install -y postgresql-client
```

Test private VPC connection:

```bash
PGPASSWORD='YOUR_DB_PASSWORD' psql -h 10.130.18.5 -U tvac_user -d tvac_prod -c "SELECT current_database(), current_user;"
```

Verified result from `wiriri-prod-api-01`:

```text
 current_database | current_user
------------------+--------------
 tvac_prod        | tvac_user
```

This confirms:

```text
wiriri-prod-api-01 10.130.18.4
   |
   | PostgreSQL private VPC connection OK
   |
wiriri-prod-db-01  10.130.18.5
```

---

## 11. Verify PostGIS

Run from the DB server:

```bash
sudo -u postgres psql -d tvac_prod -c "SELECT PostGIS_Version();"
```

Expected output should show a PostGIS `3.x` version.

---

## 12. Backend connection string

The backend should connect to PostgreSQL using the private VPC IP:

```env
DATABASE_URL=postgresql://tvac_user:YOUR_DB_PASSWORD@10.130.18.5:5432/tvac_prod
```

Do not commit real secrets to Git.

---

## 13. Password rotation note

If a database password was pasted into a chat, terminal recording, screenshot, or any shared place, rotate it.

On `wiriri-prod-db-01`:

```bash
sudo -u postgres psql
```

Then:

```sql
ALTER USER tvac_user WITH PASSWORD 'NEW_STRONG_PASSWORD_HERE';
\q
```

Retest from API server:

```bash
PGPASSWORD='NEW_STRONG_PASSWORD_HERE' psql -h 10.130.18.5 -U tvac_user -d tvac_prod -c "SELECT current_database(), current_user;"
```

---

## 14. Current verified state

Verified:

```text
Hostname: wiriri-prod-db-01
Private VPC IP: 10.130.18.5
PostgreSQL: installed
PostgreSQL version: 16.14
Database: tvac_prod
User: tvac_user
Local DB login: OK
API-to-DB private VPC connection: OK
PostGIS: installed/enabled
```

---

## 15. Next required steps

The database is connected, but production operations are not complete until these are done:

1. Rotate the database password if it was exposed anywhere.
2. Configure PostgreSQL backups:
   - local backups
   - off-server backups
   - restore tests
3. Configure monitoring:
   - `node_exporter`
   - `postgres_exporter`
   - monitoring access only from `wiriri-prod-monitor-01`
4. Configure CloudAxion firewall:
   - no public PostgreSQL access
   - allow `5432/tcp` only from `wiriri-prod-api-01` private IP
5. Resize DB VPS before real production traffic:
   - recommended minimum: 2 CPU / 4 GB RAM / 40–60 GB disk

---

## 16. Planned CloudAxion firewall rules

For `wiriri-prod-db-01`, do not expose PostgreSQL publicly.

Do not allow:

```text
5432 from 0.0.0.0/0
```

Only allow:

```text
5432 from 10.130.18.4
```

Recommended inbound rules later:

| Port | Source | Purpose |
|---:|---|---|
| `22` | Your public IP only | SSH |
| `5432` | `10.130.18.4/32` | PostgreSQL from API server |
| `9100` | Monitoring private IP only | Node exporter later |
| `9187` | Monitoring private IP only | PostgreSQL exporter later |

---

## 17. Suggested production database architecture

```text
wiriri-prod-api-01
- NestJS API
- Redis
- private IP: 10.130.18.4

wiriri-prod-db-01
- PostgreSQL 16
- PostGIS
- database: tvac_prod
- user: tvac_user
- private IP: 10.130.18.5
```

---

## 18. Important notes

PostgreSQL should be installed directly on Ubuntu for this production setup.

Do not run PostgreSQL in Docker on this VPS unless you intentionally choose a containerized database strategy and understand the backup/storage implications.

The DB VPS should run only:

```text
PostgreSQL
PostGIS
backup scripts
postgres_exporter later
node_exporter later
```

Avoid running these on the DB VPS:

```text
frontend
admin dashboard
backend app runtime
Redis
Grafana
Prometheus
```
