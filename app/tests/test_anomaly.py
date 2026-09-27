from datetime import date, timedelta

from detector.anomaly import DayPoint, evaluate_series


def series(
    base: float,
    n: int,
    spike_at: int | None = None,
    spike_mult: float = 6.0,
    start="2026-06-01",
    noisy=False,
):
    d0 = date.fromisoformat(start)
    pts = []
    for i in range(n):
        cost = base
        if noisy:
            cost += base * (0.03 if i % 2 == 0 else -0.03)  # deterministic +/-3% wobble
        if spike_at is not None and i == spike_at:
            cost = base * spike_mult
        pts.append(DayPoint((d0 + timedelta(days=i)).isoformat(), cost))
    return pts


def test_stable_series_has_no_anomalies():
    pts = series(100.0, 30)
    results = evaluate_series(pts, baseline_days=14, min_baseline_points=7)
    assert len(results) == 30 - 7
    assert not any(r.is_anomaly for r in results)


def test_spike_is_flagged():
    pts = series(100.0, 30, spike_at=20, spike_mult=8.0, noisy=True)
    results = evaluate_series(pts, baseline_days=14, min_baseline_points=7)
    flagged = [r for r in results if r.is_anomaly]
    assert len(flagged) == 1
    assert flagged[0].date == pts[20].date
    assert flagged[0].method == "z-score"


def test_early_days_without_enough_baseline_are_skipped_not_flagged():
    pts = series(100.0, 10)
    results = evaluate_series(pts, baseline_days=14, min_baseline_points=7)
    assert len(results) == 3
    assert not any(r.is_anomaly for r in results)


def test_flat_zero_variance_series_uses_percentage_fallback():
    pts = series(
        50.0, 20, spike_at=15, spike_mult=2.0
    )  # +100% on a perfectly flat series
    results = evaluate_series(
        pts, baseline_days=14, min_baseline_points=7, flat_series_pct_threshold=0.5
    )
    flagged = {r.date: r for r in results if r.is_anomaly}
    assert pts[15].date in flagged
    assert flagged[pts[15].date].method == "flat-baseline-pct"


def test_small_relative_wobble_is_not_flagged():
    pts = series(100.0, 30, spike_at=20, spike_mult=1.1)
    results = evaluate_series(pts, baseline_days=14, min_baseline_points=7)
    assert not any(r.is_anomaly for r in results)


def test_negligible_cost_series_is_not_flagged():
    pts = [DayPoint(f"2026-06-{i+1:02d}", 0.0) for i in range(10)] + [
        DayPoint("2026-06-11", 0.05)
    ]
    results = evaluate_series(
        pts, baseline_days=14, min_baseline_points=7, min_abs_cost=1.0
    )
    assert not any(r.is_anomaly for r in results)
