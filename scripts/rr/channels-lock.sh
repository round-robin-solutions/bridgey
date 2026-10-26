# The channels lock, sourced by publish.sh (needs REPO, TARGET, HOLDER and gh auth).
# The feeds hold every channel (the appcast has stable, beta and nightly items), and nightlies publish
# from GitHub Actions while betas and stable publish from rr-dev-1, so every publish runs under this
# lock: the git ref refs/rr-ci/channels-lock, which GitHub creates atomically. It points at a tag
# object made for each attempt, whose tagger date gives its age; a lock older than
# BRIDGEY_RR_LOCK_STALE_SECONDS (default 1800) is taken over.
LOCK_REF=refs/rr-ci/channels-lock
STALE=${BRIDGEY_RR_LOCK_STALE_SECONDS:-1800}
LOCK_OBJECT=""
release_lock() {
  [ -n "$LOCK_OBJECT" ] || return 0
  # Only remove the lock while it is still ours.
  if [ "$(gh api "repos/$REPO/git/$LOCK_REF" --jq .object.sha 2>/dev/null || true)" = "$LOCK_OBJECT" ]; then
    gh api -X DELETE "repos/$REPO/git/$LOCK_REF" >/dev/null 2>&1 || true
  fi
  LOCK_OBJECT=""
}
# The lock points at a tag object whose tagger date tells its age and whose message names the holder.
# A new one is made for every attempt, so a lock is always dated when it was taken.
new_lock_object() {
  gh api "repos/$REPO/git/tags" -f tag=channels-lock -f message="$HOLDER" -f object="$TARGET" -f type=commit \
    -f "tagger[name]=Bridgey release" -f "tagger[email]=noreply@roundrobin.in" -f "tagger[date]=$(date -u +%Y-%m-%dT%H:%M:%SZ)" --jq .sha
}
lock_now() { gh api "repos/$REPO/git/$LOCK_REF" --jq .object.sha 2>/dev/null || true; }
still_ours() { [ -n "$LOCK_OBJECT" ] && [ "$(lock_now)" = "$LOCK_OBJECT" ]; }
acquire_lock() {
  WAITED=0
  while :; do
    CANDIDATE=$(new_lock_object)
    if OUT=$(gh api "repos/$REPO/git/refs" -f ref="$LOCK_REF" -f sha="$CANDIDATE" 2>&1); then
      LOCK_OBJECT=$CANDIDATE
      break
    fi
    case "$OUT" in *"Reference already exists"*) ;; *) die "could not take the channels lock: $(printf '%s' "$OUT" | tail -n 1)" ;; esac
    CURRENT=$(lock_now)
    if [ -n "$CURRENT" ]; then
      INFO=$(gh api "repos/$REPO/git/tags/$CURRENT" --jq '.tagger.date + " " + .message' 2>/dev/null || true)
      SINCE=$(python3 -c 'import datetime,sys;d=sys.argv[1].split(" ")[0];print(int((datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(d.replace("Z","+00:00"))).total_seconds()) if d else 0)' "$INFO")
      if [ "$SINCE" -gt "$STALE" ] && [ "$(lock_now)" = "$CURRENT" ]; then
        # Take over by moving the ref from the stale holder to us, then make sure no other waiter did
        # the same a moment later: whoever the ref names after the pause holds the lock.
        echo "taking over a stale channels lock (${SINCE}s old: ${INFO#* })"
        if gh api -X PATCH "repos/$REPO/git/$LOCK_REF" -f sha="$CANDIDATE" -F force=true >/dev/null 2>&1; then
          sleep 5
          if [ "$(lock_now)" = "$CANDIDATE" ]; then LOCK_OBJECT=$CANDIDATE; break; fi
        fi
        continue
      fi
      echo "waiting for the channels lock (held ${SINCE}s by ${INFO#* })"
    fi
    [ "$WAITED" -lt 3600 ] || die "the channels lock was not free within an hour"
    sleep 15
    WAITED=$((WAITED + 15))
  done
}
