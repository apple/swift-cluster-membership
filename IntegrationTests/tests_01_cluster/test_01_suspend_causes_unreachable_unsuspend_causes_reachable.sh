#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Cluster Membership open source project
##
## Copyright (c) 2020 Apple Inc. and the Swift Cluster Membership project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -e
#set -x # verbose

declare -r my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r root_path="$my_path/.."

declare -r app_name='it_Clustered_swim_suspension_reachability'

source ${my_path}/shared.sh

declare -r first_logs=/tmp/first.out
declare -r second_logs=/tmp/second.out
rm -f ${first_logs}
rm -f ${second_logs}

# TODO: No integration tests yet; we run such peer to peer tests as part of the XCTest test suite.

# === cleanup ----------------------------------------------------------------------------------------------------------

_killall ${app_name}
