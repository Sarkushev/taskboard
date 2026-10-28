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
    if ! have psql || ! pg_server_installed; then MISSING="$MISSING postgresql"; fi

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

# --------------------------- 2. Исходный код ---------------------------------
# Клонировать репозиторий, если исходников ещё нет
fetch_source() {
    if [ -f "$APP_DIR/app/main.py" ]; then
        log "Исходный код уже существует: $APP_DIR (клонирование пропущено)"
    elif [ -d "$APP_DIR/.git" ]; then
        log "Репозиторий уже существует: $APP_DIR (клонирование пропущено)"
    else
        log "Клонирование $REPOSITORY_URL в $APP_DIR"
        git clone "$REPOSITORY_URL" "$APP_DIR" \
            || die "Не удалось клонировать репозиторий $REPOSITORY_URL."
    fi
    [ -f "$APP_DIR/requirements.txt" ] || die "В $APP_DIR нет файла requirements.txt."
}

# --------------------------- 3-4. Окружение и зависимости --------------------
# Создать .venv (если нет) и установить зависимости внутри него
setup_venv() {
    if [ -x "$VENV_DIR/bin/python" ]; then
        log "Виртуальное окружение уже существует: $VENV_DIR"
    else
        log "Создание виртуального окружения $VENV_DIR"
        python3 -m venv "$VENV_DIR" || die "Не удалось создать виртуальное окружение."
    fi

    log "Установка Python-зависимостей из requirements.txt"
    "$VENV_DIR/bin/python" -m pip install --quiet --upgrade pip \
        || warn "Не удалось обновить pip, продолжаем с текущей версией."
    "$VENV_DIR/bin/python" -m pip install --quiet -r "$APP_DIR/requirements.txt" \
        || die "Не удалось установить зависимости из requirements.txt."
}

# --------------------------- 5. PostgreSQL -----------------------------------
# Выполнить команду от имени системного пользователя postgres
as_postgres() {
    if have sudo; then
        (cd / && sudo -u postgres "$@")
    elif [ "$(id -u)" -eq 0 ] && have su; then
        (cd / && su -s /bin/sh postgres -c "$*")
    else
        die "Не удалось выполнить команду от имени postgres (нет sudo)."
    fi
}

# Экранирование одинарных кавычек для SQL-литералов
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Выполнить SQL от имени администратора БД, вернуть результат без форматирования
psql_admin() { as_postgres psql -v ON_ERROR_STOP=1 -tA -c "$1"; }

# RHEL/Fedora/Arch: кластер БД может быть не инициализирован
init_postgres_cluster_if_needed() {
    if [ -x /usr/bin/postgresql-setup ] && [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
        log "Инициализация кластера PostgreSQL"
        as_root postgresql-setup --initdb || die "Не удалось инициализировать PostgreSQL."
    fi
    if have pacman && [ ! -f /var/lib/postgres/data/PG_VERSION ]; then
        log "Инициализация кластера PostgreSQL (Arch)"
        as_postgres initdb -D /var/lib/postgres/data \
            || die "Не удалось инициализировать PostgreSQL."
    fi
    # На RHEL для 127.0.0.1 по умолчанию стоит ident - заменяем на парольную аутентификацию
    HBA=/var/lib/pgsql/data/pg_hba.conf
    if [ -f "$HBA" ] && as_root grep -Eq '^host.*[[:space:]]ident$' "$HBA"; then
        log "Включение парольной аутентификации в pg_hba.conf"
        as_root sed -i -E '/^host/ s/[[:space:]]ident$/ md5/' "$HBA"
        PG_RESTART=1
    fi
}

# Запустить службу PostgreSQL и дождаться готовности
start_postgres() {
    log "Запуск PostgreSQL"
    PG_RESTART=0
    init_postgres_cluster_if_needed

    if have systemctl && [ -d /run/systemd/system ]; then
        if [ "$PG_RESTART" -eq 1 ]; then
            as_root systemctl restart postgresql || die "Не удалось перезапустить PostgreSQL."
        else
            as_root systemctl enable --now postgresql \
                || die "Не удалось запустить PostgreSQL через systemctl."
        fi
    elif have service; then
        as_root service postgresql start || die "Не удалось запустить PostgreSQL через service."
    else
        die "Не найден systemctl/service для запуска PostgreSQL."
    fi

    i=0
    until psql_admin "SELECT 1" >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -le 30 ] || die "PostgreSQL не ответил за 30 секунд."
        sleep 1
    done
    log "PostgreSQL запущен"
}

# Создать пользователя и базу данных (безопасно при повторном запуске)
setup_database() {
    log "Настройка базы данных '$DB_NAME' и пользователя '$DB_USER'"
    esc_pass=$(sql_escape "$DB_PASSWORD")

    # Пользователь: создаём или обновляем пароль
    if [ "$(psql_admin "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")" = "1" ]; then
        log "Пользователь '$DB_USER' уже существует - обновляем пароль"
        psql_admin "ALTER ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$esc_pass'" >/dev/null \
            || die "Не удалось обновить пароль пользователя '$DB_USER'."
    else
        psql_admin "CREATE ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$esc_pass'" >/dev/null \
            || die "Не удалось создать пользователя '$DB_USER'."
    fi

    # База данных: создаём, если её нет
    if [ "$(psql_admin "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")" = "1" ]; then
        log "База данных '$DB_NAME' уже существует"
    else
        psql_admin "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\"" >/dev/null \
            || die "Не удалось создать базу данных '$DB_NAME'."
    fi
    psql_admin "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\"" >/dev/null \
        || die "Не удалось выдать права на базу '$DB_NAME'."

    # Проверка подключения тем же способом, каким подключается приложение
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -tA -c "SELECT 1" >/dev/null 2>&1 \
        || die "Не удаётся подключиться к БД по паролю (проверьте pg_hba.conf)."
    log "Подключение к базе данных работает"
}

# --------------------------- 6. Запуск приложения ----------------------------
# Занят ли порт приложения другим процессом
port_in_use() {
    python3 - "$APP_PORT" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(0.5)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

# Остановить экземпляр, запущенный предыдущим запуском скрипта
stop_previous_instance() {
    if [ -f "$PID_FILE" ]; then
        old_pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            log "Остановка предыдущего экземпляра приложения (PID $old_pid)"
            kill "$old_pid" 2>/dev/null || true
            i=0
            while kill -0 "$old_pid" 2>/dev/null && [ "$i" -lt 10 ]; do
                i=$((i + 1))
                sleep 1
            done
            kill -9 "$old_pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
}

# Запустить Uvicorn в фоновом режиме
start_app() {
    stop_previous_instance
    if port_in_use; then
        die "Порт $APP_PORT уже занят другим процессом. Освободите его или задайте APP_PORT."
    fi

    log "Запуск приложения (uvicorn $APP_MODULE, порт $APP_PORT)"
    export DATABASE_URL="postgresql+psycopg://$DB_USER:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME"
    (
        cd "$APP_DIR"
        nohup "$VENV_DIR/bin/uvicorn" "$APP_MODULE" --host 0.0.0.0 --port "$APP_PORT" \
            >"$LOG_FILE" 2>&1 &
        echo $! >"$PID_FILE"
    )
    sleep 1
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null \
        || die "Uvicorn завершился сразу после запуска. Лог: $LOG_FILE"
}

# --------------------------- 7. Проверка результата --------------------------
# Дождаться ответа healthcheck (до 30 секунд)
check_health() {
    log "Проверка healthcheck: $APP_URL$HEALTH_PATH"
    i=0
    until curl -fsS "$APP_URL$HEALTH_PATH" >/dev/null 2>&1; do
        i=$((i + 1))
        if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            tail -n 20 "$LOG_FILE" >&2 || true
            die "Приложение упало во время запуска. Лог: $LOG_FILE"
        fi
        if [ "$i" -gt 30 ]; then
            tail -n 20 "$LOG_FILE" >&2 || true
            die "Healthcheck не прошёл за 30 секунд. Лог: $LOG_FILE"
        fi
        sleep 1
    done
}

# ---- MAIN ----
main() {
    log "Развертывание $APP_NAME"
    log "Каталог приложения: $APP_DIR"
    install_packages
    fetch_source
    setup_venv
    start_postgres
    setup_database
    start_app
    check_health

    echo
    echo "Application deployed successfully."
    echo "Application is available at: $APP_URL"
    echo "Swagger API: $APP_URL/docs"
    echo "Log file: $LOG_FILE (PID file: $PID_FILE)"
}

main "$@"
