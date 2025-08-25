FROM alpine:3.22

RUN set -eux; \
    apk update; \
    apk upgrade --no-interactive; \
    apk --no-cache add curl ca-certificates tzdata; \
    curl -o /etc/apk/keys/angie-signing.rsa https://angie.software/keys/angie-signing.rsa; \
    echo "https://download.angie.software/angie/alpine/v$(egrep -o \
        '[0-9]+\.[0-9]+' /etc/alpine-release)/main" >> /etc/apk/repositories; \
    apk add --no-cache angie \
                       angie-module-brotli \
                       angie-module-cache-purge \
                       angie-module-modsecurity \
                       angie-module-zstd \
                       angie-console-light; \
    rm /etc/apk/keys/angie-signing.rsa; \
    rm -rf /var/cache/apk/*; \
    rm -rf /root/.cache; \
    rm -rf /tmp/*; \
    echo "net.core.rmem_max=2500000 " >> /etc/sysctl.conf; \
    echo "net.core.wmem_max=2500000 " >> /etc/sysctl.conf; \
    ln -sf /dev/stdout /var/log/angie/access.log; \
    ln -sf /dev/stderr /var/log/angie/error.log; \
    addgroup --gid 996 docker; \
    addgroup angie docker

WORKDIR /app
EXPOSE 80
# STOPSIGNAL SIGQUIT
CMD ["angie", "-g", "daemon off;"]