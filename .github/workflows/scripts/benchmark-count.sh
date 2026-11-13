#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of Swift project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

# Counts the heap allocations and the ARC traffic of one benchmark tool under valgrind, which
# makes both counts deterministic enough to compare across machines.
#
# Usage: benchmark-count.sh <tool> <binary-directory> <results-file>
#
# Writes one tab-separated line per metric and repeat to the results file:
#   <metric: allocations|arc> <repeat> <count>
#
# Allocations are the calls to the allocator (malloc, calloc, realloc and the aligned variants).
# ARC traffic is the calls to the Swift runtime's retain and release entry points. Both come from
# the call counts that callgrind records, so one run gives both.
#
# Valgrind runs the program tens of times slower, so the workloads are much smaller than a
# timed run would use. The counts are repeated to show how far from deterministic they are, since
# threads make some tools' counts vary a little between runs.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <tool> <binary-directory> <results-file>" >&2
    exit 2
fi

tool="$1"
binary="${2}/${tool}"
results_file="$3"

repeats=3

tool_arguments() {
    case "$1" in
    QUICTransfer) echo "-logging none -iterations 50" ;;
    QUICStreamLoad) echo "-logging none -stream-count 3000" ;;
    IPUDPTransfer) echo "-logging none -iterations 100" ;;
    *)
        echo "unknown tool: $1" >&2
        return 1
        ;;
    esac
}

arguments="$(tool_arguments "$tool")"
work_directory="$(mktemp -d)"

# Prints "<allocations> <arc>" from a callgrind profile: the calls recorded to the allocator and to
# the Swift runtime's retain and release functions. The profile writes each function name once, with
# a number, and refers to it by number afterwards.
summarize_profile() {
    awk '
        /^c?fn=/ {
            callee = ($0 ~ /^cfn=/)
            text = substr($0, index($0, "=") + 1)
            if (match(text, /^\([0-9]+\)/)) {
                id = substr(text, 2, RLENGTH - 2)
                name = substr(text, RLENGTH + 2)
                if (name != "") names[id] = name
                if (callee) pending = id
            }
            next
        }
        /^calls=/ {
            if (pending != "") {
                split($0, fields, /[= ]/)
                calls[pending] += fields[2]
                pending = ""
            }
            next
        }
        END {
            for (id in calls) {
                name = names[id]
                if (name ~ /^swift_(nonatomic_)?((retain|release)(_n)?|(bridgeObject|unknownObject|unowned)(Retain|Release)(_n)?)$/) {
                    arc += calls[id]
                } else if (name ~ /^(malloc|calloc|realloc|posix_memalign|aligned_alloc|memalign)$/) {
                    allocations += calls[id]
                }
            }
            printf "%.0f %.0f\n", allocations, arc
        }
    ' "$1"
}

# Runs the tool under callgrind and fails if it exits with an error or reports a failed run. The
# tools print a failed run on standard output and some still exit with success, so the output is
# checked too.
profile_tool() {
    local output report status=0
    output="${work_directory}/output"
    report="${work_directory}/report"
    # shellcheck disable=SC2086 # the arguments are deliberately split
    valgrind --tool=callgrind --fair-sched=yes --callgrind-out-file="$profile" \
        "$binary" $arguments >"$output" 2>"$report" || status=$?
    tail -n 3 "$report" >&2
    if [ "$status" -ne 0 ]; then
        echo "::error::${tool} exited with status ${status} under valgrind." >&2
        tail -n 20 "$output" >&2
        exit 1
    fi
    if grep -E 'Error running|Issue took place|something failed' "$output" >&2; then
        echo "::error::${tool} reported a failed run under valgrind." >&2
        exit 1
    fi
}

record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$results_file"
}

profile="${work_directory}/callgrind.out"
: >"$results_file"
for ((repeat = 1; repeat <= repeats; repeat++)); do
    echo "=== ${tool} repeat ${repeat} ===" >&2
    profile_tool
    read -r allocations arc < <(summarize_profile "$profile")
    # A Swift tool always allocates and retains, so a zero means the profile or the name patterns
    # above are wrong, and the comparison would silently report no change.
    if [ "$allocations" -eq 0 ] || [ "$arc" -eq 0 ]; then
        echo "::error::The callgrind profile for ${tool} has ${allocations} allocation calls and ${arc} ARC calls." >&2
        exit 1
    fi
    record allocations "$repeat" "$allocations"
    record arc "$repeat" "$arc"
done
