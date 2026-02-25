FROM alpine:3.23

# ENV FILE_FOR_GROUP=/var/run/docker.sock \
#     DOCKER_GROUP_NAME=docker \
#     ANGIE_USER=angie

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN set -eux; \
    apk update; \
    apk upgrade --no-interactive; \
    apk --no-cache add ca-certificates tzdata su-exec; \
    wget -O /etc/apk/keys/angie-signing.rsa https://angie.software/keys/angie-signing.rsa; \
    echo "https://download.angie.software/angie/alpine/v$(grep -Eo \
         '[0-9]+\.[0-9]+' /etc/alpine-release)/main" >> /etc/apk/repositories; \
    apk add --no-cache angie \
            angie-module-brotli \
            angie-module-cache-purge \
            angie-module-zstd \
            angie-console-light; \
    rm /etc/apk/keys/angie-signing.rsa; \
    rm -rf /var/cache/apk/*; \
    rm -rf /root/.cache; \
    rm -rf /tmp/*; \
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

EXPOSE 80/tcp 443/tcp 443/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["angie", "-g", "daemon off;"]
