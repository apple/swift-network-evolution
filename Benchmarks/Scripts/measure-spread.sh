#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See https://swift.org/LICENSE.txt for license information
## See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
##
##===----------------------------------------------------------------------===##

# Records the p90 thresholds several times and prints, for each benchmark and metric, the lowest
# and highest value seen. A metric whose spread is wider than its allowance in the benchmark
# source cannot hold a threshold.
#
# Run from the repository root:
#   Benchmarks/Scripts/measure-spread.sh [runs] [swift package arguments...]
# For example, `Benchmarks/Scripts/measure-spread.sh 5 --disable-sandbox`.

set -euo pipefail

runs="${1:-5}"
if [ "$#" -gt 0 ]; then shift; fi

scratch="Benchmarks/.spread"
trap 'rm -rf "$scratch"' EXIT
rm -rf "$scratch"

for run in $(seq 1 "$runs"); do
  echo "** Run $run of $runs" >&2
  swift package --package-path Benchmarks "$@" --allow-writing-to-package-directory \
    benchmark thresholds update \
    --format metricP90AbsoluteThresholds --path "$scratch/run-$run/" >&2
done

# Each file holds one `"metric" : value` pair per line.
for file in "$scratch/run-1"/*.json; do
  name="$(basename "$file")"
  for run in $(seq 1 "$runs"); do
    sed -n 's/^ *"\([A-Za-z]*\)" : \([0-9]*\),\{0,1\}$/\1 \2/p' "$scratch/run-$run/$name"
  done | awk -v name="${name%.p90.json}" '
    { if (!($1 in low) || $2 < low[$1]) low[$1] = $2
      if (!($1 in high) || $2 > high[$1]) high[$1] = $2 }
    END { for (metric in low) printf "%-70s %-16s %10d %10d %8d\n",
            name, metric, low[metric], high[metric], high[metric] - low[metric] }' | sort
done
