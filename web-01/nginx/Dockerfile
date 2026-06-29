# wiriri edge nginx + GeoIP2.
# Stock nginx:stable has no GeoIP module, so we compile the geoip2 dynamic
# module against the exact nginx version (--with-compat keeps it ABI-compatible
# with the official binary), then load it at runtime.
#
# Geo DB: DB-IP "IP to Country Lite" — MMDB format (same as MaxMind GeoLite2),
# free, NO account/license key required, refreshed monthly, CC BY 4.0.
# Attribution: "IP Geolocation by DB-IP" (https://db-ip.com). Kept in nginx.conf
# and the cookie policy. The .mmdb is baked at build time and can be hot-swapped
# on-box via refresh-geoip.sh (auto_reload picks it up).

ARG NGINX_VERSION=1.28.0
ARG GEOIP2_MODULE_VERSION=3.4

FROM nginx:${NGINX_VERSION} AS build
ARG NGINX_VERSION
ARG GEOIP2_MODULE_VERSION
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential ca-certificates wget git \
      libpcre3-dev zlib1g-dev libssl-dev libmaxminddb-dev; \
    wget -O /tmp/nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    tar -C /tmp -xzf /tmp/nginx.tar.gz; \
    git clone --depth 1 -b "${GEOIP2_MODULE_VERSION}" \
      https://github.com/leev/ngx_http_geoip2_module.git /tmp/geoip2; \
    cd "/tmp/nginx-${NGINX_VERSION}"; \
    ./configure --with-compat --add-dynamic-module=/tmp/geoip2; \
    make modules; \
    mkdir -p /out; \
    cp objs/ngx_http_geoip2_module.so /out/

FROM nginx:${NGINX_VERSION}
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libmaxminddb0 ca-certificates wget; \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ngx_http_geoip2_module.so /etc/nginx/modules/ngx_http_geoip2_module.so
# Bake the current DB-IP IP-to-Country Lite DB. Fall back to last month near the
# month boundary (the new file appears a day or two in). refresh-geoip.sh can
# replace it in place on the running box without a rebuild.
RUN set -eux; \
    mkdir -p /etc/nginx/geoip; \
    m="$(date -u +%Y-%m)"; \
    pm="$(date -u -d 'last month' +%Y-%m 2>/dev/null || date -u +%Y-%m)"; \
    ( wget -qO /tmp/db.mmdb.gz "https://download.db-ip.com/free/dbip-country-lite-${m}.mmdb.gz" \
      || wget -qO /tmp/db.mmdb.gz "https://download.db-ip.com/free/dbip-country-lite-${pm}.mmdb.gz" ); \
    gunzip -c /tmp/db.mmdb.gz > /etc/nginx/geoip/dbip-country-lite.mmdb; \
    rm -f /tmp/db.mmdb.gz; \
    test -s /etc/nginx/geoip/dbip-country-lite.mmdb
