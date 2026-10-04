#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs
# SPDX-License-Identifier: Apache-2.0
# A descendant may keep stdout open after the foreground command exits.
# Own the log file here so PowerShell does not wait for that pipe's EOF.
set -uo pipefail
if [ "$#" -lt 2 ]; then
  echo "usage: capture-command.sh LOG COMMAND [ARG ...]" >&2
  exit 2
fi
log_path=$1
shift
command_status=0
"$@" >"$log_path" 2>&1 || command_status=$?
printf 'capture-command: status=%s log=%s\n' "$command_status" "$log_path"
exit "$command_status"
