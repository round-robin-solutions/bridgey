#!/usr/bin/env bash
# Connect anywhere, local live test on one host (rr-dev-1): the control service and a relay in
# containers on the tailnet address, two headless nodes (rust/core/examples/probe.rs), a capture of
# every relay packet. Shows the relay route, the direct route and failover, and that the relay
# carries only ciphertext. Tears everything down at the end.
#
#   server/local/live-test.sh [TEST_IP]       (default 100.121.85.33)
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_IP=${1:-100.121.85.33}
CARGO=${CARGO:-$HOME/.cargo/bin/cargo}
WORK=$(mktemp -d /tmp/bridgey-live.XXXXXX)
export TEST_IP
TURN_SECRET=$(openssl rand -hex 32)
export TURN_SECRET
cleanup() {
  docker compose -f server/local/compose.yml down --remove-orphans >/dev/null 2>&1 || true
  [ -n "${CAPTURE:-}" ] && sudo kill "$CAPTURE" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== build"
(cd rust && "$CARGO" build -q --release -p bridgey-connect --example probe)
docker compose -f server/local/compose.yml up -d --build >/dev/null
for _ in $(seq 1 30); do curl -sf "http://$TEST_IP:18450/health/ready" >/dev/null && break; sleep 1; done
curl -sf "http://$TEST_IP:18450/v1/status" && echo

PROBE=rust/target/release/examples/probe
CONTROL="ws://$TEST_IP:18450/v1/ws"
SECRET=$(head -c32 /dev/urandom | base64)

echo "== capture relay traffic (3479 and 59000-59499)"
sudo tcpdump -i any -U -w "$WORK/relay.pcap" "udp and host $TEST_IP and (port 3479 or portrange 59000-59499)" >/dev/null 2>&1 &
CAPTURE=$!
sleep 1

echo "== 1. relay only (both nodes block every direct path)"
"$PROBE" --id aaaa --peer bbbb --side 0 --secret "$SECRET" --control "$CONTROL" --relay-only --seconds 20 > "$WORK/a1.log" &
"$PROBE" --id bbbb --peer aaaa --side 1 --secret "$SECRET" --control "$CONTROL" --relay-only --seconds 20 > "$WORK/b1.log" &
wait %2 %3 2>/dev/null || wait
grep -h '"probe":"tunnel"\|first_echo\|echo_rtt\|race' "$WORK/a1.log" | cut -c1-220

echo "== 2. direct (learned tailnet address), then failover to the relay at 8 s"
"$PROBE" --id aaaa --peer bbbb --side 0 --secret "$SECRET" --control "$CONTROL" --port 42460 --address "$TEST_IP:42461" --relay-only-after 8 --seconds 22 > "$WORK/a2.log" &
"$PROBE" --id bbbb --peer aaaa --side 1 --secret "$SECRET" --control "$CONTROL" --port 42461 --address "$TEST_IP:42460" --seconds 22 > "$WORK/b2.log" &
wait
grep -h '"probe":"tunnel"\|relay_only_on\|bridge_closed\|first_echo\|race' "$WORK/a2.log" | cut -c1-220

sleep 1
sudo kill "$CAPTURE" 2>/dev/null || true
CAPTURE=
sleep 1
echo "== what the relay saw"
sudo tcpdump -r "$WORK/relay.pcap" -q 2>/dev/null | wc -l | xargs echo "packets:"
sudo chmod a+r "$WORK/relay.pcap"
for marker in PLAINTEXT-MARKER probe.ping pairing.offer aaaa bbbb; do
  hits=$(grep -c -a "$marker" "$WORK/relay.pcap" || true)
  echo "plaintext \"$marker\" in relay packets: $hits"
done
