# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# OpenSBI for the hidden-time boot test (htime_opensbi.sh). Source only: the
# test builds it with its own payload and device tree.

if ! [ -n "$OPENSBI_REPO" ]; then
  OPENSBI_REPO="https://github.com/riscv-software-src/opensbi.git"
  OPENSBI_BRANCH="master"
  OPENSBI_HASH="a32a91069119e7a5aa31e6bc51d5e00860be3d80" # v1.7
fi
echo "Repo:  " $OPENSBI_REPO
echo "Branch:" $OPENSBI_BRANCH
echo "Hash:  " $OPENSBI_HASH

if ! [ -n "$OPENSBI_DIR" ]; then
  OPENSBI_DIR=tools/opensbi
fi

if ! [ -d $OPENSBI_DIR ]; then
  git clone $OPENSBI_REPO -b $OPENSBI_BRANCH $OPENSBI_DIR
  cd $OPENSBI_DIR; git checkout $OPENSBI_HASH;
  cd -
fi
