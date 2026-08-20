# Multitest

Интерактивный bash-скрипт для диагностики и тестирования Linux-серверов. Объединяет популярные инструменты проверки в одном меню.

## Быстрый старт

**Запуск без установки:**

```bash
bash <(curl -sL https://raw.githubusercontent.com/Konstannttiinn1/multitest/master/multitest.sh)
```

**Установка как команда `multitest`:**

```bash
curl -sL https://raw.githubusercontent.com/Konstannttiinn1/multitest/master/multitest.sh -o /usr/local/bin/multitest && chmod +x /usr/local/bin/multitest && echo "Установлено! Запуск: multitest"
```

После установки скрипт доступен из любого места:

```bash
multitest
```

## Меню

### Тесты

| # | Название | Описание |
|---|----------|----------|
| 1 | IP Region | Определение региона IP-адреса сервера |
| 2 | Censorcheck (геоблок) | Проверка геоблокировок |
| 3 | Censorcheck (DPI) | Проверка DPI для серверов в РФ |
| 4 | iPerf3 (РФ) | Тест скорости до российских iPerf3 серверов |
| 5 | iPerf3 (РФ, tlab) | iPerf3-тест до РФ провайдеров через bench.tlab.pw |
| 6 | YABS | Бенчмарк сервера (диск, сеть, CPU) |
| 7 | IP Check Place | Проверка IP на блокировки зарубежными сервисами |
| 8 | bench.sh | Параметры сервера и скорость к зарубежным провайдерам |
| 9 | IPQuality | Проверка качества IP-адреса |
| 10 | sysbench CPU | Тест процессора (1 поток) |
| 11 | **Мультитест** | Запуск всех тестов последовательно |

### Утилиты

| # | Название | Описание |
|---|----------|----------|
| 1 | BBR + CAKE | Включение TCP BBR и фактическое применение CAKE к интерфейсам с маршрутом по умолчанию |
| 2 | Выключить IPv6 | Отключение IPv6 через sysctl |
| 3 | Fail2Ban | Установка и защита SSH: 5 ошибок за 10 минут блокируют IP на 12 часов |
| 4 | Статус | Проверка реального состояния BBR, CAKE на каждом интерфейсе и jail `sshd` |

### Чем новая проверка CAKE отличается от старой

Значение `net.core.default_qdisc=cake` само по себе не означает, что CAKE уже
работает на активном сетевом интерфейсе. Утилита теперь:

1. Находит интерфейсы по IPv4/IPv6-маршрутам по умолчанию, не полагаясь на имя
   вроде `eth0`, `ens3` или `enp1s0`.
2. Выполняет `tc qdisc replace dev <интерфейс> root cake`.
3. Проверяет, что в выводе `tc qdisc show` действительно присутствует
   `qdisc cake ... root`.
4. На системах с systemd устанавливает `multitest-cake.service`, чтобы повторно
   применить и проверить CAKE после поднятия сети при перезагрузке.

Если хотя бы одна из проверок не прошла, скрипт не сообщает об успехе и выводит
красный статус проблемного компонента.

Для редких схем маршрутизации интерфейс можно указать явно перед запуском,
например: `MULTITEST_NET_IFACE=ens3 multitest`.

### Настройки Fail2Ban

Создаётся отдельный файл `/etc/fail2ban/jail.d/sshd-multitest.local`. SSH-порт
определяется через итоговую конфигурацию `sshd`, поэтому поддерживается и
нестандартный порт. Перед перезапуском выполняется `fail2ban-client -t`, после —
проверка активного jail `sshd`.

## Зависимости

Скрипт автоматически установит недостающие пакеты:

- `curl`
- `wget`
- `sysbench`
- `iperf3`
- `iproute2`/`iproute` (для `ip` и `tc`)
- `kmod`
- `fail2ban` (при выборе соответствующего пункта)

Поддерживаемые пакетные менеджеры: `apt`, `dnf`, `yum`, `apk`, `pacman`.

## Требования

- Linux (Debian/Ubuntu, CentOS/RHEL, Fedora, Alpine, Arch)
- Права root (для установки пакетов и утилит)
- Bash 4+

## Используемые проекты

- [ipregion](https://ipregion.vrnt.xyz) — определение региона IP
- [censorcheck](https://github.com/vernette/censorcheck) — проверка цензуры и DPI
- [russian-iperf3-servers](https://github.com/itdoginfo/russian-iperf3-servers) — iPerf3 серверы в РФ
- [bench.tlab.pw](https://bench.tlab.pw) — альтернативные iPerf3 серверы в РФ
- [YABS](https://yabs.sh) — Yet Another Bench Script
- [IP.Check.Place](https://ip.check.place) — проверка блокировок IP
- [bench.sh](https://bench.sh) — бенчмарк сервера
- [Check.Place](https://check.place) — IPQuality
- [sysbench](https://github.com/akopytov/sysbench) — тест CPU
