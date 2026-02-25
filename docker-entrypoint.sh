#!/bin/sh
set -eu

FILE="${FILE_FOR_GROUP:-/var/run/docker.sock}"
TARGET_GROUP="${DOCKER_GROUP_NAME:-docker}"
USER_NAME="${ANGIE_USER:-angie}"

# Assign the target user to the Docker socket's group
# (needed by workers for docker_endpoint service discovery)
if [ -e "$FILE" ]; then
  GID="$(stat -c %g "$FILE" 2>/dev/null || busybox stat -c %g "$FILE")"
  if [ -n "${GID:-}" ] && [ "$GID" -gt 0 ]; then
    EXISTING_GROUP="$(getent group | awk -F: -v gid="$GID" '$3==gid{print $1; exit}')"
    if [ -n "$EXISTING_GROUP" ]; then
      addgroup "$USER_NAME" "$EXISTING_GROUP" 2>/dev/null || true
    else
      if getent group "$TARGET_GROUP" >/dev/null 2>&1; then
        CURRENT_GID="$(getent group "$TARGET_GROUP" | awk -F: '{print $3}')"
        if [ "$CURRENT_GID" != "$GID" ]; then
          sed -i -E "s/^(${TARGET_GROUP}:[^:]*:)[0-9]+:/\1${GID}:/" /etc/group
        fi
      else
        addgroup -g "$GID" "$TARGET_GROUP"
      fi
      addgroup "$USER_NAME" "$TARGET_GROUP" 2>/dev/null || true
    fi
  fi
fi

# Drop master process privileges only when explicitly requested.
# By default, the master runs as root and the "user" directive in
# angie.conf handles worker privilege separation — matching the
# standard nginx Docker image approach.
#
# On some Docker configurations (rootless, restrictive seccomp/apparmor),
# non-root users cannot open /dev/stderr via /proc/self/fd/2, which
# prevents angie from writing to its log symlinks. Running the master
# as root avoids this issue entirely.
#
# Set ANGIE_DROP_MASTER=true for environments where su-exec is known
# to work (standard rootful Docker).
if [ "${ANGIE_DROP_MASTER:-}" = "true" ] && [ "$USER_NAME" != "root" ]; then
  exec su-exec "$USER_NAME" "$@"
fi

exec "$@"
