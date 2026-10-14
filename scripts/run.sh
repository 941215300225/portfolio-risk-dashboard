#!/usr/bin/env bash
# Полный прогон пайплайна: схемы -> загрузка CSV -> витрины -> выгрузка данных
# для дашборда -> сверочные запросы. Идемпотентен, можно запускать повторно.
#
# Использование:
#   ./scripts/run.sh [DATABASE_URL]
#
# По умолчанию подключается к postgresql://postgres@localhost:5432/arqa_bi.
# Локальный Postgres поднимается одной командой:
#   docker run -d --name arqa-pg -e POSTGRES_HOST_AUTH_METHOD=trust -p 5432:5432 postgres:16

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_URL="${1:-postgresql://postgres@localhost:5432/arqa_bi}"
DB_NAME="${DB_URL##*/}"
ADMIN_URL="${DB_URL%/*}/postgres"

echo "==> База: $DB_NAME"
psql "$ADMIN_URL" -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 \
    || psql "$ADMIN_URL" -c "CREATE DATABASE $DB_NAME"

echo "==> Схемы"
psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$ROOT/sql/00_init.sql"

echo "==> Загрузка CSV в raw"
psql "$DB_URL" -v ON_ERROR_STOP=1 -v data_dir="$ROOT/data" -f "$ROOT/sql/01_load_raw.sql"

echo "==> Витрины reporting"
psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$ROOT/sql/02_views.sql"

echo "==> Выгрузка данных для дашборда"
mkdir -p "$ROOT/dashboard/data"
export_json() {
    local query="$1" out="$2"
    psql "$DB_URL" -tA -c "SELECT coalesce(json_agg(t), '[]'::json) FROM ($query) t" \
        > "$ROOT/dashboard/data/$out"
    echo "    dashboard/data/$out"
}
export_json "SELECT * FROM reporting.v_metrics_delta ORDER BY report_date" metrics.json
export_json "SELECT * FROM reporting.v_by_sector     ORDER BY report_date, portfolio_kzt DESC" by_sector.json
export_json "SELECT * FROM reporting.v_by_program    ORDER BY report_date, portfolio_kzt DESC" by_program.json
export_json "SELECT * FROM reporting.v_by_dpd_bucket ORDER BY report_date, dpd_bucket" by_dpd_bucket.json

echo "==> Сверочные запросы"
psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$ROOT/sql/99_checks.sql"

echo "==> Итоговые метрики"
psql "$DB_URL" -c "SELECT * FROM reporting.v_metrics ORDER BY report_date"

echo "==> Готово. Дашборд: откройте dashboard/index.html"
echo "    (данные грузятся fetch-ом, поэтому через локальный сервер:"
echo "     cd dashboard && python3 -m http.server 8000)"
