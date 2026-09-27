"""Statistical anomaly detection over a daily cost series.

Method: trailing-window z-score. For each day, the baseline is the mean/stddev of the
previous `baseline_days` days for that same group (service, sku, label). A day is
flagged when it deviates by more than `z_threshold` standard deviations from that
baseline. Series with near-zero variance (a flat, predictable cost) fall back to a
percentage-deviation check so a low-noise series isn't either permanently silent or
trivially triggered by rounding noise.

This is intentionally the simplest method that is still honest: no seasonality model,
no ML. It is documented as such in docs/adr/0001 and the trade-off (weekly patterns can
look like anomalies without enough baseline history) is called out in the README's
known-gaps section.
"""

from __future__ import annotations

from dataclasses import dataclass
from statistics import mean, pstdev


@dataclass(frozen=True)
class DayPoint:
    date: str  # ISO date, e.g. "2026-08-14"
    cost: float


@dataclass(frozen=True)
class AnomalyResult:
    date: str
    cost: float
    baseline_mean: float
    baseline_stddev: float
    z_score: float
    pct_deviation: float
    method: str
    is_anomaly: bool
    reason: str


def evaluate_series(
    points: list[DayPoint],
    baseline_days: int = 14,
    z_threshold: float = 3.5,
    min_baseline_points: int = 7,
    flat_series_pct_threshold: float = 0.5,
    min_abs_cost: float = 1.0,
) -> list[AnomalyResult]:
    """Evaluate every day in `points` (sorted ascending by date) against its own trailing
    baseline of up to `baseline_days` prior days from the *same* series.

    Returns one AnomalyResult per day that has enough baseline history to be judged
    (days before `min_baseline_points` of history exist are skipped, not flagged).
    """
    ordered = sorted(points, key=lambda p: p.date)
    results: list[AnomalyResult] = []
    for i, point in enumerate(ordered):
        window = ordered[max(0, i - baseline_days) : i]
        if len(window) < min_baseline_points:
            continue
        costs = [w.cost for w in window]
        m = mean(costs)
        sd = pstdev(costs)
        pct_dev = (
            ((point.cost - m) / m)
            if m > 0
            else (0.0 if point.cost == 0 else float("inf"))
        )

        if point.cost < min_abs_cost and m < min_abs_cost:
            results.append(
                AnomalyResult(
                    point.date,
                    point.cost,
                    m,
                    sd,
                    0.0,
                    pct_dev,
                    "skipped-negligible",
                    False,
                    "",
                )
            )
            continue

        if sd > 0.01 * max(m, 1.0):
            z = (point.cost - m) / sd
            is_anom = abs(z) >= z_threshold
            reason = (
                f"z={z:.2f} (threshold {z_threshold}) vs {baseline_days}d baseline mean={m:.2f} stddev={sd:.2f}"
                if is_anom
                else ""
            )
            results.append(
                AnomalyResult(
                    point.date,
                    point.cost,
                    m,
                    sd,
                    z,
                    pct_dev,
                    "z-score",
                    is_anom,
                    reason,
                )
            )
        else:
            # Baseline is essentially flat: z-score would be undefined/explosive on tiny
            # noise, so fall back to a plain percentage-deviation check.
            is_anom = abs(pct_dev) >= flat_series_pct_threshold
            reason = (
                f"pct_deviation={pct_dev:+.0%} (threshold {flat_series_pct_threshold:.0%}) vs flat baseline mean={m:.2f}"
                if is_anom
                else ""
            )
            results.append(
                AnomalyResult(
                    point.date,
                    point.cost,
                    m,
                    sd,
                    0.0,
                    pct_dev,
                    "flat-baseline-pct",
                    is_anom,
                    reason,
                )
            )
    return results
