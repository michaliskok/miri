#!/usr/bin/env bash
# Debugging helper for GenMC on macOS (temporary, not meant to be merged).
#
# Usage:
#   ci/genmc-macos-debug.sh direct <test.rs>   run one test via `./miri run`, without and with GC stress
#   ci/genmc-macos-debug.sh suite <filter>     run `./miri test <filter>` (uses MIRIFLAGS from the environment)
#
# Anything still running after HANG_SECS seconds is considered hung: we print the stacks of all
# interpreter processes and kill them.
set -u

FEATURES="--features=expensive-consistency-checks,genmc"
GENMC_FLAGS="-Zmiri-genmc -Zmiri-disable-stacked-borrows -Zmiri-genmc-print-genmc-output"

dump_miri_processes() {
  for pid in $(pgrep -f "target/debug/miri "); do
    echo "##### miri process $pid (running for $(ps -o etime= -p "$pid")): $(ps -o command= -p "$pid" | grep -oE 'tests/[^ ]+\.rs')"
    sample "$pid" 3 -file "/tmp/sample-$pid.txt" > /dev/null 2>&1
    sed -n '/Call graph:/,/Total number in stack/p' "/tmp/sample-$pid.txt" | head -200
  done
}

run_with_watchdog() {
  local hang_secs=$1
  shift
  "$@" &
  local pid=$!
  local start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    if (( $(date +%s) - start >= hang_secs )); then
      echo "##### TIMEOUT after ${hang_secs}s: $*"
      dump_miri_processes
      pkill -KILL -f "target/debug/miri "
      # Give ui_test a chance to report the killed tests as failures.
      sleep 30
      kill "$pid" 2>/dev/null
      wait "$pid"
      return 124
    fi
    sleep 5
  done
  wait "$pid"
}

case "$1" in
  direct)
    FILE=$2
    status=0
    for gc in "" "-Zmiri-provenance-gc=1"; do
      echo "##### $FILE ${gc:-(no GC stress)}"
      run_with_watchdog "${HANG_SECS:-300}" \
        ./miri run --dep $FEATURES "$FILE" $GENMC_FLAGS $gc
      rc=$?
      echo "##### exit code $rc"
      [ $rc -ne 0 ] && status=1
    done
    exit $status
    ;;
  suite)
    echo "##### ./miri test $2 (MIRIFLAGS=${MIRIFLAGS-})"
    run_with_watchdog "${HANG_SECS:-1500}" ./miri test $FEATURES "$2"
    ;;
  *)
    echo "unknown mode: $1"
    exit 2
    ;;
esac
