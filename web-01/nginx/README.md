# web-01 edge nginx — GeoIP2 consent signal

The edge nginx is a **custom image** (`Dockerfile`) = stock `nginx` + the compiled
`ngx_http_geoip2_module` + a baked **DB-IP IP-to-Country Lite** database. It looks up
the visitor's country from their IP and injects an `X-Geo-EEA` request header into the
`wiriri.com` webapp upstream. The webapp uses that to set the Google **Consent Mode v2**
default server-side: `analytics_storage = 'denied'` for EEA/UK/unknown (consent required),
`'granted'` for confirmed non-EEA visitors.

- `X-Geo-EEA: 1` → EEA/UK or unknown → GA denied until the user accepts in the banner.
- `X-Geo-EEA: 0` → confirmed non-EEA → GA auto-granted (banner still shown for opt-out).

## Geo database — DB-IP Lite (no key)

`dbip-country-lite.mmdb` is **free, MMDB format (same as MaxMind GeoLite2), needs NO
account or license key**, updated monthly, licensed **CC BY 4.0**.
**Attribution (required):** *IP Geolocation by DB-IP* — https://db-ip.com
The file is baked at image build and is git-ignored (regenerated, not source).

## Files

- `Dockerfile` — builds the geoip2 dynamic module (`--with-compat`) and bakes the DB.
- `nginx.conf` — `load_module` + `geoip2 {}` lookup + EEA/UK `map` → `$is_eea`.
- `default.conf` — vhosts; `wiriri.com` adds `proxy_set_header X-Geo-EEA $is_eea;`.
- `refresh-geoip.sh` — optional monthly in-place DB refresh (host-mount `./nginx/geoip`).

## Deploy

```bash
cd /opt/wiriri            # web-01
docker compose build nginx
docker compose up -d nginx
docker exec wiriri-prod-nginx nginx -t   # config OK
```

## Verify

```bash
# module loaded + DB present
docker exec wiriri-prod-nginx sh -c 'ls -l /etc/nginx/modules/ngx_http_geoip2_module.so /etc/nginx/geoip/'
# header reaches the app (run from a non-EEA and an EEA IP / VPN)
curl -s -H 'Host: wiriri.com' https://wiriri.com -I   # app HTML is dynamic; check GA in DebugView
```

In GA4 **DebugView / Realtime**: a non-EEA visit should record hits immediately; an EEA
visit records only after clicking **Accept** in the cookie banner (with Consent Mode,
denied visits still send cookieless modeling pings).

## Monthly DB refresh (optional, recommended)

Uncomment the `./nginx/geoip:/etc/nginx/geoip` volume in `docker-compose.yml`, then:

```bash
# crontab -e  (web-01)
17 4 1 * *  GEOIP_DIR=/opt/wiriri/nginx/geoip /opt/wiriri/nginx/refresh-geoip.sh >> /var/log/geoip-refresh.log 2>&1
```

`geoip2 { auto_reload 60m; }` reloads the new file with no nginx restart.
