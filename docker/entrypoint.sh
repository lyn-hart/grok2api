#!/bin/sh
set -eu

umask 077

quality_guard_dir=/var/lib/grok2api-quality-guard
mkdir -p "${quality_guard_dir}"
chown grok2api:grok2api "${quality_guard_dir}"
chmod 0700 "${quality_guard_dir}"

if [ ! -f "${GROK2API_CONFIG_SOURCE}" ]; then
  echo "missing config: ${GROK2API_CONFIG_SOURCE}" >&2
  echo "mount config.yaml to /run/grok2api/config.yaml" >&2
  exit 1
fi

cp "${GROK2API_CONFIG_SOURCE}" /app/config.yaml
chown grok2api:grok2api /app/config.yaml
chmod 0600 /app/config.yaml

# Without TUNNEL_TOKEN, keep the original single-process path (PID 1 = app).
if [ -z "${TUNNEL_TOKEN:-}" ]; then
  exec su-exec grok2api:grok2api "$@"
fi

echo "TUNNEL_TOKEN set: starting grok2api + cloudflared" >&2

app_pid=""
tunnel_pid=""
exit_code=0

term_children() {
  if [ -n "${app_pid}" ] && kill -0 "${app_pid}" 2>/dev/null; then
    kill -TERM "${app_pid}" 2>/dev/null || true
  fi
  if [ -n "${tunnel_pid}" ] && kill -0 "${tunnel_pid}" 2>/dev/null; then
    kill -TERM "${tunnel_pid}" 2>/dev/null || true
  fi
}

wait_children() {
  if [ -n "${app_pid}" ]; then
    wait "${app_pid}" 2>/dev/null || true
  fi
  if [ -n "${tunnel_pid}" ]; then
    wait "${tunnel_pid}" 2>/dev/null || true
  fi
}

on_signal() {
  echo "received stop signal; shutting down" >&2
  exit_code=143
  term_children
  wait_children
  exit "${exit_code}"
}

trap on_signal TERM INT HUP

# cloudflared may write state under $HOME; keep it off root-owned paths.
export HOME=/tmp

su-exec grok2api:grok2api "$@" &
app_pid=$!

su-exec grok2api:grok2api cloudflared tunnel --no-autoupdate run --token "${TUNNEL_TOKEN}" &
tunnel_pid=$!

# Reap the first child that exits; stop the other.
while kill -0 "${app_pid}" 2>/dev/null && kill -0 "${tunnel_pid}" 2>/dev/null; do
  sleep 1
done

if ! kill -0 "${app_pid}" 2>/dev/null; then
  wait "${app_pid}" 2>/dev/null || exit_code=$?
  echo "grok2api exited with ${exit_code}; stopping cloudflared" >&2
else
  wait "${tunnel_pid}" 2>/dev/null || exit_code=$?
  echo "cloudflared exited with ${exit_code}; stopping grok2api" >&2
  if [ "${exit_code}" -eq 0 ]; then
    exit_code=1
  fi
fi

term_children
wait_children
exit "${exit_code}"
