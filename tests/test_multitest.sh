#!/bin/bash

set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_BIN=$(mktemp -d)
trap 'rm -rf "$TEST_BIN"' EXIT

source "$PROJECT_DIR/multitest.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    [[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

cat > "$TEST_BIN/ip" <<'EOF'
#!/bin/sh
case "$*" in
    *"-4 route show default"*)
        echo "default via 192.0.2.1 dev ens3 proto dhcp src 192.0.2.10 metric 100"
        ;;
    *"-6 route show default"*)
        echo "default via 2001:db8::1 dev ens3 proto ra metric 100"
        echo "default via 2001:db8:1::1 dev enp1s0 proto static metric 200"
        ;;
esac
EOF

cat > "$TEST_BIN/tc" <<'EOF'
#!/bin/sh
if [ "$4" = "ens3" ]; then
    echo "qdisc cake 8012: root refcnt 2 bandwidth unlimited diffserv3"
else
    echo "qdisc fq_codel 0: root refcnt 2 limit 10240p"
fi
EOF

cat > "$TEST_BIN/sshd" <<'EOF'
#!/bin/sh
echo "port 2222"
echo "port 22"
EOF

chmod +x "$TEST_BIN/ip" "$TEST_BIN/tc" "$TEST_BIN/sshd"
PATH="$TEST_BIN:$PATH"

interfaces=$(detect_network_interfaces)
assert_eq $'ens3\nenp1s0' "$interfaces" "default-route interface detection"

MULTITEST_NET_IFACE="eth9"
assert_eq "eth9" "$(detect_network_interfaces)" "explicit interface override"
unset MULTITEST_NET_IFACE

cake_is_active_on_interface ens3 || fail "CAKE should be active on ens3"
if cake_is_active_on_interface enp1s0; then
    fail "CAKE should not be active on enp1s0"
fi

assert_eq "2222,22" "$(detect_sshd_ports)" "SSH port detection"

bash -n "$PROJECT_DIR/multitest.sh"
echo "PASS: multitest tests"
