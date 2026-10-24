#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""analyze_jtl.py —— 解析 JMeter jtl 结果文件，输出 markdown 汇总表。

为什么自己写而不只看聚合报告/HTML dashboard：
1. jtl 是 CSV 纯文本，跨机器可比较、可进 git、可被 CI 当产物归档；
2. 一条命令出 P50/P90/P95/P99，转报告时不用逐个打开 HTML；
3. 教学：让新手看清"TPS/错误率/分位值到底是从哪些原始字段算出来的"。

指标口径（与 docs/01-压测场景设计.md 对齐）：
    总请求数   = jtl 行数（每个采样一行）
    错误率     = success == False 的行数 / 总行数（JMeter 的 success 已包含断言结果）
    实际时长   = (max(timeStamp + elapsed) - min(timeStamp)) / 1000 秒
                 —— 第一笔请求发出到最后一笔请求返回的墙钟时间
    TPS        = 总请求数 / 实际时长（工程口径，与 dashboard 的 throughput 一致）
    平均/P50/P90/P95/P99/max = elapsed（响应时间，毫秒）的分位数，线性插值法

用法：
    python scripts/analyze_jtl.py results/smoke.jtl
    python scripts/analyze_jtl.py results/goods_dev_t50.jtl results/goods_dev_t100.jtl
    python scripts/analyze_jtl.py results/goods_dev_t*.jtl     # 支持通配符（shell 展开）
纯标准库，Python 3.8+ 可跑。
"""

import csv
import glob
import sys


def load_jtl(path):
    """读取一个 jtl，返回 (请求数, 错误数, 响应时间列表, 实际时长秒)。

    jtl 首行是表头，关键列：
        timeStamp —— 采样开始时刻（epoch 毫秒）
        elapsed   —— 响应时间（毫秒）
        success   —— True/False（断言失败也会置为 False）
    """
    n = err = 0
    times, ts_start, ts_end = [], None, None
    with open(path, encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            n += 1
            if row["success"].strip().lower() != "true":
                err += 1
            elapsed = int(row["elapsed"])
            times.append(elapsed)
            start = int(row["timeStamp"])
            end = start + elapsed          # 该请求"完成"的时刻
            ts_start = start if ts_start is None else min(ts_start, start)
            ts_end = end if ts_end is None else max(ts_end, end)
    duration = (ts_end - ts_start) / 1000.0 if ts_start is not None else 0.0
    return n, err, times, duration


def percentile(sorted_vals, p):
    """线性插值分位数。p 取 0~100。与 Excel PERCENTILE.INC 口径一致，
    也接近 JMeter HTML dashboard 的 Aggregate percentile 聚合口径。"""
    if not sorted_vals:
        return 0.0
    k = (len(sorted_vals) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def analyze(path):
    n, err, times, duration = load_jtl(path)
    times.sort()
    stats = {
        "file": path,
        "total": n,
        "errors": err,
        "error_rate": err / n * 100 if n else 0.0,
        "duration": duration,
        "tps": n / duration if duration > 0 else 0.0,
        "avg": sum(times) / n if n else 0.0,
        "p50": percentile(times, 50),
        "p90": percentile(times, 90),
        "p95": percentile(times, 95),
        "p99": percentile(times, 99),
        "max": times[-1] if times else 0.0,
    }
    return stats


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    # 支持通配符（Windows cmd 不展开 *，这里兜底）
    paths = []
    for pat in sys.argv[1:]:
        hit = glob.glob(pat)
        paths.extend(hit if hit else [pat])

    print("| 结果文件 | 总请求 | 错误数 | 错误率 | 时长(s) | TPS | 平均(ms) | P50 | P90 | P95 | P99 | max |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for p in paths:
        s = analyze(p)
        print(f"| {s['file']} | {s['total']} | {s['errors']} | {s['error_rate']:.2f}% | "
              f"{s['duration']:.1f} | {s['tps']:.1f} | {s['avg']:.1f} | {s['p50']:.0f} | "
              f"{s['p90']:.0f} | {s['p95']:.0f} | {s['p99']:.0f} | {s['max']:.0f} |")


if __name__ == "__main__":
    main()
