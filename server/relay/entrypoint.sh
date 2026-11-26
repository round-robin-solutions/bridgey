#!/bin/sh
# Renders turnserver.conf from the template and the environment into /run/coturn (a tmpfs),
# then runs coturn. TURN_SECRET must be hex (openssl rand -hex 32), so it is safe in sed.
set -eu
: "${TURN_SECRET:?TURN_SECRET is required}"
: "${EXTERNAL_IP:?EXTERNAL_IP is required (public address, or public/private when behind NAT)}"
case "$TURN_SECRET" in *[!0-9a-f]*) echo "TURN_SECRET must be lowercase hex" >&2; exit 1;; esac
umask 077
sed \
  -e "s|@TURN_SECRET@|$TURN_SECRET|" \
  -e "s|@EXTERNAL_IP@|$EXTERNAL_IP|" \
  -e "s|@LISTEN_PORT@|${LISTEN_PORT:-3478}|" \
  -e "s|@MIN_PORT@|${MIN_PORT:-61000}|" \
  -e "s|@MAX_PORT@|${MAX_PORT:-62999}|" \
  -e "s|@TOTAL_QUOTA@|${TOTAL_QUOTA:-300}|" \
  -e "s|@BPS_CAPACITY@|${BPS_CAPACITY:-25000000}|" \
  /etc/bridgey-relay/turnserver.conf.template > /run/coturn/turnserver.conf
if [ -n "${LISTENING_IP:-}" ]; then
  echo "listening-ip=$LISTENING_IP" >> /run/coturn/turnserver.conf
  echo "relay-ip=$LISTENING_IP" >> /run/coturn/turnserver.conf
fi
# The relay's own public address stays allowed: two peers on the same relay reach each other through it, and the
# core asks permission for every relay in the pool, its own included (coturn has no exception for itself and fails
# the whole request). UDP services on the relay host are kept from relayed traffic by the host firewall instead
# (docs/connect-anywhere-deploy.md, "Relay host firewall"; security review 1.0, C4).
# Local tests only: let the relay reach its own tailnet address (relay to relay on one host).
if [ -n "${ALLOWED_PEER_IP:-}" ]; then
  echo "allowed-peer-ip=$ALLOWED_PEER_IP" >> /run/coturn/turnserver.conf
fi
unset TURN_SECRET
exec turnserver -c /run/coturn/turnserver.conf
