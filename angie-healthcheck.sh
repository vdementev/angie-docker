#!/bin/sh
# Container healthcheck: the master is alive and — when the Docker socket is
# mounted — service discovery can still reach it.
#
# The socket probe is the reason this script exists. When dockerd restarts it
# recreates /var/run/docker.sock; a container that bind-mounts the socket as a
# single file keeps the old, dead inode. Angie goes on serving from the
# upstreams it discovered earlier, so an HTTP ping stays green — until the next
# config reload wipes the dynamically discovered upstreams and discovery cannot
# repopulate them. Then every request 502s at once. Catching the dead socket
# while the site is still up is the whole point.
set -eu

SOCKET="${FILE_FOR_GROUP:-/var/run/docker.sock}"
PIDFILE=/run/angie.pid

fail() { printf '[healthcheck] %s\n' "$*" >&2; exit 1; }

# ── Master process ──────────────────────────────────────────────
[ -s "$PIDFILE" ] || fail "no pid file at $PIDFILE"
kill -0 "$(cat "$PIDFILE")" 2>/dev/null || fail "master process is not running"

# ── Docker socket reachability ──────────────────────────────────
# Skipped when the socket isn't mounted (plain reverse-proxy duty, no
# docker_endpoint discovery) or when explicitly disabled.
if [ "${ANGIE_SOCKET_CHECK:-true}" = "true" ] && [ -e "$SOCKET" ]; then
  socat -u -T2 /dev/null "UNIX-CONNECT:$SOCKET" 2>/dev/null \
    || fail "cannot connect to $SOCKET — service discovery is dead, restart this container"
fi

# ── Optional HTTP probe ─────────────────────────────────────────
# Off unless ANGIE_HEALTHCHECK_URL is set: the image ships no opinionated
# vhost, so only the operator knows which URL is supposed to answer.
if [ -n "${ANGIE_HEALTHCHECK_URL:-}" ]; then
  wget -q -O /dev/null -T "${ANGIE_HEALTHCHECK_TIMEOUT:-2}" -t 1 "$ANGIE_HEALTHCHECK_URL" \
    || fail "HTTP probe failed: $ANGIE_HEALTHCHECK_URL"
fi
