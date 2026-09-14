# angie

Reusable [Angie](https://angie.software/) base image, designed to live
**in front of** other containers on a docker host as the public-facing
reverse proxy / TLS terminator. TLS, HTTP/2, HTTP/3 (QUIC) and
public-internet exposure all happen here; downstream services sit on a
private docker network behind it.

`FROM` it in your project's Dockerfile (or use it directly in compose),
drop your vhosts into `/etc/angie/http.d/` and mount your certs.

## What's in the image

- **Debian 13 (trixie) slim** + **Angie** (from the official
  [download.angie.software](https://download.angie.software/) apt repo).
- **brotli** dynamic module (`angie-module-brotli`).
- **cache-purge** dynamic module (`angie-module-cache-purge`).
- **zstd** dynamic module (`angie-module-zstd`).
- `ca-certificates` + `tzdata` (Angie may `proxy_pass` over HTTPS and
  resolve upstreams by name; operators expect local-time logs).
- `curl` — the healthcheck's Docker-socket probe (it speaks unix sockets)
  and its optional HTTP probe.
- `setpriv` from the base image's `util-linux` for the optional
  master-process privilege drop — no `su-exec`/`gosu` binary to vendor.

Angie's own `angie.conf` is replaced with a latency-tuned one (see below).
Everything else is Angie's packaged default, including its stock
`http.d/default.conf` welcome vhost.

### Why Debian and not Alpine

glibc, mostly. musl's allocator serializes badly across worker threads and
its stub resolver is single-shot — both show up as p99 latency on a proxy
that fans out to named upstreams. The trade is size: ~190 MB unpacked
against Alpine's ~36 MB.

## What it does at startup

The whole reason this image exists: aligning the in-container worker
user with the host's `/var/run/docker.sock` group so Angie's
`docker_endpoint` upstream resolver can talk to the Docker daemon for
service discovery — even when the host's `docker` group GID differs
from the image's default (it usually does).

On every container start the entrypoint:

1. `stat`s `$FILE_FOR_GROUP` (default `/var/run/docker.sock`) for its GID.
2. If a group with that GID already exists in `/etc/group`, joins
   `$ANGIE_USER` to it (`usermod -aG`).
3. Otherwise renumbers `$DOCKER_GROUP_NAME` to that GID (`groupmod -g`)
   or creates it (`groupadd -g`), and joins `$ANGIE_USER` to it.
4. Refuses to touch root group (GID 0) — joining it would defeat the
   worker's privilege separation.

If the socket isn't mounted, the entrypoint is a no-op — the image
works fine for plain reverse-proxy duty without service discovery.

By default the master process runs as root and the `user` directive in
`angie.conf` handles worker privilege separation — the stock nginx model.

`ANGIE_DROP_MASTER=true` `setpriv`s the entire master to `$ANGIE_USER`
instead, with `--init-groups` (so the docker group joined above survives),
`--inh-caps=-all` and `--no-new-privs`. Before it does, the entrypoint
hands that user the things Angie reopens by path and would otherwise be
denied: the container's stdout/stderr pipes (Docker creates them root-owned
`0600`, and `/var/log/angie/*.log` are symlinks to `/dev/std*`), `/run` for
the pid and lock files, and the ACME store at `/var/lib/angie/acme`. Ports
80/443 still bind — Docker sets `net.ipv4.ip_unprivileged_port_start=0`
inside the container. The `user` directive in your config becomes a no-op
and logs a warning: a non-root master cannot switch users, so drop it from
`angie.conf` when you use this.

## Latency tuning

The shipped `/etc/angie/angie.conf` is Angie's packaged file with
main- and http-level tuning applied. No vhost of our own, so your
`http.d/*.conf` is still the source of truth — and mounting your own
`angie.conf` replaces all of it.

| Setting | Why |
|---|---|
| `pcre_jit on` | Location/map/rewrite regexes compile once at startup instead of being interpreted per request. |
| `accept_mutex off` | Workers accept the moment the kernel wakes them; no mutex hand-off in the accept path. |
| `worker_shutdown_timeout 30s` | A reload can't leave old workers (and their memory) pinned by one hung upstream. |
| `aio threads` | A cold page cache — including `proxy_cache` hits — blocks a thread, not the whole worker. |
| `access_log … buffer=32k flush=5s` | One `write()` per 32k of log instead of one per request. Logs stay ≤5s behind. |
| `tcp_nopush` + `tcp_nodelay` + `sendfile` | Full frames while the body streams, no Nagle delay on the last one. |
| `open_file_cache` | Serves a static file without a `stat()`/`open()` per request. Negative lookups stay uncached, so a file that appears mid-deploy is visible immediately. |
| `proxy_http_version 1.1` + empty `Connection` | What makes `keepalive N;` in an upstream block actually reuse sockets, so a proxied request skips the TCP (and TLS) handshake. |
| `proxy_connect_timeout 5s` | A dead upstream fails fast instead of holding the client for 60s. |
| `keepalive_requests 1000` | Client connections survive a page's worth of requests. |
| `gzip on`, `comp_level 5` | The knee of the ratio/CPU curve. |
| TLS 1.2 + 1.3 only, AES-GCM first, `ssl_session_cache shared:SSL:10m` | 1-RTT handshakes, resumption for the rest, AES-NI-friendly cipher order. |
| `ssl_buffer_size 4k` | First byte reaches the client without waiting for a 16k record to fill. Costs a little peak throughput. |

`listen … reuseport` and `http2 on` / `listen 443 quic` are per-server
directives, so they stay yours — put them in your own vhost.

### worker_processes

Angie's `auto` counts *host* CPUs and knows nothing about the container's
cgroup quota, so a `cpus: 2` container on a 16-core host starts 16 workers
to fight over two cores' worth of runtime. `ANGIE_WORKER_PROCESSES` picks
the value instead:

| Value | Result |
|---|---|
| `auto` (default) | Angie's own `auto` — one worker per host CPU. Unchanged behaviour. |
| `cgroup` | Derived from this container's CPU limit: the cgroup (v2 or v1) quota rounded to the nearest whole CPU, capped by the affinity mask so `--cpuset-cpus` counts too. Unlimited falls back to `nproc`. |
| `<n>` | Literally that many. |

```yaml
services:
  angie:
    image: dementev/angie:latest
    cpus: 2
    environment:
      ANGIE_WORKER_PROCESSES: cgroup   # -> worker_processes 2;
```

Anything that isn't `auto`, `cgroup` or a positive integer warns and falls
back to `auto`.

The entrypoint writes the directive to
`/etc/angie/main.d/worker_processes.conf` on every start (only when the
value actually changes, so the config watchdog doesn't see it as a deploy),
and the shipped `angie.conf` pulls it in with
`include /etc/angie/main.d/*.conf;`. Two consequences:

- **Mount your own `angie.conf` and the variable does nothing** — you own
  the directive at that point.
- `main.d/` is a general main-level drop-in dir, which is where the
  `load_module` lines for the bundled modules can live now instead of
  forcing you to replace `angie.conf` wholesale.

If `/etc/angie` is mounted read-only the write fails, the entrypoint says
so loudly, and the baked `worker_processes auto;` stays in effect.

## Hardening

- Repo trust anchor is fetched into `/usr/share/keyrings/angie.gpg` and
  pinned by SHA-256 (`ANGIE_SIGNING_SHA256` build arg), referenced from a
  deb822 `Signed-By:` source. A swapped upstream key fails the build
  instead of signing whatever it likes.
- Every setuid/setgid bit Debian ships (`su`, `mount`, `passwd`, `chsh`,
  `newgrp`, `unix_chkpwd`, …) is stripped — nothing in this image needs to
  escalate. `groupadd`/`groupmod`/`usermod`, which the entrypoint does use,
  are plain root-only binaries.
- `apt-get upgrade` at build time plus `--no-install-recommends`, purged
  apt lists, and no `-debug` binaries or modules (`/usr/sbin/angie` is a
  symlink to `angie-nodebug`).
- No sysv/systemd/logrotate wiring: one foreground master, logs to stdout.
- `server_tokens off`, TLS ≤1.1 refused, slowloris timeouts on the client
  side (`client_header_timeout` / `client_body_timeout` 15s).
- `ANGIE_DROP_MASTER=true` drops all inheritable capabilities and sets
  `no_new_privs` on the master.

## Environment

| Variable             | Default                  | Purpose                                                                  |
|----------------------|--------------------------|--------------------------------------------------------------------------|
| `FILE_FOR_GROUP`     | `/var/run/docker.sock`   | File whose GID is mirrored into the worker user's groups.                |
| `DOCKER_GROUP_NAME`  | `docker`                 | Name of the group to renumber / create when no existing GID match.       |
| `ANGIE_USER`         | `angie`                  | User added to the resolved group.                                        |
| `ANGIE_DROP_MASTER`  | _(unset)_                | When `true`, runs the master as `ANGIE_USER` via `setpriv` instead of root. |
| `ANGIE_WORKER_PROCESSES` | `auto`               | `auto`, `cgroup` (derive from the container's CPU limit), or a worker count. |

### Healthcheck

| Variable                    | Default     | Purpose                                                              |
|-----------------------------|-------------|----------------------------------------------------------------------|
| `ANGIE_SOCKET_CHECK`        | `true`      | Probe `$FILE_FOR_GROUP` when it's mounted. Set `false` to skip.      |
| `ANGIE_SOCKET_TIMEOUT`      | `2`         | Seconds for that socket probe (also used by the socket watchdog).    |
| `ANGIE_HEALTHCHECK_URL`     | _(unset)_   | When set, also HTTP-probe this URL (e.g. `http://127.0.0.1/ping`).   |
| `ANGIE_HEALTHCHECK_TIMEOUT` | `2`         | Seconds for that HTTP probe.                                         |

### Watchdogs

| Variable                      | Default      | Purpose                                                                 |
|-------------------------------|--------------|--------------------------------------------------------------------------|
| `ANGIE_SOCKET_WATCH`          | _(unset)_    | When `true`, stop the container once the Docker socket stops answering. |
| `ANGIE_SOCKET_WATCH_INTERVAL` | `15`         | Seconds between socket probes.                                          |
| `ANGIE_SOCKET_WATCH_RETRIES`  | `3`          | Consecutive failures before stopping.                                   |
| `ANGIE_WATCH_CONFIG`          | _(unset)_    | When `true`, test + reload on config change.                            |
| `ANGIE_WATCH_CONFIG_PATH`     | `/etc/angie` | Tree that's watched (hashed by content, not mtime).                     |
| `ANGIE_WATCH_CONFIG_INTERVAL` | `10`         | Seconds between change checks.                                          |

## Healthcheck

`HEALTHCHECK` is built in and checks two things:

1. the master process is alive (`/run/angie.pid`);
2. when `$FILE_FOR_GROUP` is mounted, that the socket still **accepts a
   connection**.

The second one is the one that matters. When dockerd restarts it recreates
`/var/run/docker.sock`; a container that bind-mounts the socket as a single
file keeps the old, dead inode. Angie keeps serving from the upstreams it
discovered earlier, so an HTTP ping stays green — the failure only surfaces
at the next config reload, which wipes the discovered upstreams that
discovery can no longer repopulate, and every request 502s at once. This
healthcheck goes red while the site is still up.

The probe is `curl --unix-socket … /_ping`. Only curl's "couldn't connect"
(7) and "timed out" (28) count as dead; any other exit means the listener
accepted us and merely didn't speak Docker's API, so pointing
`FILE_FOR_GROUP` at some other unix socket still works.

Set `ANGIE_HEALTHCHECK_URL` to add an HTTP probe of one of your own
locations; the image ships no opinionated vhost, so there's no sane default.
A `healthcheck:` in your compose file overrides all of this, as usual.

Mounting `/var/run` as a directory instead of the socket file avoids the
stale-inode problem altogether — the socket is then reopened by path on
every connect.

## Watchdogs

Both are off by default, both run as root alongside the master, and neither
starts for one-shot commands (`angie -t`, `-v`, `-s reload`).

**`ANGIE_SOCKET_WATCH=true`** — probes the socket every
`ANGIE_SOCKET_WATCH_INTERVAL` seconds and, after `ANGIE_SOCKET_WATCH_RETRIES`
consecutive failures, sends `SIGQUIT` to the master so the container exits
gracefully and the restart policy re-binds a live socket. Angie exits 0 on a
graceful shutdown, so this needs `restart: always` or `unless-stopped` —
`on-failure` will not restart it.

**`ANGIE_WATCH_CONFIG=true`** — hashes `ANGIE_WATCH_CONFIG_PATH` every
`ANGIE_WATCH_CONFIG_INTERVAL` seconds and on any change runs `angie -t`
first: it reloads only if the config parses, and otherwise logs the parse
error and keeps serving the running config. That turns a config deploy into
a graceful reload instead of a container recreate (which re-issues ACME certs
and drops discovered upstreams), and it contains the classic crash loop where
a literal hostname in `proxy_pass` fails to resolve at parse time and the
master refuses to start.

Contents are hashed, not mtimes — an `rsync -a` deploy preserves mtimes.

## Usage

```yaml
services:
  angie:
    image: dementev/angie:latest
    ports: ["80:80", "443:443", "443:443/udp"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./http.d:/etc/angie/http.d:ro
      - ./certs:/etc/angie/certs:ro
```

Drop your vhosts into `/etc/angie/http.d/*.conf` and you keep the tuned
`angie.conf` above. `load_module` is main-level, so the bundled modules go
into `/etc/angie/main.d/*.conf` instead:

```nginx
load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_brotli_static_module.so;
load_module modules/ngx_http_zstd_filter_module.so;
load_module modules/ngx_http_cache_purge_module.so;
```

Mount your own `/etc/angie/angie.conf` if you'd rather own the whole thing —
you then own `worker_processes` and the `load_module` lines too.

## Ports

| Port      | Use                                |
|-----------|------------------------------------|
| `80/tcp`  | HTTP                               |
| `443/tcp` | HTTPS (HTTP/2 over TLS)            |
| `443/udp` | HTTP/3 (QUIC)                      |

`EXPOSE` is declarative — publish only what you actually use.

## Signals

- `STOPSIGNAL SIGQUIT` — `docker stop` triggers a graceful Angie
  shutdown (workers drain before exiting).

## CI

`.github/workflows/ci.yml` is a thin caller of the shared reusable
workflow in [`vdementev/docker-workflows`](https://github.com/vdementev/docker-workflows)
(pinned `@v1`):

1. Pull requests build `linux/amd64` and run the **Trivy** gate (fails on
   fixable CRITICAL/HIGH; `.trivyignore` at the repo root for accepted risks)
   without publishing.
2. Merging to `main` publishes the multi-arch manifest (`linux/amd64`,
   `linux/arm64`) to Docker Hub as `dementev/angie:latest` with **SBOM** and
   max-mode **provenance**, signs the digest with **Cosign** (keyless,
   OIDC-bound to this repo), and syncs `DOCKERHUB.md` to the Docker Hub
   description.

`main` is branch-protected: everything goes through a PR with the build
check green. A weekly cron republishes to pick up package-level updates,
and Renovate auto-merges base-image digest/patch bumps once CI is green.

## Versioning

Tracks whatever Angie the trixie repo currently serves — unpinned, so the
weekly rebuild picks up new releases. Pin a specific version in a downstream
Dockerfile with `apt-get install angie=<version>` if you need to.

The apt repo URL follows the base image: `VERSION_ID` and `VERSION_CODENAME`
from `/etc/os-release` build it at image-build time, so a base bump to the
next Debian release needs no Dockerfile edit beyond the `FROM`.
