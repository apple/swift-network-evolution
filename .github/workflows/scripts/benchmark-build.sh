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

# Builds the benchmark tools at one commit and copies the binaries out.
#
# Usage: benchmark-build.sh <sha> <destination-directory> <tools> [pull-request-number]
#
# <tools> is a comma-separated list of the tool products to build.
#
# With a pull request number, <sha> is fetched from the pull request and the script
# fails if the pull request has moved on from that commit, so the commit that was
# authorized is the commit that gets measured.
#
# The script is copied out of the workspace before it runs, because checking out
# <sha> replaces the files in the workspace.

set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <sha> <destination-directory> <tools> [pull-request-number]" >&2
    exit 2
fi

sha="$1"
destination="$2"
pull_request_number="${4:-}"

IFS=, read -r -a tools <<<"$3"

# Logging is compiled out, so the counts measure the datapath and not the logger.
traits="DisableDebugLogging,DisableErrorLogging"

if [ -n "$pull_request_number" ]; then
    git fetch --quiet origin "pull/${pull_request_number}/head"
    fetched_sha="$(git rev-parse FETCH_HEAD)"
    if [ "$fetched_sha" != "$sha" ]; then
        echo "::error::The pull request is now at ${fetched_sha}, not the ${sha} that was authorized. Comment /benchmark again."
        exit 1
    fi
fi

git checkout --quiet --detach "$sha"

product_arguments=()
for tool in "${tools[@]}"; do
    product_arguments+=(--product "$tool")
done
swift build -c release --traits "$traits" "${product_arguments[@]}"

binary_directory="$(swift build -c release --show-bin-path)"
mkdir -p "$destination"
for tool in "${tools[@]}"; do
    cp "${binary_directory}/${tool}" "${destination}/${tool}"
done
