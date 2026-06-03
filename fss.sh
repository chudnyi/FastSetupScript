#!/bin/bash
# Fast Setup Script · Debian 12/13 Edition · Ultimate UI
# Содержит: русское меню + анимация загрузки + защита от падения под Root + оптимизированная вёрстка

set -euo pipefail

# ================== 0. Глобальная конфигурация ==================
# 1. Имя пользователя
DEFAULT_USERNAME="${SET_USER:-admin}"

# 2. Хеш пароля (обработка конфликта переменной $6)
# Логика: приоритет у SET_HASH, иначе используется значение по умолчанию
DEFAULT_PASSWORD_HASH="${SET_HASH:-}"
if [ -z "$DEFAULT_PASSWORD_HASH" ]; then
    # Внимание: значение по умолчанию обязательно в одинарных кавычках, чтобы $6 не интерпретировался Bash
    DEFAULT_PASSWORD_HASH='YourHashedPassWD'
fi

# 3. Публичный SSH-ключ
DEFAULT_PUBLIC_KEY="${SET_KEY:-YourSSHPubKey}"

# 4. Параметры Cloudflare (допускают инъекцию из окружения)
CF_ZONE_ID="${SET_CF_ZONE_ID:-YourZoneID}"
CF_API_ENC="${SET_CF_ENC:-YourEncryptedAPIKey}"

# 5. Пароль для расшифровки токена Cloudflare
CF_TOKEN_PASS="${SET_TOKEN_PASS:-}"

# 6. Имя хоста (допускает инъекцию из окружения)
# Если в командной строке не передан --hostname, пробуем прочитать переменную SET_HOSTNAME
HOSTNAME_ARG="${SET_HOSTNAME:-}"

# ================== 1. Разбор аргументов и предпроверка окружения ==================

FOR_REAL=0
WITHOUT_GUM=0
WITH_DNS=0
HOSTNAME_ARG=""
CF_API_TOKEN=""
PARSE_ERROR=0

# Субкоманда и её позиционные аргументы
SUBCMD=""
SUBCMD_ARGS=()

# Разбор аргументов в один проход: --help работает в любой позиции,
# флаги можно указывать вперемешку с субкомандой
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            SUBCMD="help"
            shift
            ;;
        --for-real)
            FOR_REAL=1
            WITHOUT_GUM=1
            shift
            ;;
        --without-gum)
            WITHOUT_GUM=1
            shift
            ;;
        --with-dns)
            WITH_DNS=1
            shift
            ;;
        --hostname)
            shift
            if [ $# -eq 0 ]; then echo "Ошибка: --hostname требует аргумент" >&2; exit 1; fi
            HOSTNAME_ARG="$1"
            shift
            ;;
        update|user|ssh|hostname|dns|all|help)
            # Если уже запрошена справка, субкоманды игнорируются (help имеет приоритет)
            if [ "$SUBCMD" = "help" ]; then
                shift
                continue
            fi
            # Запрет на две разные команды в одной строке
            if [ -n "$SUBCMD" ] && [ "$SUBCMD" != "$1" ]; then
                echo "Ошибка: указано более одной команды ('$SUBCMD' и '$1')" >&2
                SUBCMD="help"
                PARSE_ERROR=1
                shift
                continue
            fi
            SUBCMD="$1"
            shift
            ;;
        -*)
            echo "Неизвестный аргумент: $1" >&2
            SUBCMD="help"
            PARSE_ERROR=1
            shift
            ;;
        *)
            # Позиционный аргумент — добавляем к аргументам субкоманды
            SUBCMD_ARGS+=("$1")
            shift
            ;;
    esac
done

# Если субкоманда не задана — показать справку
if [ -z "$SUBCMD" ]; then
    SUBCMD="help"
fi

# Вывод справки
print_help() {
    cat <<'EOF'
Использование: fss.sh [ГЛОБАЛЬНЫЕ ФЛАГИ] <КОМАНДА> [АРГУМЕНТЫ]

Команды:
  update                    Обновить систему (apt update && apt upgrade)
  user [ИМЯ]                Создать пользователя и настроить sudo NOPASSWD
                            (по умолчанию: admin или $SET_USER)
  ssh [КЛЮЧ]                Установить публичный SSH-ключ и отключить вход по паролю
                            (по умолчанию: значение по умолчанию или $SET_KEY)
  hostname [ИМЯ]            Изменить имя хоста
                            (по умолчанию: $SET_HOSTNAME или интерактивный ввод)
  dns                       Синхронизировать DNS через Cloudflare
                            (требует --with-dns или заранее зашифрованный токен)
  all                       Выполнить все шаги по порядку (полная настройка)
  help                      Показать эту справку

Глобальные флаги (можно указывать в любой позиции; --help имеет приоритет):
  --for-real                Скоростной режим без интерактивных запросов
  --without-gum             Не использовать gum
  --with-dns                Включить шаг синхронизации DNS
  --hostname ИМЯ            Задать имя хоста по умолчанию
  -h, --help                Показать эту справку и выйти (имеет приоритет)

Переменные окружения:
  SET_USER                  Имя пользователя (по умолчанию: admin)
  SET_HASH                  Хеш пароля (SHA-512 crypt)
  SET_KEY                   Публичный SSH-ключ
  SET_HOSTNAME              Имя хоста
  SET_CF_ZONE_ID            ID зоны Cloudflare
  SET_CF_ENC                Зашифрованный API-токен Cloudflare
  SET_TOKEN_PASS            Пароль для расшифровки токена CF

Примеры:
  fss.sh update
  fss.sh --for-real user deploy
  fss.sh ssh "ssh-ed25519 AAAA... user@host"
  fss.sh --hostname node1.example.com hostname
  fss.sh --with-dns --for-real all
EOF
}

# [Ключевое исправление] Автодоустановка зависимостей в среде Root
prepare_env() {
    if [ "$EUID" -eq 0 ]; then
        if ! command -v sudo &>/dev/null || ! command -v curl &>/dev/null; then
            echo -e "\033[0;33m⚠ Обнаружен Root без необходимых зависимостей, устанавливаю (sudo/curl)...\033[0m"
            apt-get update -y >/dev/null 2>&1
            apt-get install -y sudo curl openssl >/dev/null 2>&1
        fi
    else
        if ! command -v sudo &>/dev/null; then
            echo -e "\033[0;31mОшибка: скрипту требуются права Root или Sudo.\033[0m"
            exit 1
        fi
    fi
}
prepare_env

# ================== 2. Визуальные и служебные функции ==================

CURRENT_TIME=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
HOSTNAME_NOW=$(hostname)
CURRENT_USER=$(whoami)

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Главная анимация (Loading -> SUCCESS) ---
show_loading() {
    local pid=$1         # PID фоновой команды
    local message=$2     # Сообщение
    local dots=('.  ' '.. ' '...')
    local i=0

    # Скрыть курсор
    tput civis 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        # Синий текст с индикатором загрузки
        printf "\r${BLUE}%s${NC} %s" "$message" "${dots[i++ % ${#dots[@]}]}"
        sleep 0.3
    done

    wait "$pid"
    local exit_code=$?

    # Очистить строку и вывести результат
    # %-50s используется для выравнивания
    if [ $exit_code -eq 0 ]; then
        printf "\r%-50s ${GREEN}УСПЕХ${NC}\n" "$message"
    else
        printf "\r%-50s ${RED}ОШИБКА${NC}\n" "$message"
        echo -e "${RED}Ошибка:${NC} команда завершилась неудачно (код: $exit_code)"
        # Здесь не делаем принудительный выход — решает вызывающий код
    fi

    # Восстановить курсор
    tput cnorm 2>/dev/null || true
    return $exit_code
}

# Обёртка для запуска в фоне
run_bg() {
    local cmd=$1
    local msg=$2
    if [ "$FOR_REAL" -eq 1 ]; then
        # Скоростной режим: без анимации, сразу выводим результат
        bash -c "$cmd" &>/dev/null
        if [ $? -eq 0 ]; then
            printf "%-50s ${GREEN}УСПЕХ${NC}\n" "$msg"
        else
            printf "%-50s ${RED}ОШИБКА${NC}\n" "$msg"
        fi
    else
        bash -c "$cmd" &>/dev/null &
        show_loading $! "$msg"
    fi
}

# Статические лог-хелперы (с оптимизацией отступов)
log_success() {
    echo -e " ${GREEN}✔ ${NC} $1"
}
log_info() {
    echo -e " ${BLUE}ℹ ${NC} $1"
}
log_warn() {
    echo -e " ${YELLOW}⚠ ${NC} $1"
}

# ================== 3. Совместимость с Gum ==================

export PATH="$HOME/.local/bin:$PATH"

has_gum() {
    [ "$WITHOUT_GUM" -eq 1 ] && return 1
    command -v gum &>/dev/null
}

install_gum_if_needed() {
    [ "$WITHOUT_GUM" -eq 1 ] && return 0
    if has_gum; then return 0; fi

    echo -e "Проверяю окружение..."

    # Пытаемся установить (анимация через run_bg)
    run_bg "sudo apt update && sudo apt install -y curl gnupg" "Установка базовых зависимостей"

    sudo mkdir -p /etc/apt/keyrings
    # Скачиваем ключ, проверяем успех; при ошибке останавливаемся (без || true)
    if ! curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg --yes; then
        log_warn "Не удалось скачать/импортировать GPG-ключ charm.gpg — gum, вероятно, не установится"
    fi
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ /" | sudo tee /etc/apt/sources.list.d/charm.list &>/dev/null

    run_bg "sudo apt update && sudo apt install -y gum" "Установка интерактивного компонента gum"
}

# --- Интерактивные обёртки ---
confirm_gum() {
    local msg="$1"
    if has_gum; then gum confirm "$msg" && return 0 || return 1; else
        read -p " $msg (Y/n): " ans
        [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]
    fi
}

input_gum() {
    local header="$1"
    local placeholder="${2:-}"
    local default_val="${3:-}"
    if has_gum; then
        if [ -n "$default_val" ]; then
            gum input --header "$header" --placeholder "$placeholder" --value "$default_val"
        else
            gum input --header "$header" --placeholder "$placeholder"
        fi
    else
        read -p " $header [по умолчанию: $default_val]: " val
        echo "${val:-$default_val}"
    fi
}

password_gum() {
    local header="$1"
    if has_gum; then gum input --header "$header" --password; else
        read -s -p " $header: " val; echo; echo "$val"; fi
}

# ================== 4. Бизнес-логика (русская версия) ==================

print_banner() {
    clear
    echo -e "${MAGENTA}"
    cat <<'EOF'
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃  🚀  Fast Setup Script · Debian 12/13 Edition        ┃
┃      "Подключись, выдохни — ты уже root."             ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
EOF
    echo -e "${NC}"

    local mode="Интерактивный режим"
    [ "$FOR_REAL" -eq 1 ] && mode="${RED}⚡ Скоростной режим (без интерактива)${NC}"

    echo -e "  Текущий режим : $mode"
    echo -e "  Текущий пользователь : $CURRENT_USER"
    echo -e "  Имя хоста     : $HOSTNAME_NOW"
    echo
}

perform_system_update() {
    echo -e "${CYAN}----- Этап проверки системы -----${NC}"
    local cmd="sudo DEBIAN_FRONTEND=noninteractive apt update && sudo DEBIAN_FRONTEND=noninteractive apt -y upgrade"

    if [ "$FOR_REAL" -eq 1 ]; then
        run_bg "$cmd" "Выполняю обновление системы"
    elif confirm_gum "Выполнить обновление системы?"; then
        run_bg "$cmd" "Выполняю обновление системы"
    else
        log_warn "Обновление системы пропущено"
    fi
}

setup_user() {
    echo -e "${CYAN}----- Создание пользователя и настройка прав -----${NC}"
    local target_user="$DEFAULT_USERNAME"

    if [ "$FOR_REAL" -ne 1 ]; then
        target_user=$(input_gum "Введите имя создаваемого пользователя" "$DEFAULT_USERNAME" "")
    fi

    # Создание пользователя
    if id "$target_user" &>/dev/null; then
        log_info "Пользователь $target_user уже существует, пропускаю создание"
    else
        sudo useradd -m -s /bin/bash "$target_user"
        log_success "Пользователь $target_user создан"
    fi

    # Установка пароля
    local pass_hash="$DEFAULT_PASSWORD_HASH"

    # [Проверка] Запрет использования плейсхолдера в качестве пароля
    if [[ "$pass_hash" == "YourHashedPassWD" ]] && [ "$FOR_REAL" -eq 1 ]; then
        echo -e "${RED}Ошибка: в скоростном режиме необходимо передать валидный хеш через SET_HASH!${NC}"
        exit 1
    fi

    if [ "$FOR_REAL" -ne 1 ]; then
        local p
        p=$(password_gum "Введите пароль пользователя (пусто — использовать хеш по умолчанию)")
        if [ -n "$p" ] && command -v openssl >/dev/null; then
            pass_hash=$(openssl passwd -6 "$p")
        fi
    fi

    # [Повторная проверка] В интерактивном режиме при пустом вводе нельзя использовать невалидный плейсхолдер
    if [[ "$pass_hash" == "YourHashedPassWD" ]]; then
         echo -e "${RED}Ошибка: пароль не задан, а значение по умолчанию — плейсхолдер.${NC}"
         exit 1
    fi

    echo "$target_user:$pass_hash" | sudo chpasswd -e
    log_success "Пароль пользователя установлен"

    # Права sudo
    sudo usermod -aG sudo "$target_user" 2>/dev/null || sudo usermod -aG wheel "$target_user" 2>/dev/null
    echo "$target_user ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$target_user" >/dev/null
    sudo chmod 440 "/etc/sudoers.d/$target_user"
    log_success "Для $target_user настроен Sudo без пароля"

    TARGET_USERNAME="$target_user"
}

setup_ssh() {
    echo -e "${CYAN}----- Усиление безопасности SSH -----${NC}"
    local ssh_dir="/home/$TARGET_USERNAME/.ssh"
    local pub_key="$DEFAULT_PUBLIC_KEY"

    if [ "$FOR_REAL" -ne 1 ]; then
        local k
        k=$(input_gum "Введите публичный ключ (пусто — значение по умолчанию)" "ssh-..." "")
        [ -n "$k" ] && pub_key="$k"
    fi

    sudo mkdir -p "$ssh_dir"

    # [Безопасность] Добавляем ключ только если его ещё нет — избегаем дубликатов при повторных запусках
    sudo touch "$ssh_dir/authorized_keys"
    if ! sudo grep -qxF "$pub_key" "$ssh_dir/authorized_keys" 2>/dev/null; then
        echo "$pub_key" | sudo tee -a "$ssh_dir/authorized_keys" >/dev/null
        log_success "Публичный SSH-ключ установлен"
    else
        log_info "Публичный SSH-ключ уже присутствует, пропускаю"
    fi

    sudo chmod 700 "$ssh_dir"
    sudo chmod 600 "$ssh_dir/authorized_keys"
    sudo chown -R "$TARGET_USERNAME:$TARGET_USERNAME" "$ssh_dir"

    # Параметры безопасности
    local disable_root="yes"
    local disable_pass="yes"

    if [ "$FOR_REAL" -ne 1 ]; then
        confirm_gum "Отключить SSH-вход под Root?" || disable_root="no"
        confirm_gum "Отключить вход по паролю (только ключ)?" || disable_pass="no"
    fi

    if [ "$disable_root" = "yes" ]; then
        sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        log_success "Вход под Root по SSH отключён"
    fi

    if [ "$disable_pass" = "yes" ]; then
        sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        log_success "Вход по паролю в SSH отключён"
    fi

    # Перезапуск SSH
    if systemctl list-unit-files | grep -q "^ssh\.service"; then
        sudo systemctl restart ssh
    else
        sudo systemctl restart sshd 2>/dev/null || true
    fi
}

setup_hostname() {
    echo -e "${CYAN}----- Настройка имени хоста -----${NC}"
    local new_host=""

    if [ -n "$HOSTNAME_ARG" ]; then
        new_host="$HOSTNAME_ARG"
        log_info "Использую имя хоста из аргумента: $new_host"
    elif [ "$FOR_REAL" -ne 1 ]; then
        new_host=$(input_gum "Введите новое имя хоста (FQDN)" "node1.example.com" "")
    fi

    if [ -n "$new_host" ]; then
        sudo hostnamectl set-hostname "$new_host"
        # [Безопасность] Используем awk вместо grep по регулярке с $new_host,
        # чтобы избежать проблем при спецсимволах в имени хоста
        if ! awk -v h="$new_host" '$1=="127.0.0.1"{for(i=2;i<=NF;i++) if($i==h){f=1;exit}} END{exit !f}' /etc/hosts; then
            echo "127.0.0.1 $new_host" | sudo tee -a /etc/hosts >/dev/null
        fi
        log_success "Имя хоста изменено на: $new_host"
    fi
}

setup_dns() {
    if [ "$WITH_DNS" -eq 0 ]; then return; fi
    echo -e "${CYAN}----- Синхронизация DNS через Cloudflare -----${NC}"

    # 1. Расшифровка токена
    local pass=""
    if [ -n "${CF_TOKEN_PASS:-}" ]; then
        pass="$CF_TOKEN_PASS"
    elif [ "$FOR_REAL" -ne 1 ]; then
        pass=$(password_gum "Введите пароль для расшифровки токена Cloudflare")
    else
        log_warn "Неинтерактивный режим без пароля — синхронизация DNS пропущена"
        return
    fi

    CF_API_TOKEN=$(echo "$CF_API_ENC" | openssl enc -aes-256-cbc -a -d -pbkdf2 -pass pass:"$pass" 2>/dev/null || true)

    if [ -z "$CF_API_TOKEN" ]; then
        echo -e "${RED}Ошибка расшифровки — проверьте пароль.${NC}"
        return
    fi

    # 2. Получение IP
    local ip
    ip=$(curl -4 -s https://ifconfig.io || curl -4 -s https://ipv4.icanhazip.com)
    local fqdn
    fqdn=$(hostname)

    # [Безопасность] Валидация IP и FQDN перед подстановкой в JSON
    if ! [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        log_warn "Не удалось получить валидный IPv4 — синхронизация DNS пропущена"
        return
    fi
    if ! [[ "$fqdn" =~ ^[A-Za-z0-9.-]+$ ]]; then
        log_warn "Имя хоста содержит недопустимые символы — синхронизация DNS пропущена"
        return
    fi

    log_info "Синхронизирую: $fqdn -> $ip"

    # 3. Вызов API (JSON собирается из валидированных значений)
    local resp
    resp=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}")

    if echo "$resp" | grep -q '"success":true'; then
        log_success "DNS-запись Cloudflare успешно добавлена"
    else
        echo -e "${RED}Ошибка вызова Cloudflare API:${NC}"
        echo "$resp" | grep "errors"
    fi
}

# ================== 5. Диспетчер и главный поток ==================

# Если запрошена справка или субкоманда не указана — вывести справку и выйти
if [ "$SUBCMD" = "help" ]; then
    print_help
    [ "$PARSE_ERROR" -eq 1 ] && exit 1 || exit 0
fi

# Применяем позиционные аргументы субкоманд к переменным окружения
case "$SUBCMD" in
    user)
        if [ ${#SUBCMD_ARGS[@]} -gt 0 ]; then
            DEFAULT_USERNAME="${SUBCMD_ARGS[0]}"
        fi
        ;;
    ssh)
        if [ ${#SUBCMD_ARGS[@]} -gt 0 ]; then
            DEFAULT_PUBLIC_KEY="${SUBCMD_ARGS[0]}"
        fi
        ;;
    hostname)
        if [ ${#SUBCMD_ARGS[@]} -gt 0 ]; then
            HOSTNAME_ARG="${SUBCMD_ARGS[0]}"
        fi
        ;;
esac

# 0. Подготовка окружения
install_gum_if_needed

# 1. Показать баннер
print_banner

# 2. Диспетчер субкоманд
case "$SUBCMD" in
    update)
        perform_system_update
        ;;
    user)
        setup_user
        ;;
    ssh)
        setup_ssh
        ;;
    hostname)
        setup_hostname
        ;;
    dns)
        setup_dns
        ;;
    all)
        perform_system_update
        echo
        setup_user
        echo
        setup_ssh
        echo
        setup_hostname
        echo
        setup_dns

        # Итоговая сводка только для полного прогона
        echo -e "${MAGENTA}╔══════════════════════════════════════╗${NC}"
        # %-30s заменено на %-29s: компенсирует погрешность в 1 пробел
        # при расчёте ширины с кириллицей и рамками
        printf "${MAGENTA}║  Пользователь: %-29s ║${NC}\n" "${TARGET_USERNAME}"
        printf "${MAGENTA}║  Хост:         %-29s ║${NC}\n" "$(hostname)"
        echo -e "${MAGENTA}╚══════════════════════════════════════╝${NC}"
        log_success "Все шаги выполнены, добро пожаловать в новую систему."
        ;;
    *)
        echo "Неизвестная команда: $SUBCMD" >&2
        print_help
        exit 1
        ;;
esac

echo
echo -e "${GREEN}Скрипт завершён, благодарим за использование!${NC}"
echo -e "${GREEN}Скрипт распространяется открыто: https://github.com/Bryant-Xue/FastSetupScript — будем рады Issue/PR!${NC}"
