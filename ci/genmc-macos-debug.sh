#!/usr/bin/env bash
# Debugging helper for GenMC on macOS (temporary, not meant to be merged).
#
# Usage:
#   ci/genmc-macos-debug.sh configure <variant>  set up the build environment for a variant (see below)
#   ci/genmc-macos-debug.sh build-info           print how GenMC and Miri were actually built
#   ci/genmc-macos-debug.sh probe                check whether Apple's toolchain memcpy's ilists in vectors
#   ci/genmc-macos-debug.sh direct <test.rs>     run one test via `./miri run`
#   ci/genmc-macos-debug.sh suite <filter>       run `./miri test <filter>` (uses MIRIFLAGS from the environment)
#
# Anything still running after HANG_SECS seconds is considered hung: we print the stacks of all
# interpreter processes and kill them.
set -u

FEATURES="--features=expensive-consistency-checks,genmc"
GENMC_FLAGS="-Zmiri-genmc -Zmiri-disable-stacked-borrows -Zmiri-genmc-print-genmc-output"

# Append `VAR=value` to the environment of all later steps.
set_env() {
  echo "$1=$2" | tee -a "$GITHUB_ENV"
}

# Clone GenMC at the commit pinned in genmc-sys/build.rs and print its path.
clone_genmc() {
  local commit src
  commit=$(grep -oE 'GENMC_COMMIT: &str = "[0-9a-f]+"' genmc-sys/build.rs | grep -oE '[0-9a-f]{40}')
  src="$RUNNER_TEMP/genmc"
  git clone --quiet https://github.com/MPI-SWS/genmc.git "$src" >&2 || return 1
  git -C "$src" checkout --quiet "$commit" >&2 || return 1
  echo "$src"
}

# Make Miri use the system allocator for C/C++ code (and everything else) instead of jemalloc.
disable_jemalloc_override() {
  perl -pi -e 's{^rustc_driver::override_c_allocator_in_binary!\(\);}{// TEMP(genmc-macos-debug): C allocator override disabled}' src/bin/miri.rs
  grep -q "C allocator override disabled" src/bin/miri.rs || { echo "failed to disable jemalloc"; exit 1; }
}

configure() {
  case "$1" in
    homebrew-llvm)
      # Build GenMC and the C++ bridge with Homebrew's clang and libc++ instead of Apple's
      # (the setup that passes on an Intel Mac).
      HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew install llvm || exit 1
      local llvm
      llvm=$(brew --prefix llvm)
      for v in CC HOST_CC CC_aarch64_apple_darwin; do set_env "$v" "$llvm/bin/clang"; done
      for v in CXX HOST_CXX CXX_aarch64_apple_darwin; do set_env "$v" "$llvm/bin/clang++"; done
      set_env SDKROOT "$(xcrun --show-sdk-path)"
      set_env MACOSX_DEPLOYMENT_TARGET 15.0
      set_env CXXFLAGS "-nostdinc++ -isystem $llvm/include/c++/v1"
      set_env RUSTFLAGS "-C link-arg=-L$llvm/lib/c++ -C link-arg=-Wl,-rpath,$llvm/lib/c++"
      ;;
    apple-O0)
      # Apple clang, but GenMC and the C++ bridge are built without optimizations.
      set_env GENMC_CMAKE_PROFILE Debug
      ;;
    apple-asan)
      # Apple clang with ASan+UBSan for GenMC and the C++ bridge.
      # ASan has to provide malloc, so we cannot use jemalloc.
      disable_jemalloc_override
      local rt_dir
      rt_dir="$(xcrun clang -print-resource-dir)/lib/darwin"
      ls "$rt_dir/libclang_rt.asan_osx_dynamic.dylib" || exit 1
      set_env CXXFLAGS "-fsanitize=address,undefined -fno-sanitize=vptr,function -fno-omit-frame-pointer"
      # Link the ASan runtime only into binaries that contain GenMC (not into proc macros, which
      # would load it too late via dlopen).
      set_env GENMC_ASAN_RT_DIR "$rt_dir"
      set_env RUSTFLAGS "-C link-arg=-Wl,-rpath,$rt_dir"
      set_env ASAN_OPTIONS "detect_leaks=0:abort_on_error=0:halt_on_error=1"
      set_env UBSAN_OPTIONS "print_stacktrace=1:halt_on_error=0"
      ;;
    apple-no-jemalloc)
      # Control for apple-asan: only switch the allocator.
      disable_jemalloc_override
      ;;
    apple-deque)
      # Apple clang, with GenMC patched to keep the per-thread po-lists in a std::deque.
      # Apple's libc++ (LLVM 19) grows a std::vector by memcpy'ing elements that AppleClang's
      # `__is_trivially_relocatable` claims are trivially relocatable, even if they have a
      # non-trivial move constructor (fixed in libc++ 20 by llvm/llvm-project#124970).
      # `genmc::ilist` must not be memcpy'd (its nodes point to its sentinel), and a deque
      # never relocates its elements when growing.
      local src
      src=$(clone_genmc) || exit 1
      perl -pi -e 's{using PoLists = std::vector<PoList>;}{using PoLists = std::deque<PoList>;}; s{^(#include <algorithm>)}{$1\n#include <deque>}' \
        "$src/genmc/genmc/Execution/ExecutionGraph.hpp"
      git -C "$src" diff
      git -C "$src" diff --quiet && { echo "patch did not apply"; exit 1; }
      set_env GENMC_SRC_PATH "$src"
      ;;
    apple-ilist-dtor)
      # Apple clang, with `genmc::ilist` given a user-provided destructor (so that it is not
      # trivially relocatable for any compiler) and a static_assert checking exactly that.
      local src
      src=$(clone_genmc) || exit 1
      git -C "$src" apply "$PWD/ci/genmc-ilist-dtor.patch" || exit 1
      git -C "$src" diff
      set_env GENMC_SRC_PATH "$src"
      ;;
    *)
      echo "unknown variant: $1"
      exit 2
      ;;
  esac
}

build_info() {
  local cache
  cache=$(ls -t target/debug/build/genmc-sys-*/out/genmc/build/CMakeCache.txt | head -1)
  echo "##### $cache"
  grep -E '^CMAKE_(CXX_COMPILER|BUILD_TYPE|CXX_FLAGS|CXX_FLAGS_[A-Z]+|OSX_DEPLOYMENT_TARGET|OSX_SYSROOT)(:[A-Z]+)?=' "$cache"
  echo "##### linked libraries of target/debug/miri"
  otool -L target/debug/miri
  echo "##### jemalloc symbols in target/debug/miri: $(nm target/debug/miri | grep -ciE 'rjem|je_arena|jemalloc')"
}

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
  configure)
    configure "$2"
    ;;
  build-info)
    build_info
    ;;
  probe)
    # Does the default toolchain grow a std::vector of ilist-like types with memcpy?
    xcrun clang++ -std=c++23 -O2 ci/genmc-relocation-probe.cpp -o "$RUNNER_TEMP/probe" || exit 1
    "$RUNNER_TEMP/probe"
    ;;
  direct)
    run_with_watchdog "${HANG_SECS:-300}" ./miri run --dep $FEATURES "$2" $GENMC_FLAGS
    rc=$?
    echo "##### exit code $rc"
    exit $rc
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
