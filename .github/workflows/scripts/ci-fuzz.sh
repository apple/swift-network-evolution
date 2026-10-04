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

# Runs the fuzz targets, each for its own duration. Shared by two workflows:
# fuzz-nightly.yml calls this with long durations and persists the corpus across
# runs via actions/cache, for deep, cumulative fuzzing; pull_request.yml's
# fuzz-smoke job calls this with short durations and no persisted corpus, as a
# quick per-PR smoke check that the fuzz targets still build and don't crash
# immediately.
#
# Durations are per target rather than shared because the targets cover very
# different amounts of code: FuzzQUICPackets reaches the whole connection and
# frame-processing machinery and keeps finding coverage for a long time, while
# FuzzTransportParameters exercises one deserializer and saturates quickly, so
# extra time there buys little.
#
# Each target gets its own corpus subdirectory under FUZZ_CORPUS_DIR, which the
# calling workflow persists across runs (e.g. via actions/cache) so coverage
# accumulates day over day instead of restarting from empty every time.
# libFuzzer writes any crash-*/oom-*/timeout-* artifact directly into that same
# subdirectory (via -artifact_prefix), so the workflow can find and upload them
# after this script exits, regardless of whether it exits 0 or non-zero.
#
# Every target always runs, even if an earlier one finds a crash - this script
# only reports the overall failure (via ci_finish's exit code) once they have
# all had a chance to run, matching ci-linux.sh's "run every step" philosophy.
#
# Usage: ci-fuzz.sh <target>=<seconds> [<target>=<seconds> ...]
#
#   e.g. ci-fuzz.sh FuzzQUICPackets=120 FuzzTransportParameters=30
#
# Env:
#   FUZZ_CORPUS_DIR - where the persisted corpus/crash artifacts live
#                     (default: fuzz-corpus)

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-support.sh
. "${script_dir}/ci-support.sh"

corpus_root="${FUZZ_CORPUS_DIR:-fuzz-corpus}"

usage() {
    echo "usage: $(basename "$0") <target>=<seconds> [<target>=<seconds> ...]" >&2
    echo "   e.g. $(basename "$0") FuzzQUICPackets=120 FuzzTransportParameters=30" >&2
    exit 2
}

fuzz_target() {
    local binary="$1"
    local seconds="$2"
    local corpus_dir="${corpus_root}/${binary}"
    mkdir -p "${corpus_dir}"
    ci_run "Fuzz ${binary} (${seconds}s)" \
        ".build/release/${binary}" \
        -max_total_time="${seconds}" \
        -artifact_prefix="${corpus_dir}/" \
        "${corpus_dir}"
}

[ "$#" -gt 0 ] || usage

# Validate everything up front, so a typo fails immediately instead of after
# the first target has already fuzzed for several minutes.
for spec in "$@"; do
    case "${spec}" in
        *=*) ;;
        *) echo "error: expected <target>=<seconds>, got '${spec}'" >&2; usage ;;
    esac
    binary="${spec%%=*}"
    seconds="${spec##*=}"
    case "${seconds}" in
        '' | *[!0-9]*)
            echo "error: '${seconds}' is not a whole number of seconds, in '${spec}'" >&2
            usage
            ;;
    esac
    if [ ! -x ".build/release/${binary}" ]; then
        echo "error: .build/release/${binary} is missing or not executable" >&2
        exit 2
    fi
done

for spec in "$@"; do
    fuzz_target "${spec%%=*}" "${spec##*=}"
done

ci_finish
