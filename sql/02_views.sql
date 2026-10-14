-- 02_views.sql
-- Витрины reporting поверх raw. Идемпотентно: только CREATE OR REPLACE VIEW.
--
-- Определения метрик (из задания):
--   портфель  = сумма principal_outstanding в тенге по курсу на дату среза,
--               без списанных кредитов (written_off = 1 исключаем);
--   PAR30     = доля портфеля с просрочкой > 30 дней;
--   PAR90     = доля портфеля с просрочкой > 90 дней;
--   NPL       = доля портфеля с просрочкой > 90 дней ИЛИ реструктуризированных;
--   провизии  = остаток × ставка: 1% при просрочке до 30 дней,
--               10% при 31-90 днях, 50% для NPL;
--   топ-10    = доля десяти крупнейших групп связанных заёмщиков (group_id).

-- ---------------------------------------------------------------------------
-- Курсы валют: последний известный курс на дату среза или раньше.
-- Прямого курса на 1-е число может не быть (выходной), поэтому берём
-- последний доступный на дату или до неё. Для KZT курс всегда 1.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_fx AS
SELECT
    date::date          AS rate_date,
    upper(trim(currency)) AS currency,
    rate_kzt::numeric   AS rate_kzt
FROM raw.fx
WHERE rate_kzt IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Очищенная витрина портфеля.
-- Очистка:
--   * типизация всех полей;
--   * дедупликация по (report_date, loan_id) — в выгрузке встречаются
--     полные дубли строк;
--   * пересчёт остатка в тенге по курсу на дату среза;
--   * расчётные атрибуты: бакет просрочки, флаг NPL, ставка и сумма провизии.
-- Списанные кредиты (written_off = 1) остаются в витрине с флагом,
-- но исключаются из всех метрик (фильтр в метрических вьюхах).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_portfolio_clean AS
WITH typed AS (
    SELECT DISTINCT ON (report_date, loan_id)
        report_date::date                  AS report_date,
        trim(loan_id)                      AS loan_id,
        trim(borrower_id)                  AS borrower_id,
        trim(group_id)                     AS group_id,
        trim(sector)                       AS sector,
        trim(program)                      AS program,
        upper(trim(currency))              AS currency,
        issue_date::date                   AS issue_date,
        maturity_date::date                AS maturity_date,
        principal_outstanding::numeric     AS principal_fcy,
        days_past_due::int                 AS days_past_due,
        restructured::int = 1              AS is_restructured,
        written_off::int = 1               AS is_written_off
    FROM raw.portfolio
    ORDER BY report_date, loan_id
),
with_fx AS (
    SELECT
        t.*,
        CASE
            WHEN t.currency = 'KZT' THEN 1::numeric
            ELSE fx.rate_kzt
        END AS fx_rate
    FROM typed t
    LEFT JOIN LATERAL (
        SELECT f.rate_kzt
        FROM reporting.v_fx f
        WHERE f.currency = t.currency
          AND f.rate_date <= t.report_date
        ORDER BY f.rate_date DESC
        LIMIT 1
    ) fx ON t.currency <> 'KZT'
),
enriched AS (
    SELECT
        *,
        -- учётный остаток в тенге: округляем один раз и дальше
        -- все производные считаем от него, чтобы избежать двойного округления
        round(principal_fcy * fx_rate, 2)               AS principal_kzt,
        CASE
            WHEN days_past_due > 90 THEN '90+'
            WHEN days_past_due > 30 THEN '31-90'
            ELSE '0-30'
        END                                             AS dpd_bucket,
        (days_past_due > 90 OR is_restructured)         AS is_npl,
        CASE
            WHEN days_past_due > 90 OR is_restructured THEN 0.50
            WHEN days_past_due > 30                    THEN 0.10
            ELSE 0.01
        END                                             AS provision_rate
    FROM with_fx
)
SELECT
    report_date,
    loan_id,
    borrower_id,
    group_id,
    sector,
    program,
    currency,
    issue_date,
    maturity_date,
    days_past_due,
    is_restructured,
    is_written_off,
    principal_fcy,
    fx_rate,
    principal_kzt,
    dpd_bucket,
    is_npl,
    provision_rate,
    round(principal_kzt * provision_rate, 2)            AS provision_kzt
FROM enriched;

-- ---------------------------------------------------------------------------
-- Активный портфель: всё, что участвует в метриках (без списанных).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_portfolio_active AS
SELECT *
FROM reporting.v_portfolio_clean
WHERE NOT is_written_off;

-- ---------------------------------------------------------------------------
-- Сводка метрик по датам среза.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_metrics AS
WITH base AS (
    SELECT
        report_date,
        sum(principal_kzt)                                            AS portfolio_kzt,
        sum(principal_kzt) FILTER (WHERE days_past_due > 30)          AS par30_kzt,
        sum(principal_kzt) FILTER (WHERE days_past_due > 90)          AS par90_kzt,
        sum(principal_kzt) FILTER (WHERE is_npl)                      AS npl_kzt,
        sum(provision_kzt)                                            AS provisions_kzt,
        count(*)                                                      AS loans_cnt
    FROM reporting.v_portfolio_active
    GROUP BY report_date
),
top10 AS (
    SELECT report_date, sum(group_kzt) AS top10_kzt
    FROM (
        SELECT
            report_date,
            group_id,
            sum(principal_kzt) AS group_kzt,
            row_number() OVER (PARTITION BY report_date
                               ORDER BY sum(principal_kzt) DESC) AS rn
        FROM reporting.v_portfolio_active
        GROUP BY report_date, group_id
    ) g
    WHERE rn <= 10
    GROUP BY report_date
)
SELECT
    b.report_date,
    b.loans_cnt,
    b.portfolio_kzt,
    round(100.0 * coalesce(b.par30_kzt, 0) / b.portfolio_kzt, 2)  AS par30_pct,
    round(100.0 * coalesce(b.par90_kzt, 0) / b.portfolio_kzt, 2)  AS par90_pct,
    round(100.0 * coalesce(b.npl_kzt, 0)   / b.portfolio_kzt, 2)  AS npl_pct,
    round(100.0 * t.top10_kzt              / b.portfolio_kzt, 2)  AS top10_pct,
    b.provisions_kzt
FROM base b
JOIN top10 t USING (report_date);

-- ---------------------------------------------------------------------------
-- Та же сводка с изменением к предыдущему срезу (для шапки дашборда).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_metrics_delta AS
SELECT
    report_date,
    loans_cnt,
    portfolio_kzt,
    par30_pct,
    par90_pct,
    npl_pct,
    top10_pct,
    provisions_kzt,
    portfolio_kzt  - lag(portfolio_kzt)  OVER w AS portfolio_chg_kzt,
    round(par30_pct - lag(par30_pct)     OVER w, 2) AS par30_chg_pp,
    round(par90_pct - lag(par90_pct)     OVER w, 2) AS par90_chg_pp,
    round(npl_pct   - lag(npl_pct)       OVER w, 2) AS npl_chg_pp,
    round(top10_pct - lag(top10_pct)     OVER w, 2) AS top10_chg_pp,
    provisions_kzt - lag(provisions_kzt) OVER w AS provisions_chg_kzt
FROM reporting.v_metrics
WINDOW w AS (ORDER BY report_date);

-- ---------------------------------------------------------------------------
-- Разрез по отраслям.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_by_sector AS
SELECT
    report_date,
    sector,
    count(*)                                              AS loans_cnt,
    sum(principal_kzt)                                    AS portfolio_kzt,
    sum(principal_kzt) FILTER (WHERE is_npl)              AS npl_kzt,
    round(100.0 * coalesce(sum(principal_kzt) FILTER (WHERE is_npl), 0)
        / nullif(sum(principal_kzt), 0), 2)               AS npl_pct,
    sum(provision_kzt)                                    AS provisions_kzt
FROM reporting.v_portfolio_active
GROUP BY report_date, sector;

-- ---------------------------------------------------------------------------
-- Разрез по программам.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_by_program AS
SELECT
    report_date,
    program,
    count(*)                                              AS loans_cnt,
    sum(principal_kzt)                                    AS portfolio_kzt,
    sum(principal_kzt) FILTER (WHERE is_npl)              AS npl_kzt,
    round(100.0 * coalesce(sum(principal_kzt) FILTER (WHERE is_npl), 0)
        / nullif(sum(principal_kzt), 0), 2)               AS npl_pct,
    sum(provision_kzt)                                    AS provisions_kzt
FROM reporting.v_portfolio_active
GROUP BY report_date, program;

-- ---------------------------------------------------------------------------
-- Разрез по бакетам просрочки (для структуры риска).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_by_dpd_bucket AS
SELECT
    report_date,
    dpd_bucket,
    count(*)            AS loans_cnt,
    sum(principal_kzt)  AS portfolio_kzt,
    sum(provision_kzt)  AS provisions_kzt
FROM reporting.v_portfolio_active
GROUP BY report_date, dpd_bucket;
