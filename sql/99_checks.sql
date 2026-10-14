-- 99_checks.sql
-- Сверочные запросы: независимый контроль того, что витрина не исказила данные.
-- Принцип: каждая контрольная цифра считается отдельным простым запросом
-- к сырым данным, без джойнов с витриной, и сравнивается с витриной.

-- 1. Дубли в сырых данных: сколько строк схлопнула дедупликация
SELECT
    (SELECT count(*) FROM raw.portfolio)                          AS raw_rows,
    (SELECT count(*) FROM reporting.v_portfolio_clean)            AS clean_rows,
    (SELECT count(*) FROM raw.portfolio)
  - (SELECT count(*) FROM reporting.v_portfolio_clean)            AS removed_duplicates;

-- 1а. Какие именно loan_id были задублированы
SELECT report_date, loan_id, count(*) AS occurrences
FROM raw.portfolio
GROUP BY report_date, loan_id
HAVING count(*) > 1
ORDER BY report_date, loan_id;

-- 2. Контрольная сумма портфеля в KZT-части: витрина против сырых данных.
--    KZT не зависит от курса, поэтому суммы обязаны совпасть копейка в копейку.
SELECT
    p.report_date,
    r.raw_kzt_sum,
    p.view_kzt_sum,
    r.raw_kzt_sum - p.view_kzt_sum AS diff
FROM (
    SELECT report_date, sum(principal_kzt) AS view_kzt_sum
    FROM reporting.v_portfolio_active
    WHERE currency = 'KZT'
    GROUP BY report_date
) p
JOIN (
    SELECT report_date::date AS report_date,
           sum(principal_outstanding::numeric) AS raw_kzt_sum
    FROM (
        SELECT DISTINCT report_date, loan_id, currency,
               principal_outstanding, written_off
        FROM raw.portfolio
    ) d
    WHERE upper(trim(currency)) = 'KZT' AND written_off::int = 0
    GROUP BY report_date::date
) r USING (report_date);

-- 3. Полнота курсов: ни один валютный кредит не остался без курса
SELECT report_date, currency, count(*) AS loans_without_fx
FROM reporting.v_portfolio_clean
WHERE fx_rate IS NULL
GROUP BY report_date, currency;
-- Ожидание: 0 строк.

-- 4. Инварианты метрик: NPL >= PAR90, PAR30 >= PAR90, все доли в [0, 100]
SELECT
    report_date,
    par30_pct, par90_pct, npl_pct, top10_pct,
    (npl_pct >= par90_pct)  AS npl_ge_par90_ok,
    (par30_pct >= par90_pct) AS par30_ge_par90_ok,
    (par30_pct BETWEEN 0 AND 100
     AND par90_pct BETWEEN 0 AND 100
     AND npl_pct BETWEEN 0 AND 100
     AND top10_pct BETWEEN 0 AND 100) AS pct_range_ok
FROM reporting.v_metrics
ORDER BY report_date;
-- Ожидание: во всех строках только true.

-- 5. Провизии: пересчёт напрямую из атомарных строк, минуя provision_kzt
SELECT
    m.report_date,
    m.provisions_kzt                AS view_provisions,
    c.recalc_provisions,
    m.provisions_kzt - c.recalc_provisions AS diff
FROM reporting.v_metrics m
JOIN (
    SELECT report_date,
           sum(round(principal_kzt * provision_rate, 2)) AS recalc_provisions
    FROM reporting.v_portfolio_active
    GROUP BY report_date
) c USING (report_date);
-- Ожидание: diff = 0.

-- 6. Сумма разрезов равна итогу: отрасли и программы покрывают портфель целиком
SELECT
    m.report_date,
    m.portfolio_kzt                          AS total,
    s.sector_sum,
    pr.program_sum,
    m.portfolio_kzt - s.sector_sum           AS diff_sector,
    m.portfolio_kzt - pr.program_sum         AS diff_program
FROM reporting.v_metrics m
JOIN (SELECT report_date, sum(portfolio_kzt) AS sector_sum
      FROM reporting.v_by_sector GROUP BY report_date) s USING (report_date)
JOIN (SELECT report_date, sum(portfolio_kzt) AS program_sum
      FROM reporting.v_by_program GROUP BY report_date) pr USING (report_date);
-- Ожидание: оба diff = 0.

-- 7. Санити по просрочке: нет отрицательных dpd и отрицательных остатков
SELECT count(*) AS bad_rows
FROM reporting.v_portfolio_clean
WHERE days_past_due < 0 OR principal_fcy < 0;
-- Ожидание: 0.
