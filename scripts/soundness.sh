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

bash $here/validate_license_header.sh
bash $here/validate_format.sh
bash $here/validate_samples.sh
