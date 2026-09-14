#!/usr/bin/env bash
# Smoke tests for the Angie base image.
#
#   ./tests.sh                  # builds the image from this repo, then tests it
#   IMAGE=some/angie ./tests.sh  # tests an already-built image (this is how CI
#                                 # calls it, via the reusable workflow's
#                                 # test-command input)
set -euo pipefail

IMAGE="${IMAGE:-}"
UPSTREAM_IMAGE=busybox:1.36
NETWORK=docker-angie-test-net
UPSTREAM=docker-angie-test-upstream
FIXTURE=docker-angie-test-fixture
CONTAINER=docker-angie-test

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
  docker rm -f "$CONTAINER" "$UPSTREAM" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
tmp="$(mktemp -d)"
trap cleanup EXIT

# ── Build ───────────────────────────────────────────────────────
if [ -z "$IMAGE" ]; then
  info "Building image"
  docker build -q -t docker-angie-test-base . >/dev/null
  IMAGE=docker-angie-test-base
fi
echo "Testing image: $IMAGE"

check_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
check_match() { # name pattern actual
  if printf '%s' "$3" | grep -Eqi -- "$2"; then ok "$1"; else bad "$1 (expected to match '$2', got '$3')"; fi
}

# ── Static image checks (no container needed) ───────────────────
info "Image contents"
check_eq "config parses" 0 \
  "$(docker run --rm "$IMAGE" angie -t >/dev/null 2>&1; echo $?)"
check_match "shipped angie.conf is the latency-tuned one, not the packaged default" 'accept_mutex +off' \
  "$(docker run --rm "$IMAGE" cat /etc/angie/angie.conf)"
check_eq "brotli + cache-purge + zstd modules present" 5 \
  "$(docker run --rm "$IMAGE" sh -c 'ls /usr/lib/angie/modules | grep -Ec "brotli|zstd|cache_purge"')"
check_eq "no *-debug.so modules shipped" 0 \
  "$(docker run --rm "$IMAGE" sh -c 'find /usr/lib/angie/modules -name "*-debug.so" | wc -l')"
check_eq "no /usr/sbin/angie-debug binary shipped" "" \
  "$(docker run --rm "$IMAGE" sh -c '[ -e /usr/sbin/angie-debug ] && echo present')"
check_eq "no setuid/setgid binaries anywhere in the image" "" \
  "$(docker run --rm "$IMAGE" find / -xdev -type f -perm /6000 2>/dev/null)"

# ── Fixture: load the bundled modules + a vhost proxying to a real upstream ──
# The modules ship but nothing loads them by default (see the Dockerfile) —
# a consumer opts in via load_module in http.d/main.d, same as this fixture
# does. Loading them and exercising brotli/zstd/cache-purge against real
# traffic is the only way to prove they work, not just that the .so exist.
mkdir -p "$tmp/main.d" "$tmp/http.d" "$tmp/www"
cat > "$tmp/main.d/modules.conf" <<'CONF'
load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_brotli_static_module.so;
load_module modules/ngx_http_zstd_filter_module.so;
load_module modules/ngx_http_zstd_static_module.so;
load_module modules/ngx_http_cache_purge_module.so;
CONF
cat > "$tmp/http.d/fixture.conf" <<CONF
# Docker's embedded DNS (127.0.0.11) resolves \$backend at request time via
# this resolver — a literal proxy_pass hostname is instead resolved once at
# config-parse/startup time and takes the whole vhost down if that lookup
# ever fails, so the fixture uses the same variable+resolver pattern the
# image's own docker_endpoint use case requires.
resolver 127.0.0.11 valid=5s;

proxy_cache_path /var/cache/angie/test_cache levels=1:2 keys_zone=testcache:10m max_size=10m;
proxy_cache_key \$scheme\$host\$request_uri;

brotli on;
brotli_types text/plain application/octet-stream;
brotli_min_length 20;

zstd on;
zstd_types text/plain application/octet-stream;
zstd_min_length 20;

server {
    listen 80;
    server_name _;

    location / {
        set \$backend "http://$UPSTREAM:8000";
        proxy_pass \$backend;
        proxy_cache testcache;
        proxy_cache_valid 200 10m;
        add_header X-Cache-Status \$upstream_cache_status always;
    }

    location ~ ^/purge(/.*)\$ {
        proxy_cache_purge testcache \$scheme\$host\$1;
    }
}
CONF
cat > "$tmp/Dockerfile" <<DOCKERFILE
FROM $IMAGE
RUN rm -f /etc/angie/http.d/default.conf
COPY main.d/modules.conf /etc/angie/main.d/modules.conf
COPY http.d/fixture.conf /etc/angie/http.d/fixture.conf
RUN angie -t
DOCKERFILE

info "Building fixture"
docker build -q -t "$FIXTURE" "$tmp" >/dev/null

# ── Upstream: a real second container to reverse-proxy to ───────
# 1 KiB of compressible text so brotli/zstd have something worth compressing,
# and a separate file for the cache-purge sequence so it starts out uncached.
printf 'upstream ok\n' > "$tmp/www/index.html"
head -c 1024 /dev/zero | tr '\0' 'a' > "$tmp/www/big.txt"
printf 'purge me\n' > "$tmp/www/cache.txt"

docker network create "$NETWORK" >/dev/null
docker run -d --name "$UPSTREAM" --network "$NETWORK" \
  -v "$tmp/www:/www:ro" "$UPSTREAM_IMAGE" httpd -f -p 8000 -h /www >/dev/null

# ── Run ─────────────────────────────────────────────────────────
# Ephemeral host port: a fixed one collides with whatever else the machine
# (or a parallel CI job) happens to be running.
start() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" --network "$NETWORK" "$@" \
    -p 127.0.0.1::80 "$FIXTURE" >/dev/null
  base="http://$(docker port "$CONTAINER" 80/tcp | head -1)"
  for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" = healthy ] && break
    sleep 1
  done
}

# The image ships no ps/pgrep (Debian slim, --no-install-recommends), so
# process identity is read straight out of /proc.
proc_count() { # cmdline-prefix -> number of matching processes
  docker exec "$CONTAINER" sh -c '
    pat="$1"; count=0
    for p in /proc/[0-9]*; do
      cmd=$(tr "\0" " " < "$p/cmdline" 2>/dev/null)
      case "$cmd" in
        "$pat"*) count=$((count + 1)) ;;
      esac
    done
    echo "$count"
  ' _ "$1"
}
proc_user() { # cmdline-prefix -> owning username of the first match
  docker exec "$CONTAINER" sh -c '
    pat="$1"
    for p in /proc/[0-9]*; do
      cmd=$(tr "\0" " " < "$p/cmdline" 2>/dev/null)
      case "$cmd" in
        "$pat"*)
          uid=$(awk "/^Uid:/{print \$2}" "$p/status" 2>/dev/null)
          getent passwd "$uid" | cut -d: -f1
          exit 0
          ;;
      esac
    done
  ' _ "$1"
}

get() { local url="$1"; shift; curl -sS -i --max-time 5 "$@" "$url"; }
status() { curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }
header() { get "$1" "${@:3}" | tr -d '\r' | awk -v h="$2" 'BEGIN{IGNORECASE=1} $0 ~ "^"h":" {sub("^[^:]*: *",""); print}'; }

start
info "Container health"
check_eq "healthcheck reports healthy with no docker.sock mounted (plain reverse-proxy duty)" healthy \
  "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")"

info "Reverse-proxy round trip"
check_eq "/big.txt proxies through to the upstream container" 200 "$(status "$base/big.txt")"
check_match "response body is the upstream's, not angie's own" '^a{100,}$' "$(curl -sS --max-time 5 "$base/big.txt")"

info "Compression"
check_match "brotli compresses a response for Accept-Encoding: br" '^br$' \
  "$(header "$base/big.txt" Content-Encoding -H 'Accept-Encoding: br')"
check_match "zstd compresses a response for Accept-Encoding: zstd" '^zstd$' \
  "$(header "$base/big.txt" Content-Encoding -H 'Accept-Encoding: zstd')"

info "cache-purge module"
check_match "first request for a fresh URL is a cache MISS" '^MISS$' "$(header "$base/cache.txt" X-Cache-Status)"
check_match "second request is a cache HIT" '^HIT$' "$(header "$base/cache.txt" X-Cache-Status)"
check_eq "PURGE via the module's purge location succeeds" 200 "$(status "$base/purge/cache.txt")"
check_match "request after purge is a cache MISS again" '^MISS$' "$(header "$base/cache.txt" X-Cache-Status)"

info "Access log"
logs=""
for _ in $(seq 1 12); do
  logs="$(docker logs "$CONTAINER" 2>&1 | tail -40)"
  printf '%s' "$logs" | grep -q 'GET /' && break
  sleep 1
done
check_match "access log reached stdout" 'GET /' "$logs"

info "ANGIE_WORKER_PROCESSES"
start -e ANGIE_WORKER_PROCESSES=2
check_eq "ANGIE_WORKER_PROCESSES=2 spawns exactly 2 workers" 2 "$(proc_count 'angie: worker process')"

info "Docker socket group alignment"
# A plain file standing in for /var/run/docker.sock, owned by an arbitrary
# GID: the entrypoint only stats it for a GID and never speaks Docker's API
# itself (that's the healthcheck's job), so this is enough to exercise the
# renumber/create/join logic deterministically.
SOCK_GID=59872
: > "$tmp/fake.sock"
docker run --rm -v "$tmp:/data" "$UPSTREAM_IMAGE" chown "0:$SOCK_GID" /data/fake.sock >/dev/null
# ANGIE_SOCKET_CHECK=false: a plain file isn't a real listening socket, so the
# healthcheck's own probe of it would fail — irrelevant here, this run is
# only exercising the entrypoint's GID-alignment logic, not that probe.
start -e ANGIE_SOCKET_CHECK=false -v "$tmp/fake.sock:/var/run/docker.sock"
check_eq "still starts healthy with a socket mounted" healthy \
  "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")"
check_match "docker group is renumbered to the socket's GID" ":$SOCK_GID:angie\$" \
  "$(docker exec "$CONTAINER" getent group docker)"
check_match "angie user joins the renumbered group" "$SOCK_GID\\(docker\\)" \
  "$(docker exec "$CONTAINER" id angie)"

info "ANGIE_DROP_MASTER=true"
start -e ANGIE_DROP_MASTER=true
check_eq "container is healthy with a non-root master" healthy \
  "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")"
check_eq "master process runs as angie, not root" angie "$(proc_user 'angie: master process')"
check_eq "still serves traffic" 200 "$(status "$base/big.txt")"

# ── Result ──────────────────────────────────────────────────────
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
