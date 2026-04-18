#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

cd "$ROOT_DIR"

status=0

check_pattern() {
  pattern=$1
  description=$2

  if matches=$(rg -n --fixed-strings --glob '*.swift' --glob '!Sources/OmniWM/Core/Platform/**' "$pattern" Sources/OmniWM); then
    printf '%s\n%s\n\n' "$description" "$matches" >&2
    status=1
  fi
}

check_pattern '@_silgen_name' 'Private API symbol declarations leaked outside Core/Platform:'
check_pattern 'import SkyLight' 'SkyLight imports leaked outside Core/Platform:'
check_pattern 'SkyLight.shared' 'SkyLight singleton usage leaked outside Core/Platform:'
check_pattern '_AXUIElementGetWindow' 'Raw AX window FFI leaked outside Core/Platform:'
check_pattern '_SLPSSetFrontProcessWithOptions' 'Private process focus FFI leaked outside Core/Platform:'
check_pattern 'SLPSPostEventRecordTo' 'Private event posting FFI leaked outside Core/Platform:'
check_pattern 'GetProcessForPID' 'Private process lookup FFI leaked outside Core/Platform:'

exit "$status"
