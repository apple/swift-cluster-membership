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

set -eu
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

printf "=> Checking docs\n"

printf "   * api docs... "
api_out=$("$here/docs/generate_api.sh" 2>&1)
if [[ "$api_out" != *"jam out"* ]]; then
  printf "\033[0;31merror!\033[0m\n"
  echo "$api_out"
  exit 1
fi
printf "\033[0;32mokay.\033[0m\n"
