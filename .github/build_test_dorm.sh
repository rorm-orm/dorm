#!/usr/bin/env bash

# This script relies on a valid environment, it's only used in the GitHub CI!

set -e
set -x
dub build
dub test
pushd testapp
dub build
popd
cd integration-tests
./run.sh
