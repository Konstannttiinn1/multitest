#!/bin/bash

# ============================================================
#  Multitest — интерактивный скрипт диагностики сервера
# ============================================================

SCRIPT_VERSION="1.4"
REPO_URL="https://raw.githubusercontent.com/Konstannttiinn1/multitest/master/multitest.sh"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
#  Установка (--install)
# ============================================================

if [[ "${1:-}" == "--version" ]]; then
    echo "Multitest ${SCRIPT_VERSION}"
    exit 0
fi

if [[ "${1:-}" == "--install" ]]; then
    echo -e "${CYAN}Установка multitest...${NC}"
    INSTALL_PATH="/usr/local/bin/multitest"
    TMP_FILE=$(mktemp)

    if command -v curl &>/dev/null; then
        curl -sL "$REPO_URL" -o "$TMP_FILE"
    elif command -v wget &>/dev/null; then
        wget -qO "$TMP_FILE" "$REPO_URL"
    else
        echo -e "${RED}Нужен curl или wget для установки.${NC}"
        exit 1
    fi

    # Проверяем что скачался именно скрипт, а не страница ошибки
    if head -1 "$TMP_FILE" 2>/dev/null | grep -q "^#!/bin/bash"; then
        mv "$TMP_FILE" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo -e "${GREEN}Установлено в ${INSTALL_PATH}${NC}"
        echo -e "${GREEN}Теперь можно запускать командой: ${BOLD}multitest${NC}"
    else
        rm -f "$TMP_FILE"
        echo -e "${RED}Ошибка: загрузка не удалась (CDN кэш). Установите напрямую:${NC}"
        echo ""
        echo "  curl -sL $REPO_URL -o /usr/local/bin/multitest && chmod +x /usr/local/bin/multitest"
        echo ""
    fi
    exit 0
fi

# ============================================================
#  Интерфейс
# ============================================================

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║          MULTITEST v${SCRIPT_VERSION}                  ║"
    echo "  ║   Диагностика и тестирование сервера     ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_separator() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  >>> $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

pause_prompt() {
    echo ""
    echo -e "${YELLOW}Нажмите Enter для возврата в меню...${NC}"
    read -r
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Эта операция требует прав root.${NC}"
        echo -e "${YELLOW}Запустите: sudo multitest${NC}"
        return 1
    fi
}

# ============================================================
#  Установка зависимостей
# ============================================================

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v apk &>/dev/null; then
        echo "apk"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

install_package() {
    local pkg="$1"
    local pm
    pm=$(detect_pkg_manager)

    echo -e "${YELLOW}Устанавливаю ${pkg}...${NC}"

    case "$pm" in
        apt)     DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" ;;
        dnf)     dnf install -y -q "$pkg" ;;
        yum)     yum install -y -q "$pkg" ;;
        apk)     apk add --quiet "$pkg" ;;
        pacman)  pacman -S --noconfirm --quiet "$pkg" ;;
        *)
            echo -e "${RED}Не удалось определить пакетный менеджер. Установите ${pkg} вручную.${NC}"
            return 1
            ;;
    esac
}

check_and_install() {
    local cmd="$1"
    local pkg="${2:-$1}"

    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${YELLOW}${cmd} не найден.${NC}"
        install_package "$pkg"
        if command -v "$cmd" &>/dev/null; then
            echo -e "${GREEN}${cmd} успешно установлен.${NC}"
        else
            echo -e "${RED}Не удалось установить ${cmd}.${NC}"
            return 1
        fi
    fi
    return 0
}

install_deps() {
    echo -e "${CYAN}Проверка зависимостей...${NC}"
    check_and_install curl
    check_and_install wget
    check_and_install sysbench
    check_and_install iperf3
    echo -e "${GREEN}Все зависимости в порядке.${NC}"
    echo ""
}

install_iproute() {
    local pm
    pm=$(detect_pkg_manager)

    case "$pm" in
        dnf|yum) install_package iproute ;;
        *)       install_package iproute2 ;;
    esac
}

# ============================================================
#  Функции тестов
# ============================================================

run_ip_region() {
    print_separator "IP Region"
    check_and_install wget
    bash <(wget -qO- https://ipregion.vrnt.xyz)
}

run_censorcheck_geoblock() {
    print_separator "Censorcheck — проверка геоблока"
    check_and_install wget
    bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode geoblock
}

run_censorcheck_dpi() {
    print_separator "Censorcheck — DPI (серверы РФ)"
    check_and_install wget
    bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode dpi
}

run_iperf3_ru() {
    print_separator "iPerf3 — тест до российских серверов"
    check_and_install wget
    check_and_install iperf3
    bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh)
}

run_iperf3_tlab() {
    print_separator "iPerf3 — bench.tlab.pw (РФ)"
    check_and_install wget
    check_and_install iperf3
    wget -qO- bench.tlab.pw | bash
}

run_yabs() {
    print_separator "YABS — бенчмарк сервера"
    check_and_install curl
    curl -sL yabs.sh | bash -s -- -4
}

run_ip_check_place() {
    print_separator "IP Check Place — блокировки зарубежными сервисами"
    check_and_install curl
    bash <(curl -Ls IP.Check.Place) -l en
}

run_bench_sh() {
    print_separator "bench.sh — параметры сервера и скорость"
    check_and_install wget
    wget -qO- bench.sh | bash
}

run_ip_quality() {
    print_separator "IPQuality"
    check_and_install curl
    bash <(curl -Ls https://Check.Place) -EI
}

run_sysbench_cpu() {
    print_separator "sysbench CPU — тест процессора"
    check_and_install sysbench
    sysbench cpu run --threads=1
}

MULTITEST_SKIPPED=0

multitest_skip_handler() {
    MULTITEST_SKIPPED=1
}

run_all() {
    print_separator "МУЛЬТИТЕСТ — запуск всех тестов"
    echo -e "  ${YELLOW}Ctrl+C${NC} во время теста — пропустить текущий"
    echo -e "  Между тестами: ${GREEN}Enter${NC} — продолжить | ${YELLOW}s${NC} — пропустить | ${RED}q${NC} — выход"
    echo ""
    install_deps

    local test_funcs=(
        "run_ip_region"
        "run_censorcheck_geoblock"
        "run_censorcheck_dpi"
        "run_iperf3_ru"
        "run_iperf3_tlab"
        "run_yabs"
        "run_ip_check_place"
        "run_bench_sh"
        "run_ip_quality"
        "run_sysbench_cpu"
    )
    local test_names=(
        "IP Region"
        "Censorcheck — проверка геоблока"
        "Censorcheck — DPI (серверы РФ)"
        "iPerf3 — тест до российских серверов"
        "iPerf3 — bench.tlab.pw (РФ)"
        "YABS — бенчмарк сервера"
        "IP Check Place — блокировки зарубежными сервисами"
        "bench.sh — параметры сервера и скорость"
        "IPQuality"
        "sysbench CPU — тест процессора"
    )

    local total=${#test_funcs[@]}

    for i in $(seq 0 $((total - 1))); do
        local num=$((i + 1))
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${CYAN}[${num}/${total}]${NC} Следующий: ${BOLD}${test_names[$i]}${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -ne "  ${BOLD}Enter${NC} — запустить | ${YELLOW}s${NC} — пропустить | ${RED}q${NC} — выход: "
        read -r action

        case "$action" in
            s|S)
                echo -e "  ${YELLOW}Пропущено.${NC}"
                continue
                ;;
            q|Q)
                echo -e "\n${GREEN}Мультитест прерван. Выполнено тестов: $((num - 1))/${total}${NC}"
                return
                ;;
        esac

        sleep 2

        # Запуск теста в подоболочке, Ctrl+C убивает только тест
        MULTITEST_SKIPPED=0
        trap multitest_skip_handler INT
        ( ${test_funcs[$i]} )
        trap - INT

        if [[ $MULTITEST_SKIPPED -eq 1 ]]; then
            echo ""
            echo -e "  ${YELLOW}Тест пропущен (Ctrl+C).${NC}"
        fi

        sleep 2
    done

    echo ""
    echo -e "${GREEN}${BOLD}Все тесты завершены! (${total}/${total})${NC}"
}

# ============================================================
#  Утилиты
# ============================================================

detect_network_interfaces() {
    if [[ -n "${MULTITEST_NET_IFACE:-}" ]]; then
        printf '%s\n' "$MULTITEST_NET_IFACE"
        return
    fi

    {
        ip -o -4 route show default 2>/dev/null
        ip -o -6 route show default 2>/dev/null
    } | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) {
                    print $(i + 1)
                }
            }
        }
    ' | awk '!seen[$0]++'
}

cake_is_active_on_interface() {
    local iface="$1"

    tc qdisc show dev "$iface" 2>/dev/null | awk '
        $1 == "qdisc" && $2 == "cake" {
            for (i = 3; i <= NF; i++) {
                if ($i == "root") {
                    found = 1
                }
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

install_cake_persistence_service() {
    if ! command -v systemctl &>/dev/null || [[ ! -d /run/systemd/system ]]; then
        echo -e "${YELLOW}systemd не найден: CAKE применён сейчас, но автопроверка после перезагрузки не настроена.${NC}"
        return 0
    fi

    cat > /usr/local/sbin/multitest-apply-cake <<'EOF'
#!/bin/sh
set -eu

interfaces=""
attempt=1
while [ "$attempt" -le 30 ]; do
    interfaces=$(
        {
            ip -o -4 route show default 2>/dev/null || true
            ip -o -6 route show default 2>/dev/null || true
        } | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "dev" && (i + 1) <= NF) {
                        print $(i + 1)
                    }
                }
            }
        ' | awk '!seen[$0]++'
    )

    [ -n "$interfaces" ] && break
    sleep 1
    attempt=$((attempt + 1))
done

if [ -z "$interfaces" ]; then
    echo "Не найден сетевой интерфейс с маршрутом по умолчанию" >&2
    exit 1
fi

modprobe sch_cake 2>/dev/null || true

applied=0
for iface in $interfaces; do
    [ -d "/sys/class/net/$iface" ] || continue
    tc qdisc replace dev "$iface" root cake triple-isolate
    tc qdisc show dev "$iface" | awk '
        $1 == "qdisc" && $2 == "cake" {
            for (i = 3; i <= NF; i++) {
                if ($i == "root") {
                    found = 1
                }
            }
        }
        END { exit(found ? 0 : 1) }
    '
    applied=1
done

[ "$applied" -eq 1 ]
EOF
    chmod 0755 /usr/local/sbin/multitest-apply-cake

    cat > /etc/systemd/system/multitest-cake.service <<'EOF'
[Unit]
Description=Apply CAKE qdisc to default-route network interfaces
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/multitest-apply-cake
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if ! systemctl enable multitest-cake.service >/dev/null; then
        echo -e "${YELLOW}Не удалось включить автозапуск multitest-cake.service.${NC}"
        return 1
    fi

    if ! systemctl restart multitest-cake.service; then
        echo -e "${YELLOW}Сервис автоприменения CAKE не прошёл проверочный запуск.${NC}"
        systemctl --no-pager --full status multitest-cake.service 2>/dev/null || true
        return 1
    fi

    echo -e "${GREEN}Автоприменение CAKE после перезагрузки настроено и проверено.${NC}"
}

show_bbr_cake_status() {
    local current_cc current_qdisc available_cc interfaces iface
    local cake_ok=1

    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "неизвестно")
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "неизвестно")

    echo -e "${BOLD}BBR${NC}"
    echo -e "  Активный алгоритм:       ${BOLD}${current_cc}${NC}"
    echo -e "  Доступные алгоритмы:     ${available_cc}"

    if [[ "$current_cc" == "bbr" && " $available_cc " == *" bbr "* ]]; then
        echo -e "  Статус BBR:              ${GREEN}АКТИВЕН${NC}"
    else
        echo -e "  Статус BBR:              ${RED}НЕ АКТИВЕН${NC}"
    fi

    echo ""
    echo -e "${BOLD}CAKE${NC}"
    echo -e "  qdisc по умолчанию:      ${BOLD}${current_qdisc}${NC}"

    interfaces=$(detect_network_interfaces)
    if [[ -z "$interfaces" ]]; then
        echo -e "  Интерфейс:               ${RED}не найден${NC}"
        cake_ok=0
    else
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            if cake_is_active_on_interface "$iface"; then
                echo -e "  Интерфейс ${BOLD}${iface}${NC}:          ${GREEN}CAKE АКТИВЕН${NC}"
                echo -e "    $(tc qdisc show dev "$iface" 2>/dev/null | head -n 1)"
            else
                echo -e "  Интерфейс ${BOLD}${iface}${NC}:          ${RED}CAKE НЕ АКТИВЕН${NC}"
                echo -e "    $(tc qdisc show dev "$iface" 2>/dev/null | head -n 1)"
                cake_ok=0
            fi
        done <<< "$interfaces"
    fi

    if [[ "$current_qdisc" == "cake" && $cake_ok -eq 1 ]]; then
        echo -e "  Итоговый статус CAKE:    ${GREEN}АКТИВЕН${NC}"
    else
        echo -e "  Итоговый статус CAKE:    ${RED}НЕ АКТИВЕН${NC}"
    fi

    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        if systemctl is-enabled --quiet multitest-cake.service 2>/dev/null && systemctl is-active --quiet multitest-cake.service 2>/dev/null; then
            echo -e "  После перезагрузки:      ${GREEN}НАСТРОЕНО${NC}"
        else
            echo -e "  После перезагрузки:      ${YELLOW}НЕ ПОДТВЕРЖДЕНО${NC}"
        fi
    fi
}

prompt_reboot_after_cake() {
    local answer

    echo ""
    echo -e "${YELLOW}CAKE уже применён. Перезагрузка нужна для контрольной проверки автозапуска.${NC}"
    echo -ne "${BOLD}Перезагрузить сервер сейчас? [y/N]: ${NC}"
    read -r answer

    case "${answer,,}" in
        y|yes|д|да)
            echo -e "${YELLOW}Сервер перезагружается. SSH-соединение сейчас закроется.${NC}"
            if command -v systemctl &>/dev/null; then
                systemctl reboot
            elif command -v reboot &>/dev/null; then
                reboot
            else
                echo -e "${RED}Команда перезагрузки не найдена. Выполните reboot вручную.${NC}"
                return 1
            fi
            ;;
        *)
            echo -e "${GREEN}Перезагрузка пропущена. Позже выполните reboot и проверьте статус через пункт 12 → 4.${NC}"
            ;;
    esac
}

enable_bbr_cake() {
    print_separator "Включение BBR + Cake"

    require_root || return 1

    if ! command -v ip &>/dev/null || ! command -v tc &>/dev/null; then
        echo -e "${YELLOW}ip/tc не найдены, устанавливаю пакет сетевых утилит...${NC}"
        install_iproute || return 1
    fi

    if ! command -v modprobe &>/dev/null; then
        check_and_install modprobe kmod || return 1
    fi

    local interfaces iface
    local apply_failed=0

    interfaces=$(detect_network_interfaces)
    if [[ -z "$interfaces" ]]; then
        echo -e "${RED}Не найден сетевой интерфейс с маршрутом по умолчанию.${NC}"
        return 1
    fi

    echo -e "Обнаруженные интерфейсы: ${BOLD}$(echo "$interfaces" | paste -sd ', ' -)${NC}"
    echo ""

    if ! modprobe tcp_bbr 2>/dev/null; then
        echo -e "${YELLOW}Не удалось загрузить tcp_bbr как модуль. Возможно, BBR встроен в ядро; проверка продолжится.${NC}"
    fi
    if ! modprobe sch_cake 2>/dev/null; then
        echo -e "${YELLOW}Не удалось загрузить sch_cake как модуль. Возможно, CAKE встроен в ядро; проверка продолжится.${NC}"
    fi

    # Имя zz-* важно: файл должен загружаться после стандартного
    # 99-sysctl.conf, который у некоторых VPS возвращает qdisc=fq.
    cat > /etc/sysctl.d/zz-multitest-bbr-cake.conf <<EOF
net.core.default_qdisc=cake
net.ipv4.tcp_congestion_control=bbr
EOF

    if ! sysctl -p /etc/sysctl.d/zz-multitest-bbr-cake.conf; then
        echo -e "${RED}Не удалось применить настройки BBR/CAKE через sysctl.${NC}"
        return 1
    fi

    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        echo -e "Применяю CAKE к интерфейсу ${BOLD}${iface}${NC}..."
        if ! tc qdisc replace dev "$iface" root cake triple-isolate; then
            echo -e "${RED}Не удалось применить CAKE к ${iface}.${NC}"
            apply_failed=1
        fi
    done <<< "$interfaces"

    if ! install_cake_persistence_service; then
        echo -e "${YELLOW}CAKE будет проверен сейчас, но сохранение после перезагрузки не подтверждено.${NC}"
    fi

    echo ""
    show_bbr_cake_status

    local new_cc new_qdisc available_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)

    if [[ "$new_cc" == "bbr" && "$new_qdisc" == "cake" && " $available_cc " == *" bbr "* && $apply_failed -eq 0 ]]; then
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            cake_is_active_on_interface "$iface" || apply_failed=1
        done <<< "$interfaces"
    else
        apply_failed=1
    fi

    echo ""
    if [[ $apply_failed -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}BBR и CAKE действительно активированы.${NC}"
        prompt_reboot_after_cake
    else
        echo -e "${RED}${BOLD}Активация не подтверждена. Красный статус выше показывает причину.${NC}"
        return 1
    fi
}

detect_sshd_ports() {
    local ports

    ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | awk '!seen[$0]++' | paste -sd ',' -)
    printf '%s\n' "${ports:-ssh}"
}

install_fail2ban() {
    print_separator "Установка и настройка Fail2Ban"

    require_root || return 1

    if ! command -v fail2ban-client &>/dev/null; then
        install_package fail2ban || return 1
    fi

    local ssh_ports backend
    ssh_ports=$(detect_sshd_ports)
    backend="auto"
    if command -v journalctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        backend="systemd"
    fi

    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/sshd-multitest.local <<EOF
# Managed by Multitest. Re-running the utility updates these values.
[sshd]
enabled = true
port = ${ssh_ports}
filter = sshd
backend = ${backend}
maxretry = 5
findtime = 600
bantime = 43200
EOF

    echo -e "SSH-порт(ы):          ${BOLD}${ssh_ports}${NC}"
    echo -e "Неудачных попыток:    ${BOLD}5${NC}"
    echo -e "Окно подсчёта:        ${BOLD}10 минут${NC}"
    echo -e "Срок блокировки IP:   ${BOLD}12 часов${NC}"
    echo ""

    if ! fail2ban-client -t; then
        echo -e "${RED}Конфигурация Fail2Ban не прошла проверку. Сервис не перезапущен.${NC}"
        return 1
    fi

    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        systemctl enable --now fail2ban
        systemctl restart fail2ban
    elif command -v rc-update &>/dev/null && command -v rc-service &>/dev/null; then
        rc-update add fail2ban default 2>/dev/null || true
        rc-service fail2ban restart
    elif command -v service &>/dev/null; then
        service fail2ban restart
    else
        echo -e "${RED}Не удалось определить систему запуска служб.${NC}"
        return 1
    fi

    sleep 1
    if fail2ban-client status sshd &>/dev/null; then
        echo -e "${GREEN}${BOLD}Fail2Ban установлен, jail sshd активен.${NC}"
        fail2ban-client status sshd
    else
        echo -e "${RED}${BOLD}Fail2Ban установлен, но jail sshd не активен.${NC}"
        return 1
    fi
}

show_fail2ban_status() {
    echo -e "${BOLD}Fail2Ban${NC}"

    if ! command -v fail2ban-client &>/dev/null; then
        echo -e "  Статус:                 ${RED}НЕ УСТАНОВЛЕН${NC}"
        return
    fi

    if ! fail2ban-client ping 2>/dev/null | grep -q "pong"; then
        echo -e "  Сервис:                 ${RED}НЕ АКТИВЕН${NC}"
        return
    fi

    if ! fail2ban-client status sshd &>/dev/null; then
        echo -e "  Сервис:                 ${GREEN}АКТИВЕН${NC}"
        echo -e "  Jail sshd:              ${RED}НЕ АКТИВЕН${NC}"
        return
    fi

    echo -e "  Сервис:                 ${GREEN}АКТИВЕН${NC}"
    echo -e "  Jail sshd:              ${GREEN}АКТИВЕН${NC}"
    echo -e "  Максимум попыток:       $(fail2ban-client get sshd maxretry 2>/dev/null || echo '?')"
    echo -e "  Окно подсчёта, секунд:  $(fail2ban-client get sshd findtime 2>/dev/null || echo '?')"
    echo -e "  Бан, секунд:            $(fail2ban-client get sshd bantime 2>/dev/null || echo '?')"
    fail2ban-client status sshd 2>/dev/null | sed 's/^/  /'
}

show_utilities_status() {
    print_separator "Статус BBR, CAKE и Fail2Ban"

    if ! command -v ip &>/dev/null || ! command -v tc &>/dev/null; then
        echo -e "${RED}ip/tc не установлены — статус CAKE проверить невозможно.${NC}"
    else
        show_bbr_cake_status
    fi

    echo ""
    show_fail2ban_status
}

disable_ipv6() {
    print_separator "Выключение IPv6"

    require_root || return 1

    # Проверяем текущее состояние
    local current_state
    current_state=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)

    if [[ "$current_state" == "1" ]]; then
        echo -e "${YELLOW}IPv6 уже выключен.${NC}"
        return
    fi

    echo -e "Текущий статус IPv6: ${BOLD}включён${NC}"
    echo ""

    # Записываем параметры в sysctl
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf

    # Проверяем результат
    local new_state
    new_state=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)

    echo ""
    if [[ "$new_state" == "1" ]]; then
        echo -e "${GREEN}IPv6 успешно выключен!${NC}"
    else
        echo -e "${RED}Не удалось выключить IPv6.${NC}"
    fi
}

show_utilities_menu() {
    while true; do
        print_header
        echo -e "  ${CYAN}${BOLD}── Утилиты ──${NC}"
        echo ""
        echo -e "  ${GREEN}1)${NC}  Включить BBR + Cake"
        echo -e "  ${GREEN}2)${NC}  Выключить IPv6"
        echo -e "  ${GREEN}3)${NC}  Установить и настроить Fail2Ban"
        echo -e "  ${GREEN}4)${NC}  Статус BBR, Cake и Fail2Ban"
        echo ""
        echo -e "  ${RED}0)${NC}  Назад"
        echo ""
        echo -ne "  ${BOLD}Выберите пункт [0-4]: ${NC}"
        read -r util_choice

        case "$util_choice" in
            1) enable_bbr_cake; pause_prompt ;;
            2) disable_ipv6; pause_prompt ;;
            3) install_fail2ban; pause_prompt ;;
            4) show_utilities_status; pause_prompt ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; pause_prompt ;;
        esac
    done
}

# ============================================================
#  Главное меню
# ============================================================

show_menu() {
    print_header
    echo -e "  ${CYAN}${BOLD}── Тесты ──${NC}"
    echo ""
    echo -e "  ${GREEN} 1)${NC}  IP Region"
    echo -e "  ${GREEN} 2)${NC}  Censorcheck — проверка геоблока"
    echo -e "  ${GREEN} 3)${NC}  Censorcheck — DPI (серверы РФ)"
    echo -e "  ${GREEN} 4)${NC}  iPerf3 — тест до российских серверов"
    echo -e "  ${GREEN} 5)${NC}  iPerf3 — bench.tlab.pw (РФ)"
    echo -e "  ${GREEN} 6)${NC}  YABS — бенчмарк сервера"
    echo -e "  ${GREEN} 7)${NC}  IP Check Place — блокировки зарубежными сервисами"
    echo -e "  ${GREEN} 8)${NC}  bench.sh — параметры сервера и скорость"
    echo -e "  ${GREEN} 9)${NC}  IPQuality"
    echo -e "  ${GREEN}10)${NC}  sysbench CPU — тест процессора"
    echo ""
    echo -e "  ${YELLOW}11)${NC}  ${BOLD}Мультитест — запуск всех тестов${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}── Утилиты ──${NC}"
    echo ""
    echo -e "  ${GREEN}12)${NC}  Утилиты (BBR, Cake, Fail2Ban, IPv6)"
    echo ""
    echo -e "  ${RED} 0)${NC}  Выход"
    echo ""
    echo -ne "  ${BOLD}Выберите пункт [0-12]: ${NC}"
}

# ============================================================
#  Главный цикл
# ============================================================

main() {
    while true; do
        show_menu
        read -r choice

        case "$choice" in
            1)  run_ip_region; pause_prompt ;;
            2)  run_censorcheck_geoblock; pause_prompt ;;
            3)  run_censorcheck_dpi; pause_prompt ;;
            4)  run_iperf3_ru; pause_prompt ;;
            5)  run_iperf3_tlab; pause_prompt ;;
            6)  run_yabs; pause_prompt ;;
            7)  run_ip_check_place; pause_prompt ;;
            8)  run_bench_sh; pause_prompt ;;
            9)  run_ip_quality; pause_prompt ;;
            10) run_sysbench_cpu; pause_prompt ;;
            11) run_all; pause_prompt ;;
            12) show_utilities_menu ;;
            0)  echo -e "${GREEN}До свидания!${NC}"; exit 0 ;;
            *)  echo -e "${RED}Неверный выбор. Попробуйте снова.${NC}"; pause_prompt ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
