#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs
# SPDX-License-Identifier: Apache-2.0
# Keep CI completion tied to the foreground command's exit status. A shared
# background service may retain an inherited writer after that command exits.
set -uo pipefail
if [ "$#" -lt 2 ]; then
  echo "usage: capture-ci-command.sh LOG COMMAND [ARG ...]" >&2
  exit 2
fi
log_path=$1
shift
tail_lines=${REPRO_DIAGNOSTIC_TAIL_LINES:-}
if [[ -n "$tail_lines" && ! "$tail_lines" =~ ^[1-9][0-9]*$ ]]; then
  echo "REPRO_DIAGNOSTIC_TAIL_LINES must be a positive integer" >&2
  exit 2
fi
log_reader=(cat)
if [[ -n "$tail_lines" ]]; then
  log_reader=(tail -n "$tail_lines")
fi
command_status=0
"$@" >"$log_path" 2>&1 || command_status=$?
# Keep the complete file for artifacts even when console output is bounded.
if ! "${log_reader[@]}" -- "$log_path"; then
  if [ "$command_status" -eq 0 ]; then command_status=1; fi
fi
exit "$command_status"
