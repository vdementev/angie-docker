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
          addgroup "$USER_NAME" "$EXISTING_GROUP" 2>/dev/null || true
        else
          # GID is unknown. Reuse TARGET_GROUP's name (renumber if needed)
          # or create it fresh at SOCK_GID, then add USER_NAME to it.
          if getent group "$TARGET_GROUP" >/dev/null 2>&1; then
            CURRENT_GID="$(getent group "$TARGET_GROUP" | awk -F: '{print $3}')"
            if [ "$CURRENT_GID" != "$SOCK_GID" ]; then
              if ! sed -i -E "s/^(${TARGET_GROUP}:[^:]*:)[0-9]+:/\1${SOCK_GID}:/" /etc/group; then
                warn "failed to renumber group '$TARGET_GROUP' to GID $SOCK_GID"
              fi
            fi
          else
            if ! addgroup -g "$SOCK_GID" "$TARGET_GROUP" 2>/dev/null; then
              warn "failed to create group '$TARGET_GROUP' with GID $SOCK_GID"
            fi
          fi
          addgroup "$USER_NAME" "$TARGET_GROUP" 2>/dev/null || true
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

    if socat -u -T2 /dev/null "UNIX-CONNECT:$SOCKET" 2>/dev/null; then
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
# On some Docker configurations (rootless, restrictive seccomp /
# apparmor), non-root users cannot open /dev/stderr via
# /proc/self/fd/2, which prevents Angie from writing to its log
# symlinks. Running the master as root avoids that entirely.
#
# Set ANGIE_DROP_MASTER=true on environments where su-exec is known
# to work (standard rootful Docker).
if [ "${ANGIE_DROP_MASTER:-}" = "true" ] && [ "$USER_NAME" != "root" ]; then
  exec su-exec "$USER_NAME" "$@"
fi

exec "$@"
