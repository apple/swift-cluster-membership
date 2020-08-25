#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Cluster Membership open source project
##
## Copyright (c) 2019 Apple Inc. and the Swift Cluster Membership project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -u

printf "=> Checking Samples/\n"
swift build --package-path Samples
printf "\033[0;32mokay.\033[0m\n"
