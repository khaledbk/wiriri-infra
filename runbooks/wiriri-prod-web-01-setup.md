# Wiriri Production Web VPS Setup

This document records the setup steps for the **Wiriri production web server**.

## Server identity

| Item | Value |
|---|---|
| Resource name | `wiriri-prod-web-01` |
| Purpose | Frontend + Admin dashboard + Caddy reverse proxy |
| OS | Ubuntu 24.04.3 LTS |
| User | `tvacadmin` |
| Public IPv4 | `102.207.250.149` |
| App directory | `/opt/wiriri` |
| Firewall strategy | CloudAxion Firewall later; UFW inactive locally |

---

## 1. Connect to the VPS

From your local machine:

```bash
ssh tvacadmin@102.207.250.149
```

Check identity:

```bash
whoami
hostname
lsb_release -a
```

Expected:

```text
tvacadmin
wiriri-prod-web-01
Ubuntu 24.04.3 LTS
```

---

## 2. Set hostname

If hostname is not correct:

```bash
sudo hostnamectl set-hostname wiriri-prod-web-01
```

Edit hosts file:

```bash
sudo nano /etc/hosts
```

Recommended content:

```text
127.0.0.1 localhost
127.0.1.1 wiriri-prod-web-01

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
ssh tvacadmin@102.207.250.149
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

mkdir -p caddy frontend admin
```

Check:

```bash
ls -la /opt/wiriri
```

Expected folders:

```text
admin
caddy
frontend
```

---

## 7. Create Docker Compose for Caddy

Create the compose file:

```bash
cd /opt/wiriri
nano docker-compose.yml
```

Paste:

```yaml
services:
  caddy:
    image: caddy:2
    container_name: wiriri-prod-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
```

---

## 8. Create temporary Caddyfile

Create the Caddyfile:

```bash
nano /opt/wiriri/caddy/Caddyfile
```

Paste:

```caddyfile
:80 {
    respond "wiriri-prod-web-01 is running"
}
```

---

## 9. Start Caddy

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
wiriri-prod-caddy
```

Check locally:

```bash
curl -I http://localhost
curl http://localhost
```

Expected response:

```text
wiriri-prod-web-01 is running
```

Browser test:

```text
http://102.207.250.149
```

---

## 10. Current verified state

The following commands were run successfully:

```bash
docker ps
curl -I http://localhost
curl http://localhost
```

Verified output:

```text
HTTP/1.1 200 OK
Server: Caddy

wiriri-prod-web-01 is running
```

---

## 11. Next steps

After the base web VPS setup, continue with:

1. Configure CloudAxion firewall for `wiriri-prod-web-01`
2. Point DNS records to `102.207.250.149`
3. Replace temporary Caddyfile with real domain routing:
   - `wiriri.com`
   - `www.wiriri.com`
   - `admin.wiriri.com`
4. Deploy Docker images for:
   - frontend Next.js app
   - admin Next.js app
5. Configure automatic deployment through CI/CD

---

## 12. Suggested final web architecture

```text
Internet
   |
   |-- wiriri.com
   |-- www.wiriri.com
   |-- admin.wiriri.com
   |
Caddy container
   |
   |-- frontend container
   |-- admin container
```

---

## 13. Important notes

Do not store uploaded images on this VPS permanently.

Uploaded images/files should go to object storage:

```text
wiriri-prod-storage
```

The web VPS should only run:

```text
Caddy
Frontend app
Admin app
```

Backend, Redis, PostgreSQL, and monitoring should run on separate resources.
