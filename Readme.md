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


bump
