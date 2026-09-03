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

# Builds and tests the package on Linux.
#
# Usage: ci-linux.sh [swift flags...]
#
# The flags are the ones appended by the workflow (swift_flags /
# swift_nightly_flags).

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-support.sh
. "${script_dir}/ci-support.sh"

ci_run 'Build (default traits)' \
    swift build --build-tests --quiet "$@"
ci_run 'Build (additive traits on)' \
    swift build --build-tests --quiet \
    --traits DatapathLogging,QlogOutput,SignpostOutput "$@"
ci_run 'Build (reductive traits on)' \
    swift build --build-tests --quiet \
    --traits DisableDebugLogging,DisableErrorLogging "$@"
ci_run 'Test (debug)' \
    swift test --quiet -Xswiftc -DNETWORK_INTERNAL_TESTS "$@"
ci_run 'Test (release)' \
    swift test --quiet -c release -Xswiftc -DNETWORK_INTERNAL_TESTS "$@"

ci_finish
