# Wiriri Production API VPS Setup

This document records the setup steps for the **Wiriri production API server**.

## Server identity

| Item | Value |
|---|---|
| Resource name | `wiriri-prod-api-01` |
| Purpose | NestJS backend + workers + Redis |
| OS | Ubuntu 24.04.3 LTS |
| User | `tvacadmin` |
| Public IPv4 | `102.207.250.152` |
| Private VPC IP | `10.130.18.4` |
| App directory | `/opt/wiriri` |
| Firewall strategy | CloudAxion Firewall later; UFW inactive locally |

---

## 1. Connect to the VPS

From your local machine:

```bash
ssh tvacadmin@102.207.250.152
```

Check identity:

```bash
whoami
hostname
lsb_release -a
ip addr show ens3 | grep "inet "
df -h
free -h
```

Expected hostname:

```text
wiriri-prod-api-01
```

Expected private VPC IP:

```text
10.130.18.4
```

---

## 2. Set hostname

If hostname is not correct:

```bash
sudo hostnamectl set-hostname wiriri-prod-api-01
```

Edit hosts file:

```bash
sudo nano /etc/hosts
```

Recommended content:

```text
127.0.0.1 localhost
127.0.1.1 wiriri-prod-api-01

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
```

Check:

```bash
hostname
hostnamectl
```

---

## 3. Update server and install base tools

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

Then reconnect:

```bash
ssh tvacadmin@102.207.250.152
```

---

## 4. Local firewall status

For now, UFW is kept inactive because CloudAxion network firewall will be configured later.

Check:

```bash
sudo ufw status
```

Expected:

```text
Status: inactive
```

Recommended final security model:

```text
CloudAxion Firewall = main firewall
Ubuntu UFW = optional second layer
```

---

## 5. Install Docker

Install Docker:

```bash
curl -fsSL https://get.docker.com | sudo sh
```

Add current user to Docker group:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

Test Docker:

```bash
docker --version
docker compose version
docker run hello-world
```

Current installed versions:

```text
Docker version 29.6.0
Docker Compose version v5.1.4
```

---

## 6. Create Wiriri app directory

```bash
sudo mkdir -p /opt/wiriri
sudo chown -R $USER:$USER /opt/wiriri
cd /opt/wiriri

mkdir -p backend redis
```

Check:

```bash
ls -la /opt/wiriri
```

Expected folders:

```text
backend
redis
```

---

## 7. Create Redis configuration

Create Redis config:

```bash
cd /opt/wiriri
nano redis/redis.conf
```

Paste:

```conf
bind 127.0.0.1
protected-mode yes

port 6379

appendonly yes
appendfsync everysec

maxmemory 512mb
maxmemory-policy allkeys-lru

save 900 1
save 300 10
save 60 10000
```

### Redis configuration explanation

| Setting | Purpose |
|---|---|
| `bind 127.0.0.1` | Redis listens only locally |
| `protected-mode yes` | Extra protection against remote access |
| `appendonly yes` | Enables Redis persistence |
| `appendfsync everysec` | Balanced durability/performance |
| `maxmemory 512mb` | Prevents Redis from consuming all VPS RAM |
| `maxmemory-policy allkeys-lru` | Evicts old keys when memory is full |

---

## 8. Create Docker Compose for Redis

Create the compose file:

```bash
nano /opt/wiriri/docker-compose.yml
```

Paste:

```yaml
services:
  redis:
    image: redis:7
    container_name: wiriri-prod-redis
    restart: unless-stopped
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    volumes:
      - ./redis/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - redis_data:/data
    ports:
      - "127.0.0.1:6379:6379"

volumes:
  redis_data:
```

---

## 9. Start Redis

```bash
cd /opt/wiriri
docker compose up -d
```

Check container:

```bash
docker ps
```

Expected container:

```text
wiriri-prod-redis
```

Check Redis logs:

```bash
docker logs wiriri-prod-redis --tail=50
```

Check Redis connectivity:

```bash
docker exec -it wiriri-prod-redis redis-cli ping
```

Expected:

```text
PONG
```

---

## 10. Confirm Redis is local-only

Run:

```bash
ss -tulpn | grep 6379
```

Expected:

```text
tcp   LISTEN 0      4096          127.0.0.1:6379      0.0.0.0:*
```

This confirms Redis is not exposed publicly.

---

## 11. Current verified state

The following commands were run successfully:

```bash
hostname
sudo ufw status
docker --version
docker compose version
ip addr show ens3 | grep "inet "
ls -la /opt/wiriri
docker ps
docker exec -it wiriri-prod-redis redis-cli ping
ss -tulpn | grep 6379
```

Verified output summary:

```text
Hostname: wiriri-prod-api-01
UFW: inactive
Docker: installed
Docker Compose: installed
Private VPC IP: 10.130.18.4
Redis container: running
Redis test: PONG
Redis binding: 127.0.0.1:6379 only
```

---

## 12. Current Docker services

Current `/opt/wiriri/docker-compose.yml` contains only Redis.

Later, this same compose file will also include:

```text
backend NestJS API
backend workers
```

Final API server target:

```text
wiriri-prod-api-01
- NestJS API
- NestJS workers
- Redis
```

---

## 13. Backend environment notes

The backend should connect to Redis locally:

```env
REDIS_URL=redis://127.0.0.1:6379
```

The backend will later connect to PostgreSQL through the private VPC IP of `wiriri-prod-db-01`:

```env
DATABASE_URL=postgresql://wiriri_app:CHANGE_ME@DB_PRIVATE_IP:5432/wiriri_prod
```

Do not commit real secrets to Git.

---

## 14. Important security notes

Redis must never be exposed publicly.

Do not add public firewall rules for:

```text
6379
```

Allowed public ports for `wiriri-prod-api-01` later:

```text
80
443
22 only from your IP
```

CloudAxion firewall should eventually allow:

```text
Public:
- 80/tcp from 0.0.0.0/0
- 443/tcp from 0.0.0.0/0
- 22/tcp from your IP only

Private/VPC:
- API to PostgreSQL on 5432
- Monitoring to API exporters later
```

---

## 15. Next steps

After the base API VPS setup, continue with:

1. Set up `wiriri-prod-db-01`
2. Install PostgreSQL directly on Ubuntu
3. Create production database and user
4. Bind PostgreSQL to private VPC IP only
5. Allow PostgreSQL access only from `wiriri-prod-api-01`
6. Deploy the NestJS backend Docker image
7. Configure `api.wiriri.com` through Caddy or API reverse proxy
8. Configure monitoring exporters

---

## 16. Suggested final API architecture

```text
Internet
   |
api.wiriri.com
   |
Reverse proxy / Caddy or Nginx
   |
NestJS backend container
   |
   |-- Redis on 127.0.0.1:6379
   |-- PostgreSQL on private VPC
```

---

## 17. Important notes

Do not store uploaded images permanently on this VPS.

Uploaded images/files should go to object storage:

```text
wiriri-prod-storage
```

The API VPS should only run:

```text
NestJS API
NestJS workers
Redis
```

PostgreSQL and monitoring should run on separate resources.
