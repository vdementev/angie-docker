#!/bin/sh
set -eu

FILE="${FILE_FOR_GROUP:-/var/run/docker.sock}"
TARGET_GROUP="${DOCKER_GROUP_NAME:-docker}"
USER_NAME="${ANGIE_USER:-angie}"

# Checkif file exist
if [ ! -e "$FILE" ]; then
  exec "$@"
fi

# Check GID of the file
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

exec "$@"
