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
