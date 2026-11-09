#!/usr/bin/env bash
# Multitest integration of Umka node installer 2026-10-26.2.
# check: reads host state and writes a private report; does not install/attach anything.
# install: fresh Ubuntu 24.04 x86_64 only; explicit interface/ports; no in-place upgrades.
# Policy: external IP >100 Mbps in either direction for 600s => 30 Mbps/direction for 2400s.
# Shared NAT shares a policy. This is not a per-UUID or per-device limiter.
# Full speed/expiry/reboot acceptance must be performed on the target node.
set -euo pipefail
umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
UMKA_NODE_VERSION='2026-10-26.2'
UMKA_PACKAGE_SHA256='0d75240f566fecf9d346e819984e4b337b70006150bb76be76116bca2f4c672a'
UMKA_PACKAGE_DIR='umka-shaper-20261026'
UMKA_COMMIT='079365e65abd50f752ecf0a16eb3a063142f42b5'
UMKA_UNIT='umka-traffic-shaper.service'
UMKA_CONFIG='/etc/umka-shaper/config.json'
UMKA_SELF=$(readlink -f -- "${BASH_SOURCE[0]}")

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section() { printf '\n--- %s ---\n' "$*"; }

help_text() {
    cat <<'HELP'
Umka: автоматическая установка шейпера, пакет 2026-10-26.2.

Проверить сервер, выбрать интерфейс и порт, установить и включить:
  bash umka-shaper.sh

Явный выбор для нескольких интерфейсов/портов или reverse proxy:
  bash umka-shaper.sh auto --interface eth0 --ports 443,8443

На пустом узле готовит шейпер для порта 443. После запуска VPN
повтори ту же команду: готовая установка будет активирована.
Работающий шейпер: проверка состояния без переустановки.
Добавь --prepare-only для подготовки даже при работающем VPN.

Проверить сервер и сохранить текстовый отчёт:
  bash umka-shaper.sh check

После разбора отчёта установить и включить:
  bash umka-shaper.sh install --interface ens3 --ports 443

Другие интерфейс/порты задаются явно. Пример:
  bash umka-shaper.sh install --interface eth0 --ports 443,8443

Исправить уже установленный точный engine версии 2026-10-23 без рестарта:
  bash umka-shaper.sh repair-fq

Если VPN ещё не установлен, только подготовить шейпер, без hooks и автозапуска:
  bash umka-shaper.sh auto --interface ens3 --ports 443 --prepare-only

После запуска VPN на нужных портах включить подготовленный шейпер:
  bash umka-shaper.sh

Проверки после установки:
  umka-shaper status
  tc qdisc show dev ens3
  tc -s filter show dev ens3 ingress
  tc -s filter show dev ens3 egress
  journalctl -u umka-traffic-shaper.service -b -n 60 --no-pager -o cat

Остановка и отмена автозапуска:
  systemctl disable --now umka-traffic-shaper.service
  umka-shaper stop

Правило: >100 Мбит/с в любом направлении 10 минут подряд =>
30 Мбит/с отдельно DL/UL на 40 минут, затем снятие ограничения.
Ключ — внешний IP. За NAT/CGNAT несколько устройств делят правило.
Интервал ниже/на пороге или простой сбрасывает таймер превышения.
Перезапуск службы/узла сбрасывает счётчики, таймеры и ограничения.
Трафик определяется по внешним портам, включая обращения сканеров.
Это не блокировка торрентов и не общий лимит канала сервера.

Установка: Ubuntu 24.04 x86_64 с systemd и Linux >=5.18.
Нужны python3, iproute2 и стандартные утилиты до первого install.
Зависимости компиляции установятся через apt после preflight.
Старые установки/ownership, чужие clsact/ingress и неизвестные
очереди требуют отдельного разбора. Поддержанный исходный fq-root
используется без замены его handle/параметров. mq с исходными fq-листьями
по-прежнему требует разбора. Неизвестные опции fq требуют разбора.
CAKE принимается только с проверенным unlimited-профилем.
Во время работы fq заменяет исходную fq_codel/поддержанную CAKE.
Штатный stop возвращает сохранённые параметры очередей; именованный
mq cafe: после остановки может остаться как родитель.
Глобальные sysctl не переписываются. Docker/VPN не устанавливаются.

Перед изменением очередей сохраняется снимок /var/backups/umka-shaper/.
check не запускает apt, не меняет сеть и не читает секреты конфигураций.
Отчёт содержит hostname, порты, имена процессов и сетевые параметры.
Логи установки также могут содержать внешние IP подключений.

ACTIVE подтверждает запуск службы, но не замер ограничения скорости.
Отдельно проверить >100 Мбит/с непрерывно 600с, скорость после срабатывания,
снятие ограничения через 2400с, оба направления, stop/restore и reboot.
После reboot фактический qdisc может отличаться от первоначального;
готовность автозапуска на конкретном сервере требует проверки.
Исправление поддержки исходного fq не заменяет реальный reboot-тест.

При ошибке сохранить отчёт/лог. Повторный install существующей установки
запрещён: сначала разбор состояния. Не удалять tc/state/pins вручную.
HELP
}

read_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Недоступна команда: %s\n' "$1"
        return 0
    fi
    local rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout 20s "$@" || rc=$?
    else
        "$@" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        printf '[%s: код %s]\n' "$1" "$rc"
    fi
    return 0
}

primary_interface() {
    command -v ip >/dev/null 2>&1 || return 0
    { ip -4 route get 1.1.1.1 2>/dev/null || true; } |
        awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

check_host() {
    local iface unit p
    section 'Версия проверки и время UTC'
    printf 'Umka node %s\n' "$UMKA_NODE_VERSION"
    read_cmd date -u '+%Y-%m-%dT%H:%M:%SZ'
    read_cmd hostname
    read_cmd id
    read_cmd sha256sum "$UMKA_SELF"
    section 'ОС, ядро, архитектура, виртуализация'
    if [ -r /etc/os-release ]; then cat /etc/os-release; fi
    read_cmd uname -r
    read_cmd uname -m
    read_cmd systemd-detect-virt
    section 'CPU, память, диск и нагрузка'
    read_cmd nproc
    read_cmd free -h
    read_cmd df -h /
    read_cmd uptime
    section 'Интерфейсы и маршруты'
    read_cmd ip -br link
    read_cmd ip -4 route show default
    read_cmd ip -6 route show default
    iface=$(primary_interface)
    section 'Очереди и фильтры основного IPv4-интерфейса'
    read_cmd tc -V
    if [ -n "$iface" ]; then
        printf 'Предполагаемый интерфейс: %s\n' "$iface"
        read_cmd tc qdisc show dev "$iface"
        read_cmd tc -j -d qdisc show dev "$iface"
        printf '\nIngress:\n'
        read_cmd tc -s filter show dev "$iface" ingress
        printf '\nEgress:\n'
        read_cmd tc -s filter show dev "$iface" egress
    else
        printf 'IPv4-интерфейс не определён. Выбрать внешний интерфейс отдельно.\n'
    fi
    section 'Сетевой стек и BTF'
    read_cmd sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control
    if [ -r /sys/kernel/btf/vmlinux ]; then
        printf 'BTF: доступен\n'
    else
        printf 'BTF: недоступен\n'
    fi
    section 'TCP-listeners'
    read_cmd ss -lntp
    section 'UDP-listeners только 443/8443'
    read_cmd ss -lnup '( sport = :443 or sport = :8443 )'
    section 'Контейнеры'
    read_cmd docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
    section 'Существующие службы'
    for unit in "$UMKA_UNIT" reshala-traffic-limiter.service multitest-cake.service; do
        read_cmd systemctl show -p Id -p LoadState -p ActiveState -p UnitFileState "$unit"
    done
    section 'Существующие файлы и ownership'
    for p in /opt/reshala /opt/umka-shaper /etc/umka-shaper \
        /var/lib/umka-shaper/tc-state.json /var/lib/umka-shaper/mq-owner.json \
        /sys/fs/bpf/umka_shaper; do
        if [ -e "$p" ] || [ -L "$p" ]; then
            printf 'Есть: %s\n' "$p"
        else
            printf 'Отсутствует: %s\n' "$p"
        fi
    done
    section 'Сохранённые настройки очередей'
    if command -v rg >/dev/null 2>&1; then
        rg -n --no-heading 'default_qdisc|tc[[:space:]]+qdisc' \
            /etc/sysctl.conf /etc/sysctl.d /etc/systemd/system \
            /etc/network /etc/rc.local 2>/dev/null | head -n 80 || true
    elif command -v grep >/dev/null 2>&1; then
        grep -RnsE 'default_qdisc|tc[[:space:]]+qdisc' \
            /etc/sysctl.conf /etc/sysctl.d /etc/systemd/system \
            /etc/network /etc/rc.local 2>/dev/null | head -n 80 || true
    fi
    section 'Диагностика завершена'
    printf 'Дополнительно нужны скорость канала по тарифу и VPN-порты.\n'
    printf 'При policy routing/reverse proxy выбор интерфейса и портов проверить отдельно.\n'
}

parse_node_args() {
    UMKA_IFACE=''
    UMKA_PORTS=''
    UMKA_PREPARE_ONLY=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --interface)
                [ "$#" -ge 2 ] && [ -n "$2" ] || die 'После --interface нужно имя.'
                UMKA_IFACE=$2; shift 2 ;;
            --ports)
                [ "$#" -ge 2 ] && [ -n "$2" ] || die 'После --ports нужен список.'
                UMKA_PORTS=$2; shift 2 ;;
            --prepare-only) UMKA_PREPARE_ONLY=1; shift ;;
            *) die "Неизвестный аргумент: $1" ;;
        esac
    done
}

validate_interface() {
    [[ "$UMKA_IFACE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || die 'Явно укажи --interface, например ens3.'
    [ "$UMKA_IFACE" != lo ] || die 'Loopback не подходит как внешний интерфейс.'
}

validate_target() {
    validate_interface
    [[ "$UMKA_PORTS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die 'Явно укажи --ports, например 443 или 443,8443.'
    command -v python3 >/dev/null 2>&1 || die 'Нужен python3. Сначала выполни check.'
    UMKA_PORTS=$(python3 - "$UMKA_PORTS" <<'PY'
import sys
ports=[int(s) for s in sys.argv[1].split(',')]
if not 1 <= len(ports) <= 32 or len(set(ports)) != len(ports) or any(not 1 <= p <= 65535 for p in ports):
    raise SystemExit('ERROR: нужны 1..32 разных порта в диапазоне 1..65535.')
print(','.join(map(str,ports)))
PY
    ) || die 'Недопустимый список портов.'
    export UMKA_IFACE UMKA_PORTS
}

assert_queue_services_free() {
    if systemctl is-active --quiet multitest-cake.service 2>/dev/null ||
       systemctl is-enabled --quiet multitest-cake.service 2>/dev/null; then
        die 'Конфликт с multitest-cake.service. Перед переходом на Umka отключи эту службу: systemctl disable --now multitest-cake.service'
    fi
    if systemctl is-active --quiet reshala-traffic-limiter.service 2>/dev/null ||
       systemctl is-enabled --quiet reshala-traffic-limiter.service 2>/dev/null; then
        die 'Штатный limiter Решалы активен или включён в автозапуск. Сначала устранить конфликт.'
    fi
}

validate_host() {
    [ "$(id -u)" -eq 0 ] || die 'Запусти install от root.'
    [ -r /etc/os-release ] || die 'Не найдена информация об ОС.'
    local ID='' VERSION_ID=''
    . /etc/os-release
    [ "$ID" = ubuntu ] && [ "$VERSION_ID" = 24.04 ] || die 'Эта версия install проверена для Ubuntu 24.04. Пришли check для другой ОС.'
    [ "$(uname -m)" = x86_64 ] || die 'Эта версия install рассчитана на x86_64.'
    [ -d /run/systemd/system ] || die 'Нужен сервер с работающим systemd.'
    local cmd p
    for cmd in apt-get python3 ip tc ss systemctl sysctl sha256sum base64 tar mktemp tee; do
        command -v "$cmd" >/dev/null 2>&1 || die "Нет команды $cmd. Сначала пришли check."
    done
    [ -d "/sys/class/net/$UMKA_IFACE" ] || die "Не найден интерфейс $UMKA_IFACE."
    [ -r /sys/kernel/btf/vmlinux ] || die 'Не найден BTF ядра. Сначала отдельный разбор.'
    python3 - <<'PY'
import platform
version=tuple(map(int,platform.release().split('-')[0].split('.')[:2]))
if version < (5,18):
    raise SystemExit('ERROR: требуется Linux 5.18 или новее.')
PY
    for p in /opt/umka-shaper /etc/umka-shaper \
        /etc/systemd/system/umka-traffic-shaper.service /usr/local/sbin/umka-shaper \
        /var/lib/umka-shaper/tc-state.json /var/lib/umka-shaper/mq-owner.json \
        /sys/fs/bpf/umka_shaper; do
        if [ -e "$p" ] || [ -L "$p" ]; then
            die "Уже существует $p. Повторный install запрещён; сначала разбор."
        fi
    done
    assert_queue_services_free
    if [ "$UMKA_PREPARE_ONLY" -eq 0 ]; then
        local port listeners
        local -a selected_ports
        IFS=',' read -r -a selected_ports <<< "$UMKA_PORTS"
        for port in "${selected_ports[@]}"; do
            listeners=$(ss -H -lnt "sport = :$port"; ss -H -lnu "sport = :$port")
            [ -n "$listeners" ] || die "Нет listener на порту $port. Для пустого сервера используй --prepare-only."
        done
        printf 'Listener найден. Его принадлежность VPN должна быть проверена по отчёту.\n'
    fi
}

cleanup_stage() {
    case "${umka_stage:-}" in
        /tmp/umka-node.*) rm -rf -- "$umka_stage" ;;
    esac
}

unpack_package() {
    umka_stage=$(mktemp -d /tmp/umka-node.XXXXXX)
    trap cleanup_stage EXIT
    umka_payload | base64 --decode > "$umka_stage/package.tar.gz"
    (
        cd "$umka_stage"
        printf '%s  %s\n' "$UMKA_PACKAGE_SHA256" package.tar.gz | sha256sum -c -
        tar -xzf package.tar.gz
        cd "$UMKA_PACKAGE_DIR"
        sha256sum -c SHA256SUMS
    )
    umka_source="$umka_stage/$UMKA_PACKAGE_DIR"
}

verify_existing_reshala() {
    if [ -e /opt/reshala ] || [ -L /opt/reshala ]; then
        [ -d /opt/reshala ] && [ ! -L /opt/reshala ] || die '/opt/reshala имеет неожиданную структуру.'
        python3 - "$umka_source" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from patch_engine import COMMIT,SOURCE_BLOBS,verify_blob
base=Path('/opt/reshala')
if not (base/'INSTALLED_COMMIT').is_file() or (base/'INSTALLED_COMMIT').read_text().strip()!=COMMIT:
    raise SystemExit('ERROR: существующая Решала не совпадает с закреплённой версией.')
for name in SOURCE_BLOBS:
    verify_blob(base/'modules/local'/name)
print('Pinned Reshala source: PASS')
PY
    fi
}

queue_preflight() {
    python3 - "$umka_source" "$UMKA_IFACE" <<'PY'
import sys
sys.path.insert(0,sys.argv[1])
import engine
plan=engine.plan_queues(engine.qdiscs(sys.argv[2]))
print('Queue preflight: PASS;',', '.join(r['kind'] for r in plan))
PY
}

install_node() {
    validate_host
    section 'Проверка встроенного пакета'
    unpack_package
    verify_existing_reshala
    queue_preflight
    section 'Исходный снимок'
    mkdir -p /var/backups/umka-shaper
    local backup_dir
    backup_dir=$(mktemp -d /var/backups/umka-shaper/before-node-install.XXXXXX)
    tc -j -d qdisc show dev "$UMKA_IFACE" > "$backup_dir/qdiscs.json"
    tc -s filter show dev "$UMKA_IFACE" ingress > "$backup_dir/filters-ingress.txt"
    tc -s filter show dev "$UMKA_IFACE" egress > "$backup_dir/filters-egress.txt"
    sysctl net.core.default_qdisc > "$backup_dir/default-qdisc.txt"
    uname -a > "$backup_dir/kernel.txt"
    printf 'Initial queue backup: %s\n' "$backup_dir"
    printf 'Interface: %s; ports: %s\n' "$UMKA_IFACE" "$UMKA_PORTS"
    section 'Зависимости'
    apt-get update
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=300 install -y \
        ca-certificates curl tar python3 iproute2 jq bc sudo \
        clang llvm libbpf-dev build-essential kmod linux-tools-common linux-tools-generic
    if [ ! -e /opt/reshala ] && [ ! -L /opt/reshala ]; then
        mkdir "$umka_stage/reshala-source"
        curl --fail --location --retry 3 \
            --output "$umka_stage/reshala.tar.gz" \
            "https://github.com/DonMatteoVPN/Reshala-Remnawave-Bedolaga/archive/${UMKA_COMMIT}.tar.gz"
        tar -xzf "$umka_stage/reshala.tar.gz" -C "$umka_stage/reshala-source" --strip-components=1
        RESHALA_NO_AUTOSTART=1 bash "$umka_stage/reshala-source/reshala.sh" install
        printf '%s\n' "$UMKA_COMMIT" > /opt/reshala/INSTALLED_COMMIT
    fi
    verify_existing_reshala
    section 'Сборка, тесты и verifier ядра'
    python3 "$umka_source/install.py" --interface "$UMKA_IFACE" --ports "$UMKA_PORTS"
    if [ "$UMKA_PREPARE_ONLY" -eq 1 ]; then
        printf '\nPREPARED: шейпер установлен без hooks и без автозапуска.\n'
        printf 'После запуска VPN повтори: bash umka-shaper.sh\n'
        return 0
    fi
    activate_shaper
    printf '\nInitial queue backup: %s\n' "$backup_dir"
}

record_check() {
    local report_dir report
    report_dir=$(pwd -P)
    if [ "$(id -u)" -eq 0 ]; then report_dir=/root; fi
    report=$(mktemp "$report_dir/umka-shaper-check.XXXXXX.txt")
    printf 'Отчёт: %s\n' "$report"
    check_host 2>&1 | tee "$report"
    printf '\nОтчёт сохранён: %s\n' "$report"
}

install_selected() {
    local report
    report=$(mktemp /root/umka-shaper-install.XXXXXX.log)
    printf 'Лог установки: %s\n' "$report"
    install_node 2>&1 | tee "$report"
    printf '\nЛог сохранён: %s\n' "$report"
}

show_active_shaper() {
    systemctl is-active --quiet "$UMKA_UNIT" || die 'Служба Umka не активна.'
    /usr/local/sbin/umka-shaper status
    local qdiscs ingress egress
    qdiscs=$(tc qdisc show dev "$UMKA_IFACE")
    ingress=$(tc -s filter show dev "$UMKA_IFACE" ingress)
    egress=$(tc -s filter show dev "$UMKA_IFACE" egress)
    printf '%s\n%s\n%s\n' "$qdiscs" "$ingress" "$egress"
    [[ "$ingress" == *umka_up* && "$egress" == *umka_down* ]] ||
        die 'Служба активна, но не найдены оба BPF-фильтра Umka.'
    if ! awk '
        $1 == "qdisc" && $4 == "root" { root = $2 }
        $1 == "qdisc" && $4 == "parent" && $2 != "clsact" {
            leaves++
            if ($2 != "fq") bad = 1
        }
        END { exit !(root == "fq" || (root == "mq" && leaves && !bad)) }
    ' <<< "$qdiscs"; then
        die 'Фильтры есть, но активная очередь отличается от ожидаемой fq.'
    fi
}

activate_shaper() {
    assert_queue_services_free
    section 'Запуск Umka'
    if ! systemctl start "$UMKA_UNIT"; then
        journalctl -u "$UMKA_UNIT" -b -n 60 --no-pager -o cat || true
        die 'Служба не запустилась. Проверь журнал перед повторным запуском.'
    fi
    show_active_shaper
    systemctl enable "$UMKA_UNIT"
    printf 'Автозапуск включён. Фактический лимит проверяется VPN-трафиком.\n'
}

discover_interface() {
    local v4 v6 interfaces
    v4=$(ip -o -4 route show default) || die 'Не удалось прочитать маршруты IPv4.'
    v6=$(ip -o -6 route show default) || die 'Не удалось прочитать маршруты IPv6.'
    interfaces=$(printf '%s\n%s\n' "$v4" "$v6" | awk '
        { for (i = 1; i < NF; i++) if ($i == "dev" && !seen[$(i+1)]++) print $(i+1) }
    ')
    [[ -n "$interfaces" && "$interfaces" != *$'\n'* ]] ||
        die 'Маршруты не указывают на один интерфейс. Укажи --interface.'
    printf '%s\n' "$interfaces"
}

listener_rows() {
    local iface=$1 addresses sockets
    addresses=$(ip -o addr show dev "$iface" scope global) || return 1
    sockets=$(ss -H -lntup) || return 1
    awk -v addresses="$addresses" -v iface="$iface" '
        BEGIN {
            n = split(addresses, rows, "\n")
            for (i = 1; i <= n; i++) {
                split(rows[i], fields, /[[:space:]]+/)
                split(fields[4], ip, "/")
                if (ip[1] != "") local_ip[tolower(ip[1])] = 1
            }
        }
        $1 ~ /^(tcp|udp)$/ && $5 ~ /:[0-9]+$/ {
            address = $5
            sub(/:[0-9]+$/, "", address)
            gsub(/^\[|\]$/, "", address)
            n = split(address, scoped, "%")
            if (n > 1 && scoped[2] != iface) next
            address = tolower(scoped[1])
            sub(/^::ffff:/, "", address)
            if (address != "*" && address != "0.0.0.0" && address != "::" && !(address in local_ip)) next
            port = $5
            sub(/^.*:/, "", port)
            owners = $0
            known = gsub(/\("(rw-core|xray)",pid=/, "", owners)
            if (known) vpn[port] = 1
            if (!known || owners ~ /\("[^"]+",pid=/) other[port] = 1
            seen[port] = 1
        }
        END {
            for (p in seen) print p, (vpn[p] ? (other[p] ? "mixed" : "vpn") : "other")
        }
    ' <<< "$sockets" | sort -n
}

saved_target() {
    python3 - "$UMKA_CONFIG" "$UMKA_COMMIT" <<'PY'
import json
import re
import sys
from pathlib import Path

try:
    cfg = json.loads(Path(sys.argv[1]).read_text())
    iface = cfg["interface"]
    ports = cfg["ports"]
    policy = {
        "threshold_mbps": 100, "hold_seconds": 600,
        "penalty_mbps": 30, "penalty_seconds": 2400,
    }
    if (
        cfg.get("policy_version") != "umka-timed-v1"
        or cfg.get("upstream_commit") != sys.argv[2]
        or any(type(cfg.get(key)) is not int or cfg[key] != value for key, value in policy.items())
        or not isinstance(iface, str)
        or not re.fullmatch(r"[a-zA-Z0-9_.:-]{1,15}", iface)
        or not isinstance(ports, list)
        or not 1 <= len(ports) <= 32
        or any(type(p) is not int or not 1 <= p <= 65535 for p in ports)
        or len(set(ports)) != len(ports)
    ):
        raise ValueError
except (OSError, ValueError, TypeError, KeyError):
    sys.exit(1)
print(iface, ",".join(map(str, ports)))
PY
}

auto_node() {
    [ "$(id -u)" -eq 0 ] || die 'Запусти auto от root.'
    parse_node_args "$@"
    local cmd
    for cmd in ip ss systemctl python3; do
        command -v "$cmd" >/dev/null 2>&1 || die "Нет команды $cmd. Запусти check для диагностики."
    done
    record_check
    local installed=0 load_state saved saved_iface saved_ports explicit_ports=0
    [ -z "$UMKA_PORTS" ] || explicit_ports=1
    if ! load_state=$(systemctl show -p LoadState --value "$UMKA_UNIT"); then
        [ "$load_state" = not-found ] || die 'Не удалось прочитать состояние systemd.'
    fi
    case "$load_state" in
        loaded)
            installed=1
            saved=$(saved_target) || die 'Существующая конфигурация Umka не соответствует стандартной политике или не читается. Запусти check.'
            read -r saved_iface saved_ports <<< "$saved"
            UMKA_IFACE=${UMKA_IFACE:-$saved_iface}
            UMKA_PORTS=${UMKA_PORTS:-$saved_ports}
            validate_target
            [[ "$UMKA_IFACE" == "$saved_iface" && "$UMKA_PORTS" == "$saved_ports" ]] ||
                die 'Интерфейс или порты отличаются от существующей конфигурации Umka.'
            if systemctl is-active --quiet "$UMKA_UNIT"; then
                show_active_shaper
                return
            fi
            if systemctl is-failed --quiet "$UMKA_UNIT"; then
                die "Предыдущий запуск завершился ошибкой: journalctl -u $UMKA_UNIT -n 60 --no-pager"
            fi
            ;;
        not-found)
            if [ -z "$UMKA_IFACE" ]; then UMKA_IFACE=$(discover_interface); fi
            ;;
        *) die "Состояние службы $UMKA_UNIT: $load_state. Запусти check." ;;
    esac

    assert_queue_services_free
    validate_interface
    local listeners found port kind
    listeners=$(listener_rows "$UMKA_IFACE") || die 'Не удалось прочитать слушающие порты.'
    if [ -z "$UMKA_PORTS" ]; then
        found=$(awk '$2 == "vpn" { print $1 }' <<< "$listeners")
        if [[ "$found" == *$'\n'* ]] || awk '$2 == "mixed" { found=1 } END { exit !found }' <<< "$listeners"; then
            die 'Обнаружено несколько VPN-портов или разные владельцы сокетов. Укажи --ports.'
        fi
        if [ -z "$found" ] && awk '$1 == 443 { found=1 } END { exit !found }' <<< "$listeners"; then
            die 'Порт 443 занят другим процессом. Если это вход VPN через прокси, укажи --ports явно.'
        fi
        UMKA_PORTS=${found:-443}
    fi
    validate_target

    local -a ports
    IFS=',' read -r -a ports <<< "$UMKA_PORTS"
    for port in "${ports[@]}"; do
        kind=$(awk -v port="$port" '$1 == port { print $2 }' <<< "$listeners")
        if [ "$explicit_ports" -eq 0 ] && [[ "$kind" == other || "$kind" == mixed ]]; then
            die "Порт $port не удалось однозначно связать с VPN. Укажи --ports явно."
        fi
        [ -n "$kind" ] || UMKA_PREPARE_ONLY=1
    done
    printf '\nВыбран интерфейс %s, порты %s.\n' "$UMKA_IFACE" "$UMKA_PORTS"
    if [ "$installed" -eq 0 ]; then
        install_selected
    elif [ "$UMKA_PREPARE_ONLY" -eq 1 ]; then
        printf 'PREPARED: пакет уже готов. После запуска VPN повтори команду.\n'
    else
        activate_shaper
    fi
}

repair_existing_fq() {
    [ -f /opt/umka-shaper/engine.py ] && [ ! -L /opt/umka-shaper/engine.py ] || die 'Не найден обычный файл установленного engine.py.'
    [ -x /usr/local/sbin/umka-shaper ] && [ -f /etc/systemd/system/umka-traffic-shaper.service ] || die 'Не найдена полная установка шейпера.'
    unpack_package
    python3 - "$umka_source/engine.py" <<'PY'
import fcntl,hashlib,os,shutil,stat,sys,tempfile
from pathlib import Path
replacement=Path(sys.argv[1]).read_bytes()
compile(replacement,'/opt/umka-shaper/engine.py','exec')
target=Path('/opt/umka-shaper/engine.py')
old_hash='025fb7cdee082c46a6344d2f48144cf8706a6d9d574adf43dc5dc990be788497'
new_hash=hashlib.sha256(replacement).hexdigest()
lock_dir=Path('/run/umka-shaper')
lock_dir.mkdir(mode=0o700,exist_ok=True)
with (lock_dir/'engine.lock').open('a') as lock:
    try:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit('ERROR: менеджер занят; повтори repair-fq после завершения команды.')
    original=target.read_bytes()
    digest=hashlib.sha256(original).hexdigest()
    if digest==new_hash:
        print('FQ boot fix is already installed. No restart performed.')
        raise SystemExit(0)
    if digest!=old_hash:
        raise SystemExit('ERROR: engine.py отличается от ожидаемой версии; изменения не внесены.')
    backup=target.with_name('engine.py.before-fq-boot-fix-20261026')
    if backup.exists() or backup.is_symlink():
        if backup.is_symlink() or hashlib.sha256(backup.read_bytes()).hexdigest()!=old_hash:
            raise SystemExit('ERROR: существующая резервная копия требует разбора.')
    else:
        shutil.copy2(target,backup)
    info=target.stat()
    temp_path=None
    try:
        with tempfile.NamedTemporaryFile(prefix='.engine-fqfix-',dir=target.parent,delete=False) as temp:
            temp_path=Path(temp.name)
            temp.write(replacement)
            temp.flush()
            os.fchmod(temp.fileno(),stat.S_IMODE(info.st_mode))
            os.fchown(temp.fileno(),info.st_uid,info.st_gid)
            os.fsync(temp.fileno())
        temp_path.replace(target)
    finally:
        if temp_path is not None:temp_path.unlink(missing_ok=True)
    print('FQ boot fix installed. No service/network restart performed.')
    print('Backup:',backup)
    print('Engine SHA256:',new_hash)
PY
    /usr/local/sbin/umka-shaper status
}


main() {
    local action=${1:-auto} report
    case "$action" in
        --interface|--ports|--prepare-only) action=auto ;;
        *) if [ "$#" -gt 0 ]; then shift; fi ;;
    esac
    case "$action" in
        auto) auto_node "$@" ;;
        help|-h|--help) help_text ;;
        check)
            [ "$#" -eq 0 ] || die 'У check нет дополнительных аргументов.'
            record_check
            ;;
        install)
            parse_node_args "$@"
            validate_target
            [ "$(id -u)" -eq 0 ] || die 'Запусти install от root.'
            install_selected
            ;;
        repair-fq)
            [ "$#" -eq 0 ] || die 'У repair-fq нет дополнительных аргументов.'
            [ "$(id -u)" -eq 0 ] || die 'Запусти repair-fq от root.'
            report=$(mktemp /root/umka-shaper-fq-fix.XXXXXX.log)
            printf 'Лог исправления: %s\n' "$report"
            repair_existing_fq 2>&1 | tee "$report"
            printf '\nЛог сохранён: %s\n' "$report"
            ;;
        *) die 'Команды: auto, check, install, repair-fq, help.' ;;
    esac
}

umka_payload() {
    cat <<'UMKA_EMBEDDED_PACKAGE_BASE64'
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
UMKA_EMBEDDED_PACKAGE_BASE64
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
