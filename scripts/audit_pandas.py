#!/usr/bin/env python3
"""Независимый аудит витрин: пересчёт всех метрик на pandas без единой
строки общего кода с SQL. Запускается напрямую от CSV и сравнивается
с выводом reporting.v_metrics глазами или скриптом.

Ожидаемое поведение: проценты совпадают до сотых; суммы в тенге могут
расходиться на тиыны, потому что pandas считает во float64, а Postgres
в точном numeric. Эталоном считается Postgres.
"""
import pathlib

import pandas as pd

ROOT = pathlib.Path(__file__).resolve().parent.parent

p = pd.read_csv(ROOT / "data" / "portfolio.csv",
                dtype={"days_past_due": int, "restructured": int, "written_off": int})
fx = pd.read_csv(ROOT / "data" / "fx.csv")

print("=== Проверка данных на ловушки ===")
print("граничные dpd:", {d: int((p.days_past_due == d).sum()) for d in (29, 30, 31, 89, 90, 91)})
print("нулевые/отрицательные остатки:", int((p.principal_outstanding <= 0).sum()))
print("restructured и written_off одновременно:",
      int(((p.restructured == 1) & (p.written_off == 1)).sum()))
print("полных дублей строк:", int(p.duplicated().sum()))
print("валюты:", sorted(p.currency.unique()))

print("\n=== Независимый расчёт метрик ===")
p = p.drop_duplicates()
assert not p.duplicated(["report_date", "loan_id"]).any(), "неполные дубли: одинаковый ключ, разные значения"

fxmap = fx.set_index(["date", "currency"]).rate_kzt


def rate_on(date: str, currency: str) -> float:
    if currency == "KZT":
        return 1.0
    sub = fx[(fx.currency == currency) & (fx.date <= date)]
    assert len(sub), f"нет курса {currency} на {date} или раньше"
    return float(sub.sort_values("date").rate_kzt.iloc[-1])


for date in sorted(p.report_date.unique()):
    s = p[(p.report_date == date) & (p.written_off == 0)].copy()
    s["kzt"] = (s.principal_outstanding * s.currency.map(lambda c: rate_on(date, c))).round(2)
    total = s.kzt.sum()
    npl_mask = (s.days_past_due > 90) | (s.restructured == 1)
    prov_rate = npl_mask * 0.50 \
        + (~npl_mask & (s.days_past_due > 30)) * 0.10 \
        + (~npl_mask & (s.days_past_due <= 30)) * 0.01
    groups = s.groupby("group_id").kzt.sum().sort_values(ascending=False)
    assert abs(groups.iloc[9] - groups.iloc[10]) > 0.01, "ничья на границе топ-10, нужен детерминированный тай-брейк"
    print(f"{date}: портфель={total:,.2f}  "
          f"PAR30={s.loc[s.days_past_due > 30, 'kzt'].sum() / total * 100:.2f}  "
          f"PAR90={s.loc[s.days_past_due > 90, 'kzt'].sum() / total * 100:.2f}  "
          f"NPL={s.loc[npl_mask, 'kzt'].sum() / total * 100:.2f}  "
          f"top10={groups.head(10).sum() / total * 100:.2f}  "
          f"провизии={(s.kzt * prov_rate).round(2).sum():,.2f}  "
          f"кредитов={len(s)}")
