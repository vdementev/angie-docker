# Reusable Angie base image — designed to live IN FRONT of other services
# (acts as the public-facing reverse proxy / TLS terminator on a docker host).
#
# Angie + brotli + cache-purge + zstd dynamic modules, plus an entrypoint
# that aligns the worker user with the mounted /var/run/docker.sock group
# so Angie's docker_endpoint upstream resolver can talk to the daemon for
# service discovery.
#
# Consumers (a compose stack, an orchestrator): mount your own
# /etc/angie/angie.conf (and conf.d/*.conf) plus TLS certs. The image
# itself ships only Angie's apk defaults — no opinionated vhost.
# syntax=docker/dockerfile:1.6

FROM mirror.gcr.io/library/alpine:3.23

# OCI metadata. Source/url/title/licenses can be overridden at build time
# via --label so downstream projects don't have to fork this Dockerfile.
LABEL org.opencontainers.image.title="angie"
LABEL org.opencontainers.image.description="Reusable Angie base — brotli + cache-purge + zstd, with Docker-socket group integration for service discovery."
LABEL org.opencontainers.image.source="https://github.com/vdementev/angie"
LABEL org.opencontainers.image.licenses="MIT"

# Entrypoint env defaults. Override at runtime to point at a different
# socket, target group, or worker user.
ENV FILE_FOR_GROUP=/var/run/docker.sock \
    DOCKER_GROUP_NAME=docker \
    ANGIE_USER=angie

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN set -eux; \
    apk update; \
    apk upgrade --no-interactive; \
    wget -O /etc/apk/keys/angie-signing.rsa https://angie.software/keys/angie-signing.rsa; \
    echo "https://download.angie.software/angie/alpine/v$(grep -Eo \
         '[0-9]+\.[0-9]+' /etc/alpine-release)/main" >> /etc/apk/repositories; \
    apk add --no-cache \
            ca-certificates tzdata su-exec \
            angie \
            angie-module-brotli \
            angie-module-cache-purge \
            angie-module-zstd; \
    rm /etc/apk/keys/angie-signing.rsa; \
    # Tidy: apk caches, root .cache, /tmp, manpages and docs. ca-certificates
    # and tzdata stay (Angie may proxy_pass over HTTPS and resolve upstreams
    # by name, and operators expect non-UTC logs).
    rm -rf /var/cache/apk/* /root/.cache /tmp/* /usr/share/man /usr/share/doc; \
    ln -sf /dev/stdout /var/log/angie/access.log; \
    ln -sf /dev/stderr /var/log/angie/error.log; \
    mkdir -p /var/cache/angie/client_temp \
             /var/cache/angie/proxy_temp \
             /var/cache/angie/fastcgi_temp \
             /var/cache/angie/uwsgi_temp \
             /var/cache/angie/scgi_temp \
             /var/run/angie; \
    chown -R angie:angie /var/cache/angie \
                         /var/log/angie \
                         /var/run/angie; \
    chmod 700 /usr/local/bin/docker-entrypoint.sh

WORKDIR /app

# 80  — HTTP (typically published)
# 443 — HTTPS / HTTP/3 (TCP + UDP for QUIC)
EXPOSE 80/tcp 443/tcp 443/udp

STOPSIGNAL SIGQUIT

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["angie", "-g", "daemon off;"]
