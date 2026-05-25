# angie — reverse proxy with Docker-socket service discovery

Tiny Alpine-based [Angie](https://angie.software/) image purpose-built
as the **public-facing reverse proxy / TLS terminator** in front of
other containers on a docker host. Brotli + cache-purge + zstd dynamic
modules are bundled, and an entrypoint aligns the worker user with the
mounted `/var/run/docker.sock` group so Angie's `docker_endpoint`
upstream resolver can talk to the daemon for service discovery.

`FROM` it, mount your `angie.conf` (+ certs), done.

## Tags

| Tag      | Description                       |
|----------|-----------------------------------|
| `latest` | Latest build from `main`.         |

Multi-arch: `linux/amd64`, `linux/arm64`. SBOM and max-mode build
provenance attached to every image. Images are signed with Cosign
(keyless, OIDC-bound to this repo) — verify with:

```
cosign verify vdementev/angie:latest \
  --certificate-identity-regexp '^https://github\.com/vdementev/angie/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Quick start

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

The entrypoint reads the GID of `/var/run/docker.sock` and joins the
`angie` worker user to that group on every start — so Angie keeps
working when the host's `docker` group GID differs from the image's
default (which it usually does).

## What's inside

- **Alpine edge** + **Angie** (from the official `download.angie.software` apk repo).
- **brotli** dynamic module (`angie-module-brotli`).
- **cache-purge** dynamic module (`angie-module-cache-purge`).
- **zstd** dynamic module (`angie-module-zstd`).
- `ca-certificates` + `tzdata` (Angie proxies upstream over HTTPS and
  resolves names; operators expect local-time logs).
- `su-exec` for optional master-process privilege drop.

## Default behaviour

- **`:80`**, **`:443/tcp`**, **`:443/udp`** exposed (publish what you need).
- **Master runs as root** by default — workers drop privilege via the
  `user angie;` directive in your config. This matches stock nginx and
  avoids `/dev/stderr` permission failures on rootless / restrictive
  seccomp hosts. Set `ANGIE_DROP_MASTER=true` to `su-exec` the entire
  master if your environment supports it.
- **`STOPSIGNAL SIGQUIT`** for clean worker drain on `docker stop`.
- Logs symlinked to `/dev/stdout` / `/dev/stderr` so `docker logs`
  works without extra wiring.
- Cache + run dirs under `/var/cache/angie/*` and `/var/run/angie`,
  owned by `angie:angie`.

## Environment

| Variable             | Default                  | Purpose                                                                                                 |
|----------------------|--------------------------|---------------------------------------------------------------------------------------------------------|
| `FILE_FOR_GROUP`     | `/var/run/docker.sock`   | File whose GID is mirrored into the worker user's groups.                                               |
| `DOCKER_GROUP_NAME`  | `docker`                 | Name of the group created / renumbered to match that GID when no existing group already maps to it.     |
| `ANGIE_USER`         | `angie`                  | User added to the resolved group (the worker user from `angie.conf`).                                   |
| `ANGIE_DROP_MASTER`  | _(unset)_                | When `true`, runs the master process as `ANGIE_USER` via `su-exec` instead of root.                     |

## Security note

The entrypoint refuses to add the worker user to GID 0 — a root-owned
`docker.sock` is a misconfiguration and joining root group would defeat
privilege separation. Use docker rootless, or ensure your socket has a
non-root group, if you hit that warning.

## Source

[github.com/vdementev/angie](https://github.com/vdementev/angie) · MIT license
