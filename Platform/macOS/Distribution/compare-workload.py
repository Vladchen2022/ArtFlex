#!/usr/bin/env python3
"""Compare identical opt-in workload logs; exclude first warmup, report nearest-rank tails."""
import argparse
import json
import math
from pathlib import Path

def read(path):
    groups = {}
    for line in Path(path).read_text().splitlines():
        if not line.startswith('WORKLOAD_BENCH '):
            continue
        row = json.loads(line.partition(' ')[2])
        if row['sample'] > 0:
            groups.setdefault((row['side'], row['format']), []).append(row)
    if not groups:
        raise ValueError('No measured workloads; enable ARTFLEX_RUN_WORKLOAD_BENCHMARK=1')
    return groups

def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)]

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before'); parser.add_argument('after')
    parser.add_argument('--maximum-regression', type=float, default=0.2)
    parser.add_argument('--enforce', action='store_true')
    args = parser.parse_args()
    before, after = read(args.before), read(args.after)
    if before.keys() != after.keys():
        raise ValueError('Workload matrix differs')
    regressions = []
    for key in sorted(before):
        for metric in ('stroke_ms', 'commit_ms', 'undo_ms', 'redo_ms', 'save_ms', 'save_prepare_ms'):
            a, b = [row[metric] for row in before[key]], [row[metric] for row in after[key]]
            old, new = percentile(a, .95), percentile(b, .95)
            delta = new / old - 1 if old > 0 else 0
            row = dict(side=key[0], format=key[1], metric=metric, samples=[len(a), len(b)],
                       before_median=percentile(a, .5), after_median=percentile(b, .5),
                       before_p95=old, after_p95=new, relative_change=delta)
            print(json.dumps(row, sort_keys=True))
            if delta > args.maximum_regression:
                regressions.append(row)
    if args.enforce and regressions:
        raise SystemExit(f'{len(regressions)} tail-latency regressions exceed the agreed threshold')
