# angie

Reusable [Angie](https://angie.software/) base image, designed to live
**in front of** other containers on a docker host as the public-facing
reverse proxy / TLS terminator. TLS, HTTP/2, HTTP/3 (QUIC) and
public-internet exposure all happen here; downstream services sit on a
private docker network behind it.

`FROM` it in your project's Dockerfile (or use it directly in compose)
and mount your `angie.conf` plus certs.

## What's in the image

- **Alpine edge** + **Angie** (from the official
  [download.angie.software](https://download.angie.software/) apk repo).
- **brotli** dynamic module (`angie-module-brotli`).
- **cache-purge** dynamic module (`angie-module-cache-purge`).
- **zstd** dynamic module (`angie-module-zstd`).
- `ca-certificates` + `tzdata` (Angie may `proxy_pass` over HTTPS and
  resolve upstreams by name; operators expect local-time logs).
- `su-exec` for optional master-process privilege drop.
- `socat` — the healthcheck's Docker-socket probe (busybox `nc`/`wget`
  can't speak to a unix socket).

## What it does at startup

The whole reason this image exists: aligning the in-container worker
user with the host's `/var/run/docker.sock` group so Angie's
`docker_endpoint` upstream resolver can talk to the Docker daemon for
service discovery — even when the host's `docker` group GID differs
from the image's default (it usually does).

On every container start the entrypoint:

1. `stat`s `$FILE_FOR_GROUP` (default `/var/run/docker.sock`) for its GID.
2. If a group with that GID already exists in `/etc/group`, joins
   `$ANGIE_USER` to it.
3. Otherwise renumbers `$DOCKER_GROUP_NAME` to that GID (or creates it)
   and joins `$ANGIE_USER` to it.
4. Refuses to touch root group (GID 0) — joining it would defeat the
   worker's privilege separation.

If the socket isn't mounted, the entrypoint is a no-op — the image
works fine for plain reverse-proxy duty without service discovery.

By default the master process runs as root and the `user` directive in
`angie.conf` handles worker privilege separation (matches stock nginx,
avoids `/dev/stderr` permission failures on rootless / restrictive
seccomp hosts). Set `ANGIE_DROP_MASTER=true` to `su-exec` the entire
master to `$ANGIE_USER`.

## Environment

| Variable             | Default                  | Purpose                                                                  |
|----------------------|--------------------------|--------------------------------------------------------------------------|
| `FILE_FOR_GROUP`     | `/var/run/docker.sock`   | File whose GID is mirrored into the worker user's groups.                |
| `DOCKER_GROUP_NAME`  | `docker`                 | Name of the group to renumber / create when no existing GID match.       |
| `ANGIE_USER`         | `angie`                  | User added to the resolved group.                                        |
| `ANGIE_DROP_MASTER`  | _(unset)_                | When `true`, runs the master as `ANGIE_USER` via `su-exec` instead of root. |

### Healthcheck

| Variable                    | Default     | Purpose                                                              |
|-----------------------------|-------------|----------------------------------------------------------------------|
| `ANGIE_SOCKET_CHECK`        | `true`      | Probe `$FILE_FOR_GROUP` when it's mounted. Set `false` to skip.      |
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
    image: vdementev/angie:latest
    ports: ["80:80", "443:443", "443:443/udp"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./angie.conf:/etc/angie/angie.conf:ro
      - ./conf.d:/etc/angie/conf.d:ro
      - ./certs:/etc/angie/certs:ro
```

The image ships only Angie's apk defaults — no opinionated vhost — so
your `angie.conf` / `conf.d/*.conf` is the source of truth.

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

`.github/workflows/docker-build-push.yml` runs on every push to `main`:

1. Builds `linux/amd64` locally and scans it with **Trivy** (fails on
   HIGH/CRITICAL OS or library CVEs).
2. Builds + pushes a multi-arch manifest (`linux/amd64`, `linux/arm64`)
   to Docker Hub as `${DOCKERHUB_USERNAME}/angie:latest` with **SBOM**
   and **max-mode provenance**.
3. Signs the pushed digest with **Cosign** (keyless, OIDC-bound to this repo).
4. Syncs `DOCKERHUB.md` to the Docker Hub repository description.

## Versioning

Tracks Alpine edge's Angie package. To pin a specific upstream Angie
version, override the apk install in a downstream Dockerfile.
