#!/bin/sh
# =============================================================================
# deploy.sh - автоматическое локальное развертывание приложения TaskBoard
#
# Использование:   chmod +x deploy.sh && ./deploy.sh
#
# Скрипт идемпотентен: повторный запуск ничего не ломает.
# =============================================================================

# Завершаться при ошибке и при использовании необъявленных переменных
set -eu

# --------------------------- Настройки (единое место) ------------------------
APP_NAME="${APP_NAME:-taskboard}"
REPOSITORY_URL="${REPOSITORY_URL:-https://github.com/sharton/taskboard}"
APP_PORT="${APP_PORT:-8000}"
APP_MODULE="${APP_MODULE:-app.main:app}"
HEALTH_PATH="${HEALTH_PATH:-/api/health}"

DB_NAME="${DB_NAME:-taskboard}"
DB_USER="${DB_USER:-taskboard}"
# Внимание: приложение берёт пароль из app/config.py (по умолчанию taskboard).
DB_PASSWORD="${DB_PASSWORD:-taskboard}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Если скрипт лежит внутри репозитория приложения - используем эту папку,
# иначе клонируем репозиторий в ./taskboard рядом со скриптом.
if [ -z "${APP_DIR:-}" ]; then
    if [ -f "$SCRIPT_DIR/app/main.py" ]; then
        APP_DIR="$SCRIPT_DIR"
    else
        APP_DIR="$SCRIPT_DIR/$APP_NAME"
    fi
fi

VENV_DIR="$APP_DIR/.venv"
PID_FILE="${TMPDIR:-/tmp}/$APP_NAME.pid"
LOG_FILE="${TMPDIR:-/tmp}/$APP_NAME.log"
APP_URL="http://localhost:$APP_PORT"

# --------------------------- Вспомогательные функции -------------------------
log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Проверка: существует ли команда
have() { command -v "$1" >/dev/null 2>&1; }

# Сообщение при любом неуспешном завершении скрипта
on_exit() {
    code=$?
    if [ "$code" -ne 0 ]; then
        printf 'Deployment FAILED (exit code %s).\n' "$code" >&2
    fi
}
trap on_exit EXIT

# --------------------------- 1. Системные программы --------------------------
# Выполнить команду с правами root (через sudo, если мы не root)
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    else
        die "Нужны права root для команды '$*', но sudo не установлен."
    fi
}

# Определить системный менеджер пакетов
detect_pkg_manager() {
    if   have apt-get; then PM=apt
    elif have dnf;     then PM=dnf
    elif have yum;     then PM=yum
    elif have pacman;  then PM=pacman
    elif have zypper;  then PM=zypper
    else PM=""
    fi
}

# Установлен ли сервер PostgreSQL (а не только клиент psql)
pg_server_installed() {
    have postgres \
        || ls /usr/lib/postgresql/*/bin/postgres >/dev/null 2>&1 \
        || ls /usr/pgsql-*/bin/postgres >/dev/null 2>&1 \
        || [ -x /usr/bin/postgresql-setup ]
}

# Проверить наличие программ и доустановить недостающие
install_packages() {
    log "Проверка необходимых программ"
    detect_pkg_manager

    MISSING=""
    have git     || MISSING="$MISSING git"
    have python3 || MISSING="$MISSING python3"
    have curl    || MISSING="$MISSING curl"
    if have python3; then
        python3 -m pip --version >/dev/null 2>&1 || MISSING="$MISSING pip"
        python3 -c 'import ensurepip, venv' >/dev/null 2>&1 || MISSING="$MISSING venv"
    else
        MISSING="$MISSING pip venv"
    fi
    have psql           || MISSING="$MISSING postgresql"
    pg_server_installed || MISSING="$MISSING postgresql"

    if [ -z "$MISSING" ]; then
        log "Все необходимые программы уже установлены"
        return 0
    fi

    log "Не хватает:$MISSING"
    [ -n "$PM" ] || die "Не найден поддерживаемый менеджер пакетов (apt, dnf, yum, pacman, zypper)."

    case "$PM" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            as_root apt-get update -y || die "apt-get update завершился с ошибкой."
            as_root apt-get install -y git curl python3 python3-pip python3-venv \
                postgresql postgresql-contrib \
                || die "Не удалось установить пакеты через apt-get."
            ;;
        dnf|yum)
            as_root "$PM" install -y git curl python3 python3-pip \
                postgresql-server postgresql-contrib \
                || die "Не удалось установить пакеты через $PM."
            ;;
        pacman)
            as_root pacman -Sy --noconfirm --needed git curl python python-pip postgresql \
                || die "Не удалось установить пакеты через pacman."
            ;;
        zypper)
            as_root zypper --non-interactive install git curl python3 python3-pip \
                postgresql-server postgresql-contrib \
                || die "Не удалось установить пакеты через zypper."
            ;;
    esac
    log "Установка пакетов завершена"
}

# ---- MAIN ----
main() {
    log "Развертывание $APP_NAME"
    log "Каталог приложения: $APP_DIR"
    install_packages
}

main "$@"
