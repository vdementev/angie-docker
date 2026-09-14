#!/bin/sh
# Aligns the worker user with the host's docker.sock group so Angie's
# docker_endpoint upstream resolver can talk to the Docker daemon for
# service discovery. Idempotent: safe to run on every container start,
# whether or not the socket is mounted.
set -eu

SOCKET="${FILE_FOR_GROUP:-/var/run/docker.sock}"
TARGET_GROUP="${DOCKER_GROUP_NAME:-docker}"
USER_NAME="${ANGIE_USER:-angie}"

warn() { printf '[entrypoint] %s\n' "$*" >&2; }

# Does the socket still accept a connection? curl exits 7 on a refused
# connect and 28 on a timeout; every other code means we got in and only
# the HTTP conversation went sideways, which is proof enough of life for a
# socket that may not be Docker's.
socket_alive() {
  rc=0
  curl -s -o /dev/null --max-time "${ANGIE_SOCKET_TIMEOUT:-2}" \
       --unix-socket "$SOCKET" http://localhost/_ping 2>/dev/null || rc=$?
  case "$rc" in
    7|28) return 1 ;;
    *)    return 0 ;;
  esac
}

# ── worker_processes ────────────────────────────────────────────
# Angie's own `auto` counts host CPUs and ignores the container's CPU
# quota, so a `cpus: 2` container starts a worker per host core and they
# fight over two cores' worth of runtime. ANGIE_WORKER_PROCESSES:
#
#   auto    (default) — leave it to Angie: one worker per host CPU
#   cgroup            — derive it from this container's own CPU limit
#   <n>               — literally that many
#
# The value lands in a main-level include that the shipped angie.conf
# picks up. Mount your own angie.conf and this does nothing — you own the
# directive at that point.
WORKER_CONF=/etc/angie/main.d/worker_processes.conf

# CPUs this container may actually use: its cgroup CPU quota, capped by the
# affinity mask (`--cpuset-cpus`, which nproc honours and `auto` doesn't).
cgroup_cpus() {
  quota='' period=''
  if [ -r /sys/fs/cgroup/cpu.max ]; then                  # cgroup v2
    read -r quota period < /sys/fs/cgroup/cpu.max || true
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then   # cgroup v1
    quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo)"
    period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo)"
  fi

  online="$(nproc 2>/dev/null || echo 1)"

  # "max", "-1" and anything non-numeric all mean unlimited.
  case "$quota"  in ''|*[!0-9]*) printf '%s' "$online"; return ;; esac
  case "$period" in ''|0|*[!0-9]*) printf '%s' "$online"; return ;; esac

  cpus=$(( (quota + period / 2) / period ))   # round to nearest
  [ "$cpus" -ge 1 ] || cpus=1
  [ "$cpus" -le "$online" ] || cpus="$online"
  printf '%s' "$cpus"
}

worker_processes_value() {
  requested="${ANGIE_WORKER_PROCESSES:-auto}"
  case "$requested" in
    auto)        printf 'auto' ;;
    cgroup)      cgroup_cpus ;;
    0|''|*[!0-9]*)
      warn "ANGIE_WORKER_PROCESSES='$requested' is not a positive number, 'auto' or 'cgroup'; using auto"
      printf 'auto' ;;
    *)           printf '%s' "$requested" ;;
  esac
}

# Rewritten on every start, but only when it actually changes — an
# unconditional write would look like a config change to the watchdog.
desired="worker_processes  $(worker_processes_value);"
if [ "$(cat "$WORKER_CONF" 2>/dev/null || echo)" != "$desired" ]; then
  if ( printf '%s\n' "$desired" > "$WORKER_CONF" ) 2>/dev/null; then
    warn "$desired"
  else
    warn "could not write $WORKER_CONF (read-only /etc/angie?);" \
         "ANGIE_WORKER_PROCESSES is being ignored — in effect:" \
         "$(cat "$WORKER_CONF" 2>/dev/null || echo 'nothing, Angie will use its own default')"
  fi
fi

# ── Docker socket → group alignment ─────────────────────────────
# Only runs when the socket is actually mounted. Skipped silently
# otherwise so the image works fine for plain reverse-proxy duty
# without docker_endpoint service discovery.
if [ -e "$SOCKET" ]; then
  if ! getent passwd "$USER_NAME" >/dev/null 2>&1; then
    warn "user '$USER_NAME' not found; skipping socket group alignment"
  else
    SOCK_GID="$(stat -c %g "$SOCKET" 2>/dev/null || echo '')"

    # Guard: must be a positive integer. Root-owned sockets (GID 0) are a
    # misconfiguration — we'd be granting the worker root group, which
    # defeats the privilege separation, so refuse to touch /etc/group.
    case "$SOCK_GID" in
      ''|*[!0-9]*) warn "could not read GID of $SOCKET; skipping" ;;
      0)           warn "$SOCKET is owned by GID 0; refusing to add '$USER_NAME' to root group" ;;
      *)
        EXISTING_GROUP="$(getent group | awk -F: -v gid="$SOCK_GID" '$3==gid{print $1; exit}')"
        if [ -n "$EXISTING_GROUP" ]; then
          # GID already mapped to a known group — just join it.
          usermod -aG "$EXISTING_GROUP" "$USER_NAME" 2>/dev/null || true
        else
          # GID is unknown. Reuse TARGET_GROUP's name (renumber if needed)
          # or create it fresh at SOCK_GID, then add USER_NAME to it.
          if getent group "$TARGET_GROUP" >/dev/null 2>&1; then
            CURRENT_GID="$(getent group "$TARGET_GROUP" | awk -F: '{print $3}')"
            if [ "$CURRENT_GID" != "$SOCK_GID" ]; then
              if ! groupmod -g "$SOCK_GID" "$TARGET_GROUP" 2>/dev/null; then
                warn "failed to renumber group '$TARGET_GROUP' to GID $SOCK_GID"
              fi
            fi
          else
            if ! groupadd -g "$SOCK_GID" "$TARGET_GROUP" 2>/dev/null; then
              warn "failed to create group '$TARGET_GROUP' with GID $SOCK_GID"
            fi
          fi
          usermod -aG "$TARGET_GROUP" "$USER_NAME" 2>/dev/null || true
        fi
        ;;
    esac
  fi
fi

# ── Background watchdogs ────────────────────────────────────────
# Both are opt-in and both are skipped unless we are actually starting the
# server — `angie -t`, `angie -v`, `angie -s reload` must stay one-shot.
is_server_start() {
  case " $* " in
    *" -t "*|*" -T "*|*" -v "*|*" -V "*|*" -s "*) return 1 ;;
  esac
  return 0
}

# Stop the container when the Docker socket stops answering, so the restart
# policy re-binds a fresh socket inode. A dead socket is silent otherwise:
# discovery keeps failing every poll while the already-populated upstreams
# serve traffic, and the outage only lands at the next reload.
socket_watchdog() {
  interval="${ANGIE_SOCKET_WATCH_INTERVAL:-15}"
  threshold="${ANGIE_SOCKET_WATCH_RETRIES:-3}"
  failures=0

  while sleep "$interval"; do
    [ -e "$SOCKET" ] || continue

    if socket_alive; then
      failures=0
      continue
    fi

    failures=$((failures + 1))
    warn "docker socket unreachable ($failures/$threshold): $SOCKET"
    [ "$failures" -ge "$threshold" ] || continue

    warn "service discovery is dead — stopping so the restart policy re-binds the socket"
    kill -QUIT "$(cat /run/angie.pid 2>/dev/null || echo 1)" 2>/dev/null || kill -QUIT 1
    return
  done
}

# Fingerprint of every config file, content-based: mtimes survive an rsync -a
# deploy, contents don't.
config_fingerprint() {
  find "$1" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum
}

# Reload on config change, but only after the config parses. A failed parse is
# left running on the old config instead of taking the vhost down — a literal
# hostname in a proxy_pass whose DNS is broken exits the master at parse time
# and turns `restart: unless-stopped` into a crash loop.
config_watchdog() {
  path="${ANGIE_WATCH_CONFIG_PATH:-/etc/angie}"
  interval="${ANGIE_WATCH_CONFIG_INTERVAL:-10}"
  last="$(config_fingerprint "$path")"

  while sleep "$interval"; do
    current="$(config_fingerprint "$path")"
    [ "$current" != "$last" ] || continue
    last="$current"

    if output="$(angie -t 2>&1)"; then
      if angie -s reload 2>/dev/null; then
        warn "config changed — reloaded"
      else
        warn "config changed and parses, but reload failed"
      fi
    else
      warn "config changed but failed to parse — NOT reloading:"
      printf '%s\n' "$output" >&2
    fi
  done
}

if is_server_start "$@"; then
  if [ "${ANGIE_SOCKET_WATCH:-}" = "true" ]; then
    socket_watchdog &
  fi
  if [ "${ANGIE_WATCH_CONFIG:-}" = "true" ]; then
    config_watchdog &
  fi
fi

# ── Master process privilege ────────────────────────────────────
# By default the master runs as root and the "user" directive in
# angie.conf handles worker privilege separation — matching the
# stock nginx Docker image.
#
# Set ANGIE_DROP_MASTER=true to run the master as ANGIE_USER instead.
# Ports 80/443 still bind — Docker sets net.ipv4.ip_unprivileged_port_start=0
# inside the container — but every path Angie writes to has to belong to that
# user, and the "user" directive in angie.conf becomes a no-op (it logs a
# warning and is ignored, since a non-root master can't switch users).
if [ "${ANGIE_DROP_MASTER:-}" = "true" ] && [ "$USER_NAME" != "root" ]; then
  # Docker hands the container its stdout/stderr as root-owned 0600 pipes and
  # Angie *reopens* them by path (/var/log/angie/*.log are symlinks to
  # /dev/std*), so a non-root master dies at startup with "Permission denied"
  # before it logs anything useful. Same story for the pid and lock files it
  # creates directly in /run. Hand both to the user we're about to become —
  # while we still have the privilege to do it.
  # No `2>/dev/null` here, on purpose: the redirect would replace chown's own
  # fd 2, so /proc/self/fd/2 would resolve to /dev/null and the chown would
  # "succeed" against the wrong file. /proc/$$/fd/2 doesn't work either — the
  # magic symlinks only resolve to the open file for the process itself.
  for fd in 1 2; do
    chown "$USER_NAME" "/proc/self/fd/$fd" \
      || warn "could not chown fd $fd to '$USER_NAME'; Angie may fail to open its logs"
  done
  chown "$USER_NAME" /run 2>/dev/null \
    || warn "could not chown /run to '$USER_NAME'; Angie may fail to write its pid file"

  # The ACME store ships as root-owned 0700 and a fresh volume inherits that,
  # so the built-in ACME client can't write its account key or the issued
  # certificates.
  if [ -d /var/lib/angie/acme ]; then
    chown -R "$USER_NAME" /var/lib/angie/acme 2>/dev/null \
      || warn "could not chown /var/lib/angie/acme to '$USER_NAME'; ACME issuance will fail"
  fi

  # setpriv ships in util-linux, already in the base image — no su-exec/gosu
  # to vendor. --init-groups picks up the docker group we just joined;
  # --inh-caps and --no-new-privs make sure nothing downstream of the master
  # can gain a capability back.
  exec setpriv --reuid "$USER_NAME" --regid "$USER_NAME" --init-groups \
               --inh-caps=-all --no-new-privs -- "$@"
fi

exec "$@"
