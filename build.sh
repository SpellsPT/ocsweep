#!/usr/bin/env bash
# build.sh — build every test tool for every NVIDIA GPU architecture found in this machine.
#
#   ./build.sh            build what is missing
#   ./build.sh --clean    rebuild everything
#
# Needs: nvidia-smi, a CUDA toolkit (nvcc), gcc, make, cmake, git. Finds nvcc via $CUDA_HOME (set it in ocsweep.conf
# for a toolkit in an unusual place), PATH, /usr/local/cuda, or the newest /usr/local/cuda-*. Third-party tools are cloned from GitHub at pinned commits:
#   wilicc/gpu-burn                               (BSD-2)       compute + tensor-core stress with result checking
#   ComputationalRadiationPhysics/cuda_memtest    (NCSA/Illinois) VRAM pattern tests
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
CONF=${OCSWEEP_CONF:-$D/ocsweep.conf}; [ -f "$CONF" ] && . "$CONF"
GPUBURN_REPO=https://github.com/wilicc/gpu-burn;                         GPUBURN_REF=3ead140
MEMTEST_REPO=https://github.com/ComputationalRadiationPhysics/cuda_memtest; MEMTEST_REF=e94e1ee
[ "${1:-}" = --clean ] && rm -rf "$D/bin" "$D/build"
mkdir -p "$D/bin" "$D/build" "$D/third_party"

find_nvcc() {
  local c
  for c in "${CUDA_HOME:-}/bin/nvcc" "$(command -v nvcc 2>/dev/null || true)" /usr/local/cuda/bin/nvcc \
           $(ls -d /usr/local/cuda-*/bin/nvcc 2>/dev/null | sort -V -r); do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done; return 1
}
NVCC=$(find_nvcc) || { echo "no nvcc found — install a CUDA toolkit or set CUDA_HOME in ocsweep.conf"; exit 1; }
CUDA=$(dirname "$(dirname "$NVCC")")
ARCHS=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | tr -d ' .' | sort -u)
[ -n "$ARCHS" ] || { echo "nvidia-smi found no GPUs"; exit 1; }
echo "nvcc: $NVCC ($("$NVCC" --version | grep -o 'release [0-9.]*'))   GPU architectures: $(echo $ARCHS | sed 's/[0-9]*/sm_&/g')"
SUPPORTED=$("$NVCC" --list-gpu-arch 2>/dev/null || true)
for a in $ARCHS; do
  grep -qx "compute_$a" <<< "$SUPPORTED" || { echo "this nvcc cannot build sm_$a — install a newer CUDA toolkit"; exit 1; }
done
pinned() {  # pinned DIR REPO REF — clone once, then make sure the checkout IS the pinned commit, every run
  [ -d "$1/.git" ] || git clone -q "$2" "$1"
  git -C "$1" checkout -q "$3" 2>/dev/null || git -C "$1" fetch -q origin && git -C "$1" checkout -q "$3"
  case "$(git -C "$1" rev-parse HEAD)" in "$3"*) ;; *) echo "$1 is not at the pinned commit $3 — delete $1 and re-run"; exit 1 ;; esac
}

# ── our own tools ──
gcc -O2 -Wall -o "$D/bin/vramtemp" "$D/src/vramtemp.c"
for a in $ARCHS; do
  [ "$D/bin/vrambench-sm$a" -nt "$D/src/vrambench.cu" ] || { echo "building vrambench sm_$a"; "$NVCC" -O3 -arch=sm_$a -o "$D/bin/vrambench-sm$a" "$D/src/vrambench.cu"; }
done

# ── gpu-burn: one build per architecture (it loads compare.fatbin from its working directory) ──
pinned "$D/third_party/gpu-burn" "$GPUBURN_REPO" "$GPUBURN_REF"
for a in $ARCHS; do
  o="$D/bin/gpu-burn-sm$a"
  [ -x "$o/gpu_burn" ] && continue
  echo "building gpu-burn sm_$a"
  rm -rf "$D/build/gpu-burn-sm$a"; cp -a "$D/third_party/gpu-burn" "$D/build/gpu-burn-sm$a"
  make -s -C "$D/build/gpu-burn-sm$a" COMPUTE="$a" CUDAPATH="$CUDA" >/dev/null
  mkdir -p "$o"; cp "$D/build/gpu-burn-sm$a/gpu_burn" "$D/build/gpu-burn-sm$a/compare.fatbin" "$o/"
done

# ── cuda_memtest: one binary for all architectures ──
want=$(echo $ARCHS | tr ' ' ';')
if [ ! -x "$D/bin/cuda_memtest" ] || [ "$(cat "$D/bin/cuda_memtest.archs" 2>/dev/null)" != "$want" ]; then
  pinned "$D/third_party/cuda_memtest" "$MEMTEST_REPO" "$MEMTEST_REF"
  echo "building cuda_memtest for $want"
  rm -rf "$D/build/cuda_memtest"
  cmake -S "$D/third_party/cuda_memtest" -B "$D/build/cuda_memtest" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_COMPILER="$NVCC" -DCMAKE_CUDA_ARCHITECTURES="$want" >/dev/null
  make -s -C "$D/build/cuda_memtest" -j"$(nproc)" >/dev/null
  cp "$D/build/cuda_memtest/cuda_memtest" "$D/bin/"; echo "$want" > "$D/bin/cuda_memtest.archs"
fi
{ echo "built $(date '+%F %T') on $(hostname) with $NVCC"; echo "archs: $ARCHS"
  echo "gpu-burn $GPUBURN_REF  cuda_memtest $MEMTEST_REF"; } > "$D/bin/BUILD_INFO"
echo "done:"; ls "$D/bin"
[ -x /usr/local/libexec/ocsweep/vramtemp ] && ! cmp -s "$D/bin/vramtemp" /usr/local/libexec/ocsweep/vramtemp && \
  echo "note: bin/vramtemp changed — run ./install-service.sh to update the root-owned copy"
