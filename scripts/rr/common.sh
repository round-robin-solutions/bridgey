# Shared helpers for scripts/rr/*.sh (sourced, not executed).
RR_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RR_PROPERTIES="$RR_ROOT/rr-edition.properties"

edition_value() {
  value=$(sed -n "s/^$1=//p" "$RR_PROPERTIES" | tail -n 1)
  [ -n "$value" ] || { echo "rr-edition.properties is missing $1" >&2; exit 1; }
  printf '%s' "$value"
}

die() { echo "error: $*" >&2; exit 1; }

# KEY's value in a KEY=value file such as a job's release.env, without a carriage return: files written on Windows
# may end their lines with CRLF.
env_value() {
  tr -d '\r' < "$1" | sed -n "s/^$2=//p" | tail -n 1
}
