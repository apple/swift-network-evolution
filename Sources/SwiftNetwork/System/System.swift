//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !NETWORK_EMBEDDED && canImport(Dispatch)
import Dispatch
#endif

#if canImport(Android)
import Android
internal import Logging
#elseif canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if NETWORK_DRIVERKIT
#if canImport(DriverKitRuntime.Mach.mach_time)
internal import DriverKitRuntime.Mach.mach_time
#endif
#endif

@available(Network 0.1.0, *)
internal struct System {

    struct Time {
        static let NSEC_PER_USEC = UInt64(
            Duration.microseconds(1) / Duration.nanoseconds(1)
        ) /* nanoseconds per microsecond */
        static let USEC_PER_SEC = UInt64(Duration.seconds(1) / Duration.microseconds(1)) /* microseconds per second */
        static let NSEC_PER_SEC = UInt64(Duration.seconds(1) / Duration.nanoseconds(1)) /* nanoseconds per second */
        static let NSEC_PER_MSEC = UInt64(
            Duration.milliseconds(1) / Duration.nanoseconds(1)
        ) /* nanoseconds per millisecond */
        static let USEC_PER_MSEC = UInt64(
            Duration.milliseconds(1) / Duration.microseconds(1)
        ) /* microseconds per millisecond */

        #if os(Linux) || os(Android) || (NETWORK_STANDALONE && !NETWORK_DRIVERKIT)
        private static let timebaseNumerator: UInt64 = 0
        private static let timebaseDenominator: UInt64 = 0
        #else
        private static let timebaseInfo: mach_timebase_info_data_t = {
            var info = mach_timebase_info_data_t(numer: 1, denom: 1)
            mach_timebase_info(&info)
            return info
        }()
        private static let timebaseNumerator = UInt64(timebaseInfo.numer)
        private static let timebaseDenominator = UInt64(timebaseInfo.denom)
        #endif

        static func now() -> UInt64 {
            #if os(Linux) || os(Android)
            return DispatchTime.now().uptimeNanoseconds / Time.NSEC_PER_USEC
            #elseif NETWORK_STANDALONE && !NETWORK_DRIVERKIT
            return 0
            #else
            /*
             * mach_continuous_time() is used to make sure our timers keep running when the
             * device goes to sleep.
             * This allow us to idle timeout a connection when waking up from sleep.
             */
            let continuousTime = mach_continuous_time()
            let nanoseconds = (continuousTime * Time.timebaseNumerator) / Time.timebaseDenominator

            return nanoseconds / System.Time.NSEC_PER_USEC
            #endif
        }

        static func nowAbsoluteNanoseconds() -> UInt64 {
            #if os(Linux) || os(Android)
            return DispatchTime.now().uptimeNanoseconds
            #elseif NETWORK_STANDALONE && !NETWORK_DRIVERKIT
            return 0
            #else
            let absoluteTime = mach_absolute_time()
            let nanoseconds = (absoluteTime * Time.timebaseNumerator) / Time.timebaseDenominator

            return nanoseconds
            #endif
        }

        static func nanosecondsToAbsolute(nanoseconds: UInt64) -> UInt64 {
            // N.B.: swapped numerator/denominator
            nanoseconds * timebaseDenominator / timebaseNumerator
        }
    }
}
