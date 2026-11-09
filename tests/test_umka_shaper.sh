#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
if [ "$#" -eq 0 ]; then set -- "$PROJECT_DIR/umka-shaper.sh"; fi
SHAPER=$(realpath "$1")
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

fail() { printf 'FAIL: %s\n%s\n' "$1" "$OUTPUT" >&2; exit 1; }

auto() {
    bash -s -- "$SHAPER" "$WORK/config.json" "$@" <<'DRIVER'
source "$1"
UMKA_CONFIG=$2
shift 2
id() { echo 0; }
ip() {
    case "$*" in
        '-o -4 route show default') printf '%s\n' "$CASE_ROUTES" ;;
        '-o -6 route show default') : ;;
        '-o addr show dev eth0 scope global')
            echo '2: eth0 inet 192.0.2.10/24 scope global eth0'
            echo '2: eth0 inet6 2001:db8::10/64 scope global'
            ;;
        *) return 91 ;;
    esac
}
ss() {
    [[ "$*" == '-H -lntup' ]] || return 92
    printf '%s\n' "$CASE_SOCKETS"
}
systemctl() {
    case "$*" in
        'show -p LoadState --value umka-traffic-shaper.service') echo "$CASE_LOAD" ;;
        'is-enabled --quiet multitest-cake.service') [[ "$CASE_CAKE" == enabled ]] ;;
        'is-active --quiet multitest-cake.service') [[ "$CASE_CAKE" == active ]] ;;
        'is-active --quiet umka-traffic-shaper.service') [[ "$CASE_STATE" == active ]] ;;
        'is-failed --quiet umka-traffic-shaper.service') [[ "$CASE_STATE" == failed ]] ;;
        'is-active --quiet reshala-traffic-limiter.service'|'is-enabled --quiet reshala-traffic-limiter.service') return 1 ;;
        *) printf 'Unexpected systemctl action: %s\n' "$*" >&2; return 93 ;;
    esac
}
record_check() { echo CHECK; }
install_selected() { printf 'INSTALL %s %s %s\n' "$UMKA_IFACE" "$UMKA_PORTS" "$UMKA_PREPARE_ONLY"; }
activate_shaper() { printf 'ACTIVATE %s %s\n' "$UMKA_IFACE" "$UMKA_PORTS"; }
show_active_shaper() { printf 'ACTIVE %s %s\n' "$UMKA_IFACE" "$UMKA_PORTS"; }
auto_node "$@"
DRIVER
}

ok() {
    local expected=$1
    shift
    OUTPUT=$(auto "$@" 2>&1) || fail "expected success: $expected"
    [[ "$OUTPUT" == *CHECK* && "$OUTPUT" == *"$expected"* ]] || fail "$expected"
}

blocked() {
    local expected=$1
    shift
    if OUTPUT=$(auto "$@" 2>&1); then fail "expected failure: $expected"; fi
    [[ "$OUTPUT" == *"$expected"* && "$OUTPUT" != *INSTALL* && "$OUTPUT" != *ACTIVATE* ]] \
        || fail "$expected"
}

export CASE_ROUTES='default via 192.0.2.1 dev eth0'
export CASE_LOAD=not-found CASE_STATE=inactive CASE_CAKE=none CASE_SOCKETS=''

ok 'INSTALL eth0 443 1'

export CASE_SOCKETS='tcp LISTEN 0 4096 *:443 *:* users:(("rw-core",pid=123,fd=4))'
ok 'INSTALL eth0 443 0'
ok 'INSTALL eth0 443 1' --prepare-only

export CASE_SOCKETS='tcp LISTEN 0 4096 [2001:db8::10]:8443 [::]:* users:(("xray",pid=123,fd=4))'
ok 'INSTALL eth0 8443 0'

export CASE_SOCKETS=$'tcp LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:* users:(("xray",pid=123,fd=4))\ntcp LISTEN 0 4096 192.0.2.99:9443 0.0.0.0:* users:(("rw-core",pid=123,fd=5))'
ok 'INSTALL eth0 443 1'

export CASE_SOCKETS='tcp LISTEN 0 4096 *:443 *:* users:(("caddy",pid=123,fd=4))'
blocked '--ports'
ok 'INSTALL eth0 443 0' --ports 443

export CASE_SOCKETS=$'tcp LISTEN 0 4096 *:443 *:* users:(("rw-core",pid=123,fd=4))\nudp UNCONN 0 0 *:443 *:* users:(("caddy",pid=321,fd=8))'
blocked '--ports'

export CASE_SOCKETS=$'tcp LISTEN 0 4096 *:443 *:* users:(("rw-core",pid=123,fd=4))\ntcp LISTEN 0 4096 *:8443 *:* users:(("xray",pid=123,fd=5))'
blocked '--ports'
ok 'INSTALL eth0 443,8443 0' --ports 443,8443

export CASE_ROUTES=$'default via 192.0.2.1 dev eth0\ndefault via 198.51.100.1 dev ens3'
blocked '--interface'
ok 'INSTALL eth0 443 0' --interface eth0 --ports 443
export CASE_ROUTES='default via 192.0.2.1 dev eth0'

export CASE_CAKE=enabled
blocked 'multitest-cake.service' --ports 443
export CASE_CAKE=none

cat > "$WORK/config.json" <<'JSON'
{"interface":"eth0","ports":[443],"threshold_mbps":100,"hold_seconds":600,"penalty_mbps":30,"penalty_seconds":2400,"policy_version":"umka-timed-v1","upstream_commit":"079365e65abd50f752ecf0a16eb3a063142f42b5"}
JSON
export CASE_LOAD=loaded CASE_SOCKETS=''
ok 'PREPARED'
[[ "$OUTPUT" != *INSTALL* && "$OUTPUT" != *ACTIVATE* ]] || fail 'prepared service must be left intact'

export CASE_SOCKETS='tcp LISTEN 0 4096 *:443 *:* users:(("rw-core",pid=123,fd=4))'
ok 'ACTIVATE eth0 443'
[[ "$OUTPUT" != *INSTALL* ]] || fail 'prepared service must not be reinstalled'
blocked 'конфигурац' --ports 8443

export CASE_STATE=active
ok 'ACTIVE eth0 443'
[[ "$OUTPUT" != *INSTALL* && "$OUTPUT" != *ACTIVATE* ]] || fail 'active service must not be restarted'

export CASE_STATE=failed
blocked 'journalctl'

export CASE_STATE=inactive
sed -i 's/"threshold_mbps":100/"threshold_mbps":200/' "$WORK/config.json"
blocked 'стандартной политике'

printf 'PASS: Umka shaper automatic discovery and lifecycle\n'
