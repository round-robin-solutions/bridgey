#!/usr/bin/env bash
# Points the three Connect anywhere Dokploy entries (Round Robin Dokploy, project "Bridgey") at a branch,
# for when rr/connect-anywhere merges into rr/main. Reads the Dokploy API key from the vault note
# "Keychain/Round Robin Dokploy.md" without printing it, updates each entry, reads it back, and redeploys
# the control service (the relays only redeploy when asked: their compose file is unchanged).
#
#   server/deploy/switch-branch.sh rr/main [--redeploy-relays]
set -euo pipefail
BRANCH=${1:?branch}
VAULT=${VAULT:-$HOME/obsidian-vault/Keychain/Round Robin Dokploy.md}
URL=$(python3 - "$VAULT" <<'PY'
import re,sys
for l in open(sys.argv[1]):
    m=re.match(r'\|\s*URL \(public\)\s*\|\s*`([^`]+)`',l)
    if m: print(m.group(1)); break
PY
)
KEY=$(python3 - "$VAULT" <<'PY'
import re,sys
for l in open(sys.argv[1]):
    m=re.match(r'\|\s*API Key\s*\|\s*`([^`]+)`',l)
    if m: print(m.group(1)); break
PY
)
# The key goes to curl in a private header file, not on its command line.
HDR=$(mktemp); chmod 600 "$HDR"; trap 'rm -f "$HDR"' EXIT
printf 'x-api-key: %s\nContent-Type: application/json\n' "$KEY" > "$HDR"
api() { curl -sS -A 'Mozilla/5.0' -H @"$HDR" "$@"; }
APP=AWhUiERgwLozVUZrH6aAz          # bridgey-rendezvous (rr-web)
RELAYS="sPkcw4V_FcPmlFYpGF8Bw AUcFGMLUaVr3qgXixmTvn"  # bridgey-relay-sg (rb-vps), bridgey-relay-eu (rr-dev-1)

api -X POST "$URL/api/application.update" -d "{\"applicationId\":\"$APP\",\"branch\":\"$BRANCH\"}" >/dev/null
for c in $RELAYS; do api -X POST "$URL/api/compose.update" -d "{\"composeId\":\"$c\",\"branch\":\"$BRANCH\"}" >/dev/null; done
api "$URL/api/application.one?applicationId=$APP" | python3 -c "import json,sys; d=json.load(sys.stdin); print('bridgey-rendezvous', d['branch'], d['autoDeploy'])"
for c in $RELAYS; do api "$URL/api/compose.one?composeId=$c" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['name'], d['branch'], d['autoDeploy'])"; done
api -X POST "$URL/api/application.deploy" -d "{\"applicationId\":\"$APP\",\"title\":\"Follow $BRANCH\"}" >/dev/null && echo "control service redeploy queued"
if [ "${2:-}" = --redeploy-relays ]; then
  for c in $RELAYS; do api -X POST "$URL/api/compose.deploy" -d "{\"composeId\":\"$c\",\"title\":\"Follow $BRANCH\"}" >/dev/null; done
  echo "relay redeploys queued"
fi
echo "check: curl -s https://connect.roundrobin.in/health/ready"
