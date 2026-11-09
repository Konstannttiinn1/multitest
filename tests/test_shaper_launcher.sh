#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

fail() { printf 'FAIL: %s\n%s\n' "$1" "$OUTPUT" >&2; exit 1; }

# The helper must be callable without entering the interactive menu.
OUTPUT=$(bash -c 'source "$1"; run_umka_shaper --help' bash "$PROJECT_DIR/multitest.sh" 2>&1) \
    || fail 'launch shaper help from a checkout'
[[ "$OUTPUT" == *'автоматическая установка шейпера'* ]] || fail 'wrong help'

cp "$PROJECT_DIR/multitest.sh" "$PROJECT_DIR/umka-shaper.sh" "$WORK/"
printf '\n# damaged download\n' >> "$WORK/umka-shaper.sh"
if OUTPUT=$(bash "$WORK/multitest.sh" --shaper --help 2>&1); then fail 'accepts a changed helper'; fi
[[ "$OUTPUT" == *SHA-256* ]] || fail 'no checksum error'

# An installed copy of multitest has no sibling helper. Mock only the transport.
rm -- "$WORK/umka-shaper.sh"
mkdir "$WORK/bin"
export TEST_HELPER="$PROJECT_DIR/umka-shaper.sh" TEST_URL="$WORK/url"
cat > "$WORK/bin/curl" <<'CURL'
#!/bin/bash
set -eu
while [ "$#" -gt 1 ]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' "$1" > "$TEST_URL"
cp -- "$TEST_HELPER" "$output"
CURL
chmod +x "$WORK/bin/curl"
OUTPUT=$(PATH="$WORK/bin:$PATH" bash "$WORK/multitest.sh" --shaper --help 2>&1) \
    || fail 'launch verified downloaded helper'
[[ "$OUTPUT" == *'автоматическая установка шейпера'* ]] || fail 'wrong downloaded helper'
[[ "$(cat "$TEST_URL")" =~ ^https://raw\.githubusercontent\.com/Konstannttiinn1/multitest/[0-9a-f]{40}/umka-shaper\.sh$ ]] \
    || fail 'helper is not pinned to a commit'

# This call must stop before any networking mutation.
if OUTPUT=$(bash -s -- "$PROJECT_DIR/multitest.sh" 2>&1 <<'DRIVER'
source "$1"
require_root() { :; }
systemctl() { [[ "$*" == 'is-enabled --quiet umka-traffic-shaper.service' ]]; }
ip() { echo 'default via 192.0.2.1 dev eth0'; }
tc() { echo MUTATION; exit 91; }
modprobe() { echo MUTATION; exit 92; }
enable_bbr_cake
DRIVER
); then fail 'CAKE allowed while Umka is enabled'; fi
[[ "$OUTPUT" == *umka-traffic-shaper.service* && "$OUTPUT" != *MUTATION* ]] || fail 'CAKE conflict guard'

printf 'PASS: multitest shaper launcher, integrity and CAKE guard\n'
