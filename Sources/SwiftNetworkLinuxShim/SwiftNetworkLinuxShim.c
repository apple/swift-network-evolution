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

#ifdef __linux__

#ifndef _GNU_SOURCE
#error You must define _GNU_SOURCE
#endif

#include <SwiftNetworkLinuxShim.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/resource.h>

char * SwiftNetworkLinuxShim_if_indextoname(int index, char * name)
{
    if (index < 0) {
        return NULL;
    }
    return if_indextoname((unsigned int)index, name);
}

uint64_t SwiftNetworkLinuxShim_getFDLimit()
{
    struct rlimit existing_limit;

    if (getrlimit(RLIMIT_NOFILE, &existing_limit) == 0) {
        return (uint64_t)existing_limit.rlim_cur;
    }
    return 0;
}

int SwiftNetworkLinuxShim_ioctl(int fd, unsigned long request, void * arg)
{
#if defined(__ANDROID__)
    return ioctl(fd, (unsigned)request, arg);
#else
    return ioctl(fd, request, arg);
#endif
}

#endif
