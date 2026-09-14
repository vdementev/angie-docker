# syntax=docker/dockerfile:1.18
# Reusable Angie base image — designed to live IN FRONT of other services
# (acts as the public-facing reverse proxy / TLS terminator on a docker host).
#
# Angie + brotli + cache-purge + zstd dynamic modules, plus an entrypoint
# that aligns the worker user with the mounted /var/run/docker.sock group
# so Angie's docker_endpoint upstream resolver can talk to the daemon for
# service discovery. The healthcheck then keeps watching that socket, and
# two opt-in watchdogs handle a socket that dies mid-flight
# (ANGIE_SOCKET_WATCH) and config reloads (ANGIE_WATCH_CONFIG).
#
# Consumers (a compose stack, an orchestrator): mount your own
# /etc/angie/angie.conf (and http.d/*.conf) plus TLS certs. The shipped
# angie.conf is the packaged one with latency tuning applied — no vhost
# of our own beyond Angie's stock default.

FROM mirror.gcr.io/library/debian:13-slim

# OCI metadata. Source/url/title/licenses can be overridden at build time
# via --label so downstream projects don't have to fork this Dockerfile.
LABEL org.opencontainers.image.title="angie" \
      org.opencontainers.image.description="Reusable Angie base — brotli + cache-purge + zstd, with Docker-socket group integration for service discovery." \
      org.opencontainers.image.url="https://hub.docker.com/r/dementev/angie" \
      org.opencontainers.image.documentation="https://github.com/vdementev/angie-docker#readme" \
      org.opencontainers.image.source="https://github.com/vdementev/angie-docker" \
      org.opencontainers.image.vendor="Lotus Web Agency" \
      org.opencontainers.image.authors="Vasilii Dementev https://vasiliidementev.com" \
      org.opencontainers.image.licenses="MIT"

# Trust anchor for the Angie apt repository. Pinned by content hash rather
# than trusted on first use: a swapped key at angie.software fails the build
# instead of silently signing whatever it likes. Bump both together.
ARG ANGIE_SIGNING_URL=https://angie.software/keys/angie-signing.gpg
ARG ANGIE_SIGNING_SHA256=06ef4d35c4f3cf1dfa2dc37751bdd51a95a5fb64390ac11f60587e06183ebfe7

# Entrypoint env defaults. Override at runtime to point at a different
# socket, target group, or worker user.
ENV FILE_FOR_GROUP=/var/run/docker.sock \
    DOCKER_GROUP_NAME=docker \
    ANGIE_USER=angie \
    ANGIE_WORKER_PROCESSES=auto

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY angie-healthcheck.sh /usr/local/bin/angie-healthcheck

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt_get() { apt-get -o Acquire::Retries=3 -y --no-install-recommends "$@"; }; \
    # dpkg maintainer scripts must not try to start services in a container.
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; \
    chmod +x /usr/sbin/policy-rc.d; \
    \
    apt-get -o Acquire::Retries=3 update; \
    apt_get upgrade; \
    # ca-certificates and tzdata stay in the final image: Angie may
    # proxy_pass over HTTPS and resolve upstreams by name, and operators
    # expect non-UTC logs. curl is the healthcheck's probe tool — it speaks
    # both unix sockets and HTTP, so socat/wget are not needed.
    apt_get install ca-certificates curl tzdata; \
    \
    curl -fsSL --retry 3 -o /usr/share/keyrings/angie.gpg "$ANGIE_SIGNING_URL"; \
    echo "${ANGIE_SIGNING_SHA256}  /usr/share/keyrings/angie.gpg" | sha256sum -c -; \
    chmod 0644 /usr/share/keyrings/angie.gpg; \
    # Track whatever Debian release the base image is on, the way the Alpine
    # build tracked /etc/alpine-release.
    . /etc/os-release; \
    printf '%s\n' \
        'Types: deb' \
        "URIs: https://download.angie.software/angie/debian/${VERSION_ID}" \
        "Suites: ${VERSION_CODENAME}" \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/angie.gpg' \
        > /etc/apt/sources.list.d/angie.sources; \
    \
    apt-get -o Acquire::Retries=3 update; \
    apt_get install \
            angie \
            angie-module-brotli \
            angie-module-cache-purge \
            angie-module-zstd; \
    \
    apt_get autoremove; \
    apt-get clean; \
    rm -f /usr/sbin/policy-rc.d; \
    \
    # Tidy. The -debug.so modules and the angie-debug binary are ~2.5 MB of
    # symbols we never load (/usr/sbin/angie is a symlink to angie-nodebug),
    # and the sysv/systemd/logrotate wiring is dead weight in a container
    # that runs one foreground master and logs to stdout.
    rm -rf /var/lib/apt/lists/* /root/.cache /tmp/* \
           /usr/share/man /usr/share/doc /usr/share/lintian \
           /usr/sbin/angie-debug \
           /usr/lib/systemd /etc/init.d/angie /etc/logrotate.d/angie \
           /etc/default/angie; \
    find /usr/lib/angie/modules -name '*-debug.so' -delete; \
    \
    # Hardening: nothing in this image needs to escalate, so strip every
    # setuid/setgid bit Debian ships (su, mount, passwd, chsh, newgrp, …).
    # groupadd/groupmod/usermod, which the entrypoint does use, are plain
    # root-only binaries and are unaffected.
    find / -xdev -type f -perm /6000 -exec chmod a-s '{}' +; \
    \
    ln -sf /dev/stdout /var/log/angie/access.log; \
    ln -sf /dev/stderr /var/log/angie/error.log; \
    mkdir -p /var/cache/angie/client_temp \
             /var/cache/angie/proxy_temp \
             /var/cache/angie/fastcgi_temp \
             /var/cache/angie/uwsgi_temp \
             /var/cache/angie/scgi_temp \
             /var/run/angie \
             /etc/angie/main.d; \
    # Main-level include dir. The entrypoint rewrites worker_processes.conf
    # from ANGIE_WORKER_PROCESSES on every start; this baked default keeps
    # the old behaviour if /etc/angie is mounted read-only (an empty include
    # would silently leave Angie on its built-in default of one worker).
    printf 'worker_processes  auto;\n' > /etc/angie/main.d/worker_processes.conf; \
    chown -R angie:angie /var/cache/angie \
                         /var/log/angie \
                         /var/run/angie; \
    chmod 700 /usr/local/bin/docker-entrypoint.sh \
              /usr/local/bin/angie-healthcheck

# Latency-tuned replacement for the packaged angie.conf. Copied after the
# install so a package upgrade in a derived image can't quietly revert it.
COPY --chmod=0644 angie.conf /etc/angie/angie.conf

# Build-time gate: a typo in the tuning never ships.
RUN set -eux; angie -t

WORKDIR /app

# 80  — HTTP (typically published)
# 443 — HTTPS / HTTP/3 (TCP + UDP for QUIC)
EXPOSE 80/tcp 443/tcp 443/udp

STOPSIGNAL SIGQUIT

# Master alive + (when mounted) the Docker socket still answers, so a dead
# socket shows up before the next reload turns it into a sitewide 502.
# Set ANGIE_HEALTHCHECK_URL to add an HTTP probe of your own vhost.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/usr/local/bin/angie-healthcheck"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["angie", "-g", "daemon off;"]
