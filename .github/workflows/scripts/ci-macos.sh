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

# Builds the package for every Apple platform with xcodebuild, then runs the
# test suite on macOS.
#
# Usage: ci-macos.sh [swift flags...]
#
# The flags are forwarded to `swift test` only. The xcodebuild invocations take
# their settings from the scheme, which is how this worked before the commands
# were moved out of the workflow file.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-support.sh
. "${script_dir}/ci-support.sh"

scheme='swift-network-evolution-Package'

# xcodebuild_step <name> <destination>
xcodebuild_step() {
    ci_run "$1" /usr/bin/xcodebuild -quiet -scheme "${scheme}" -destination "$2" build
}

xcodebuild_step 'macOS build' 'generic/platform=macos,variant=macos'
xcodebuild_step 'Mac Catalyst build' 'generic/platform=macos,variant=Mac Catalyst'
xcodebuild_step 'iOS build' 'generic/platform=ios'
xcodebuild_step 'watchOS build' 'generic/platform=watchos'
xcodebuild_step 'tvOS build' 'generic/platform=tvos'
xcodebuild_step 'visionOS build' 'generic/platform=visionos'

ci_run 'swift test' xcrun swift test --quiet -Xswiftc -DNETWORK_INTERNAL_TESTS "$@"

ci_finish
