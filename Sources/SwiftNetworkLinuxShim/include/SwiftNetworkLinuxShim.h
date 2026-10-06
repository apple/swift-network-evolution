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

#ifndef SWIFTNETWORKLINIXSHIM
#define SWIFTNETWORKLINIXSHIM

#ifdef __linux__

#include <stdio.h>
// We cannot just use "ifdef NETLINK_ENABLED" because
// flags from Package.swift don't get propagated here.
#if __has_include(<linux/netlink.h>)
    #include <linux/netlink.h>
    #include <linux/rtnetlink.h>
#endif
#include <arpa/inet.h>

// Not exposed in Glibc.swiftmodule. Bionic's ioctl is variadic and unavailable from Swift.
char * _Nullable SwiftNetworkLinuxShim_if_indextoname(int index, char * _Nullable name);
uint64_t SwiftNetworkLinuxShim_getFDLimit();
int SwiftNetworkLinuxShim_ioctl(int fd, unsigned long request, void * _Nonnull arg);

#endif // __linux__
#endif // SWIFTNETWORKLINIXSHIM
