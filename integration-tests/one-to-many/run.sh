#!/bin/bash
set -euo pipefail

dub build
$RORM_CLI make-migrations
$RORM_CLI migrate --log-sql
./one-to-many
