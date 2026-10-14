-- 00_init.sql
-- Схемы проекта. Скрипт идемпотентен: повторный запуск ничего не ломает.

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS reporting;

COMMENT ON SCHEMA raw IS 'Сырые выгрузки как есть, без трансформаций';
COMMENT ON SCHEMA reporting IS 'Очищенные витрины и метрики для отчётности';
