#!/usr/bin/env bash
# Builds terra_core for the host and runs the native test suite, including a
# replay of nrsc5's bundled hybrid FM capture.
#
#   tooling/native_test.sh [ctest args...]     e.g. -R rds -V
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/native/build/host"
sample_xz="$root/third_party/nrsc5/support/sample.xz"
sample="$root/native/build/sample.cu8"

if [[ ! -f "$root/third_party/nrsc5/.terra-stamp" ]]; then
  "$root/tooling/fetch_third_party.sh"
fi

if [[ ! -f "$sample" && -f "$sample_xz" ]]; then
  echo "Decompressing nrsc5 sample capture..."
  mkdir -p "$(dirname "$sample")"
  if command -v xz >/dev/null; then
    xz -dc "$sample_xz" > "$sample.tmp"
  else
    python3 -c "import lzma,shutil,sys; shutil.copyfileobj(lzma.open(sys.argv[1]), open(sys.argv[2],'wb'))" \
      "$sample_xz" "$sample.tmp"
  fi
  mv "$sample.tmp" "$sample"
fi

generator=()
if command -v ninja >/dev/null; then generator=(-G Ninja); fi
cmake -S "$root/native" -B "$build" ${generator[@]+"${generator[@]}"} \
  -DCMAKE_BUILD_TYPE=Release -DTERRA_BUILD_TESTS=ON \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
cmake --build "$build" -j "$jobs"

export TERRA_SAMPLE_IQ="$sample"
ctest --test-dir "$build" --output-on-failure "$@"
