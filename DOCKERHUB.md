# angie — reverse proxy with Docker-socket service discovery

Debian-slim [Angie](https://angie.software/) image purpose-built as the
**public-facing reverse proxy / TLS terminator** in front of other
containers on a docker host. Brotli + cache-purge + zstd dynamic modules
are bundled, `angie.conf` ships latency-tuned, and an entrypoint aligns
the worker user with the mounted `/var/run/docker.sock` group so Angie's
`docker_endpoint` upstream resolver can talk to the daemon for service
discovery.

`FROM` it, drop a vhost into `/etc/angie/http.d/`, mount your certs, done.

## Tags

| Tag      | Description                       |
|----------|-----------------------------------|
| `latest` | Latest build from `main`.         |

Multi-arch: `linux/amd64`, `linux/arm64`. SBOM and max-mode build
provenance attached to every image. Images are signed with Cosign
(keyless, OIDC-bound to this repo) — verify with:

```
cosign verify dementev/angie:latest \
  --certificate-identity-regexp '^https://github\.com/vdementev/angie/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Quick start

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

The entrypoint reads the GID of `/var/run/docker.sock` and joins the
`angie` worker user to that group on every start — so Angie keeps
working when the host's `docker` group GID differs from the image's
default (which it usually does).

Mount your own `/etc/angie/angie.conf` instead of using `http.d/` if you
want full control. You'll need to anyway for the bundled dynamic modules,
since `load_module` is main-level:

```nginx
load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_zstd_filter_module.so;
load_module modules/ngx_http_cache_purge_module.so;
```

## What's inside

- **Debian 13 (trixie) slim** + **Angie** (from the official `download.angie.software` apt repo).
- **brotli** dynamic module (`angie-module-brotli`).
- **cache-purge** dynamic module (`angie-module-cache-purge`).
- **zstd** dynamic module (`angie-module-zstd`).
- `ca-certificates` + `tzdata` (Angie proxies upstream over HTTPS and
  resolves names; operators expect local-time logs).
- `curl` for the healthcheck's Docker-socket and HTTP probes.
- `setpriv` (base `util-linux`) for the optional master privilege drop.

glibc rather than musl is the point of the Debian base: musl's allocator
serializes across worker threads and its resolver is single-shot, both of
which show up as p99 latency on a proxy fanning out to named upstreams.

## Latency tuning

The shipped `angie.conf` carries main- and http-level tuning — `pcre_jit`,
`accept_mutex off`, `aio threads`, buffered access log, `open_file_cache`,
upstream keepalive (`proxy_http_version 1.1` + empty `Connection`),
`proxy_connect_timeout 5s`, gzip at level 5, TLS 1.2/1.3 with AES-GCM
first, a shared session cache and `ssl_buffer_size 4k`. No vhost of our
own, so your `http.d/*.conf` still decides everything user-visible.

One knob it deliberately leaves alone: `worker_processes auto` counts
*host* CPUs, not your cgroup quota. Set it explicitly whenever you cap CPU.

## Hardening

- Angie's apt trust anchor is pinned by SHA-256 and referenced through a
  deb822 `Signed-By:` keyring — a swapped upstream key fails the build.
- Every setuid/setgid bit Debian ships is stripped.
- `--no-install-recommends`, `apt-get upgrade` at build, purged apt lists,
  no `-debug` binaries or modules, no sysv/systemd/logrotate wiring.
- `server_tokens off`, TLS ≤1.1 refused, slowloris client timeouts.
- `ANGIE_DROP_MASTER=true` drops all inheritable capabilities and sets
  `no_new_privs`.

## Default behaviour

- **`:80`**, **`:443/tcp`**, **`:443/udp`** exposed (publish what you need).
- **Master runs as root** by default — workers drop privilege via the
  `user angie;` directive in your config, the stock nginx model.
  `ANGIE_DROP_MASTER=true` runs the whole master as `ANGIE_USER` instead;
  the entrypoint first hands that user the container's stdout/stderr pipes,
  `/run` and the ACME store, which Angie reopens by path and Docker leaves
  root-owned. Drop the `user` directive from your config when you use it —
  a non-root master ignores it and warns.
- **`STOPSIGNAL SIGQUIT`** for clean worker drain on `docker stop`.
- **`HEALTHCHECK`** verifies the master is alive *and*, when the socket is
  mounted, that it still accepts connections — a dockerd restart leaves the
  bind-mounted socket file pointing at a dead inode, which stays invisible
  until the next reload wipes the discovered upstreams and everything 502s.
  Set `ANGIE_HEALTHCHECK_URL` to add an HTTP probe of your own vhost.
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
| `ANGIE_DROP_MASTER`  | _(unset)_                | When `true`, runs the master process as `ANGIE_USER` via `setpriv` instead of root.                     |
| `ANGIE_SOCKET_CHECK`      | `true`       | Healthcheck probes the mounted socket. `false` skips it.                                           |
| `ANGIE_HEALTHCHECK_URL`   | _(unset)_    | Extra HTTP probe for the healthcheck, e.g. `http://127.0.0.1/ping`.                                |
| `ANGIE_SOCKET_WATCH`      | _(unset)_    | `true` stops the container when the socket dies, so the restart policy re-binds it (needs `restart: always`/`unless-stopped`). |
| `ANGIE_WATCH_CONFIG`      | _(unset)_    | `true` watches `/etc/angie` and reloads on change — but only after `angie -t` passes, so a broken config never takes the vhost down. |

## Security note

The entrypoint refuses to add the worker user to GID 0 — a root-owned
`docker.sock` is a misconfiguration and joining root group would defeat
privilege separation. Use docker rootless, or ensure your socket has a
non-root group, if you hit that warning.

## Source

[github.com/vdementev/angie](https://github.com/vdementev/angie) · MIT license
