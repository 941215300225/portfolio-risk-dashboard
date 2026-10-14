-- 01_load_raw.sql
-- Загрузка CSV в схему raw. Идемпотентно: таблицы пересоздаются из файлов целиком.
-- Запуск: psql -v data_dir=/абсолютный/путь/к/data -f sql/01_load_raw.sql
-- (scripts/run.sh подставляет data_dir автоматически)

-- Сырой слой храним максимально близко к файлу: все поля текстом,
-- типизация и очистка происходят на входе в reporting (принцип ELT).

DROP TABLE IF EXISTS raw.portfolio CASCADE;
CREATE TABLE raw.portfolio (
    report_date           text,
    loan_id               text,
    borrower_id           text,
    group_id              text,
    sector                text,
    program               text,
    currency              text,
    issue_date            text,
    maturity_date         text,
    principal_outstanding text,
    days_past_due         text,
    restructured          text,
    written_off           text
);

DROP TABLE IF EXISTS raw.fx CASCADE;
CREATE TABLE raw.fx (
    date     text,
    currency text,
    rate_kzt text
);

-- \copy не интерполирует переменные напрямую, поэтому команда собирается
-- в переменную и выполняется через :cmd
\set portfolio_csv :data_dir /portfolio.csv
\set fx_csv :data_dir /fx.csv
\set cmd_portfolio '\\copy raw.portfolio FROM ' :'portfolio_csv' ' WITH (FORMAT csv, HEADER true)'
\set cmd_fx '\\copy raw.fx FROM ' :'fx_csv' ' WITH (FORMAT csv, HEADER true)'
:cmd_portfolio
:cmd_fx

-- Контроль загрузки
SELECT 'raw.portfolio' AS table_name, count(*) AS rows_loaded FROM raw.portfolio
UNION ALL
SELECT 'raw.fx', count(*) FROM raw.fx;
