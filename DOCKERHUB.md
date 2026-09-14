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

| Tag | Contents |
|---|---|
| `latest` | The newest build — every merge to `main`, plus a weekly rebuild for package updates. |
| `1.12.1` | The exact Angie version inside the image. |
| `1.12` | The newest patch of that Angie minor. |

Version tags are read out of the image *after* it is built and tested, so a tag
can never claim a version the image does not run.

Multi-arch: `linux/amd64`, `linux/arm64`. SBOM, max-mode build provenance and a
keyless Cosign signature on every published digest.

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

`load_module` is main-level, so the bundled dynamic modules go into
`/etc/angie/main.d/*.conf` (mount your own `angie.conf` instead if you want
to own the whole file):

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

`worker_processes` comes from **`ANGIE_WORKER_PROCESSES`**: `auto`
(default, Angie's own — one worker per host CPU), `cgroup` (derived from
this container's CPU limit, so `cpus: 2` gets 2 workers instead of one per
host core), or a literal count. The entrypoint writes it to
`/etc/angie/main.d/worker_processes.conf`, which the shipped `angie.conf`
includes — mount your own `angie.conf` and you own the directive instead.

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
| `ANGIE_WORKER_PROCESSES` | `auto`               | `auto`, `cgroup` (derive from the container's CPU limit), or a literal worker count.                |
| `ANGIE_SOCKET_CHECK`      | `true`       | Healthcheck probes the mounted socket. `false` skips it.                                           |
| `ANGIE_HEALTHCHECK_URL`   | _(unset)_    | Extra HTTP probe for the healthcheck, e.g. `http://127.0.0.1/ping`.                                |
| `ANGIE_SOCKET_WATCH`      | _(unset)_    | `true` stops the container when the socket dies, so the restart policy re-binds it (needs `restart: always`/`unless-stopped`). |
| `ANGIE_WATCH_CONFIG`      | _(unset)_    | `true` watches `/etc/angie` and reloads on change — but only after `angie -t` passes, so a broken config never takes the vhost down. |

## The docker.sock group

The entrypoint refuses to add the worker user to GID 0 — a root-owned
`docker.sock` is a misconfiguration and joining root group would defeat
privilege separation. Use docker rootless, or ensure your socket has a
non-root group, if you hit that warning.

## Security and provenance

Every published digest is built by the shared pipeline in
[vdementev/docker-workflows](https://github.com/vdementev/docker-workflows).
Pull requests build, test and scan without publishing; `main` is
branch-protected, so nothing reaches Docker Hub without a green check behind it.
A Trivy gate fails the build on any *fixable* CRITICAL or HIGH finding, and each
published digest carries an SBOM, max-mode SLSA provenance and a keyless Cosign
signature.

Verify what you pulled:

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp 'github.com/vdementev/' \
  dementev/angie:latest
```

[SECURITY.md](https://github.com/vdementev/angie-docker/blob/main/SECURITY.md) is the reporting channel and the response
targets; [SUPPORT.md](https://github.com/vdementev/angie-docker/blob/main/SUPPORT.md) covers tag lifecycle, pinning and
patch cadence.

## Related images

One family, built by the same pipeline, meant to run together — a proxy in
front, an app runtime, a database, and a way into it.

| Image | What it does |
|---|---|
| **[`dementev/angie`](https://hub.docker.com/r/dementev/angie)** — this image | Public-facing reverse proxy and TLS terminator — Angie, the nginx fork, with brotli, zstd and cache-purge |
| [`dementev/nginx`](https://hub.docker.com/r/dementev/nginx) — [source](https://github.com/vdementev/nginx-docker) | Static sites and SPAs behind that proxy — brotli/zstd siblings, Prometheus stub_status |
| [`dementev/php-fpm-with-ext`](https://hub.docker.com/r/dementev/php-fpm-with-ext) — [source](https://github.com/vdementev/docker-php-fpm-with-ext) | PHP-FPM and CLI, PHP 7.0 → 8.5, with the extensions most projects reach for |
| [`dementev/mysql-percona`](https://hub.docker.com/r/dementev/mysql-percona) — [source](https://github.com/vdementev/mysql-percona-docker) | Percona Server for MySQL 8.4 LTS, XtraBackup built in, no root inside |
| [`dementev/adminer`](https://hub.docker.com/r/dementev/adminer) — [source](https://github.com/vdementev/adminer-docker) | Adminer 6 with every driver it supports, for reaching any of the above |

## Maintainer

Built and maintained by [Vasilii Dementev](https://vasiliidementev.com) at
[Lotus Web Agency](https://lotuswebagency.com). These images are not a side
project — they are the base layer under the client and product systems we run,
which is why they are gated, tested and signed rather than pushed by hand.

Issues and pull requests:
[github.com/vdementev/angie-docker](https://github.com/vdementev/angie-docker).
Need this kind of infrastructure built or maintained for your own stack?
[lotuswebagency.com](https://lotuswebagency.com).

Packaging in this repository is MIT licensed — see
[LICENSE](https://github.com/vdementev/angie-docker/blob/main/LICENSE). The software
inside the image keeps its own upstream licenses.
