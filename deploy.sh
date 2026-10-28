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

# ---- MAIN ----
main() {
    log "Развертывание $APP_NAME"
    log "Каталог приложения: $APP_DIR"
}

main "$@"
