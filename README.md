# rocm-optimized

Build ROCm from source, optimized for your specific CPU — targeting any AMD GPU family.

Stock ROCm packages are compiled for generic x86-64. This leaves Zen 5
microarchitecture features (AVX-512, improved branch prediction, etc.) unused
on systems like the Ryzen AI MAX / Strix Halo. Building from source with
`-march=native` or `-march=znver5` lets the compiler exploit these.

## How it works

Everything runs inside the [TheRock](https://github.com/ROCm/TheRock) manylinux
build container (GCC 13, AlmaLinux 8, glibc 2.28). Your local TheRock checkout
is bind-mounted in; the container handles all compiler and OS dependencies.

A single small patch (`native_march.patch`) is applied to the TheRock source
before the build. It adds a `THEROCK_HOST_MARCH` CMake string option that
propagates `-march=<value>` to all ROCm library subprojects, while explicitly
exempting the LLVM/Clang bootstrap compiler (which OOMs when compiling MLIR
dialect files at `-O3 -march=<anything>`).

The patch is idempotent — re-running `build.sh` skips it if already applied.

## Prerequisites

- **Docker** or **Podman** — the manylinux image is pulled automatically on first run
- **Git** — for cloning TheRock and applying the patch
- **Python 3** — to invoke TheRock's `linux_portable_build.py`

No specific Linux distribution, GCC version, or system packages required on
the host.

## Quick start

### 1. Clone TheRock alongside this repo

```bash
# Both repos should sit in the same parent directory:
# ~/code/
# ├── TheRock/          ← upstream, unmodified
# └── rocm-optimized/   ← this repo

git clone https://github.com/ROCm/TheRock.git
```

### 2. Fetch TheRock submodules

The submodules are large (~30–60 min depending on bandwidth):

```bash
cd TheRock
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python3 build_tools/fetch_sources.py --jobs 16
```

For a faster start, fetch only what you need:

```bash
# Core + compiler + math libraries (covers most ML/compute use cases):
python3 build_tools/fetch_sources.py --stage foundation --jobs 16
python3 build_tools/fetch_sources.py --stage compiler-runtime --jobs 16
python3 build_tools/fetch_sources.py --stage math-libs --jobs 16
```

Available stages: `foundation`, `compiler-runtime`, `math-libs`, `comm-libs`,
`debug-tools`, `profiler-apps`, `media-libs`.

### 3. Build

```bash
cd rocm-optimized

# Strix Halo (gfx1151), optimized for the current build machine:
./build.sh

# Strix Halo, explicit Zen 5 (useful when building on a different machine):
./build.sh --march znver5

# Different GPU family:
./build.sh --gpu-family gfx1100

# No CPU tuning (reproduces upstream behavior):
./build.sh --march none

# Use Podman instead of Docker:
./build.sh --docker podman
```

Build output lands in `output/build/`. The finished ROCm install tree is at:

```
output/build/dist/rocm/
```

ccache is persisted in `output/caches/` between runs. A cold LLVM build takes
1–2 hours on a 16-core machine; subsequent builds are much faster.

## Options

| Option | Default | Description |
|---|---|---|
| `--gpu-family FAMILY` | `gfx1151` | AMDGPU target. Examples: `gfx1151`, `gfx1100`, `gfx942`, `gfx1100-all` |
| `--march ARCH` | `native` | Host CPU `-march` value. `native` = auto-detect, `znver5` = Zen 5, `none` = disable |
| `--therock-dir DIR` | `../TheRock` | Path to TheRock checkout (or set `THEROCK_DIR` env var) |
| `--output-dir DIR` | `./output` | Build tree and ccache location |
| `--docker CMD` | `docker` | Docker or Podman binary |
| `--no-pull` | — | Skip pulling the latest container image |
| `--interactive` | — | Drop into a shell inside the container |
| `--fetch` | — | Fetch/update TheRock submodules before building |

## Keeping up with upstream TheRock

```bash
# In the TheRock directory:
git apply --reverse ../rocm-optimized/native_march.patch  # un-apply patch first
git pull                                                   # update to latest main
python3 build_tools/fetch_sources.py --jobs 16            # update submodules

# Back in rocm-optimized:
./build.sh                                                 # re-apply patch + rebuild
```

If TheRock changes the two patched files and the patch no longer applies
cleanly, see [Maintaining the patch](#maintaining-the-patch) below.

## What `--march` does

`-march=<arch>` compiles host-side ROCm code (library dispatch, initialization,
and any CPU-side computation in math libs) using instructions specific to the
target microarchitecture. On Zen 5 this means AVX-512, VNNI, improved branch
predictors, and other features absent from the generic x86-64 build.

GPU compute kernels are compiled for the GPU ISA regardless of this flag — the
gains appear in host-side dispatch latency, library initialization, and CPU
computation in rocBLAS, rocFFT, rocRAND, etc.

**`native`** — right choice when the build machine is also the runtime machine.  
**`znver5`** — use this when building on a generic x86-64 server for deployment
on a Strix Halo or Ryzen 9000 system.

## GPU family reference

| `--gpu-family` | GPU | Example hardware |
|---|---|---|
| `gfx1151` | Radeon 8060S | Ryzen AI MAX (Strix Halo iGPU) |
| `gfx1150` | Radeon 890M | Ryzen AI 300 (Strix Point iGPU) |
| `gfx1100` | RX 7900 XTX | Navi 31 (RDNA3 flagship) |
| `gfx1101` | RX 7800 XT | Navi 32 |
| `gfx942`  | Instinct MI300X | Data center GPU |
| `gfx1100-all` | all RDNA3 | Multi-target build |

## Benchmarking

Compare the optimized build against stock ROCm:

```bash
ROCM=./output/build/dist/rocm

# Optimized build
LD_LIBRARY_PATH=${ROCM}/lib ${ROCM}/bin/rocblas-bench \
  -f gemm -r f32_r --transpA N --transpB N \
  -m 4096 -n 4096 -k 4096 --alpha 1 --beta 0 -i 20

# Stock ROCm (if installed at /opt/rocm)
LD_LIBRARY_PATH=/opt/rocm/lib /opt/rocm/bin/rocblas-bench \
  -f gemm -r f32_r --transpA N --transpB N \
  -m 4096 -n 4096 -k 4096 --alpha 1 --beta 0 -i 20
```

## Maintaining the patch

`native_march.patch` modifies two files in TheRock:

**`cmake/therock_compiler_config.cmake`** — appended at the end:
```cmake
set(THEROCK_HOST_MARCH "" CACHE STRING
  "Host CPU -march value for non-portable local builds (e.g. 'native', 'znver5'). Empty = no flag.")

if(THEROCK_HOST_MARCH)
  if(NOT MSVC)
    string(APPEND CMAKE_C_FLAGS " -march=${THEROCK_HOST_MARCH}")
    string(APPEND CMAKE_CXX_FLAGS " -march=${THEROCK_HOST_MARCH}")
    message(STATUS "THEROCK_HOST_MARCH: enabled (-march=${THEROCK_HOST_MARCH})")
  endif()
endif()
```

**`compiler/CMakeLists.txt`** — inside the `amd-llvm` `CMAKE_ARGS` block:
```cmake
      "-DCMAKE_C_FLAGS="
      "-DCMAKE_CXX_FLAGS="
```

If the patch stops applying after a TheRock update, apply the changes manually,
then regenerate:

```bash
cd TheRock
git diff -- cmake/therock_compiler_config.cmake compiler/CMakeLists.txt \
  > ../rocm-optimized/native_march.patch
```

## Background

TheRock's CI uses a manylinux container with GCC 13 to produce binaries
portable across all Linux distributions with glibc ≥ 2.28. The constraint
preventing `-march` flags in official packages is that all host-side binaries
must be bit-identical regardless of GPU target.

This project sidesteps that constraint by using the same manylinux container
for isolation and reproducibility, while adding a single opt-in flag that CI
never sets. A PR ([ROCm/TheRock#4580](https://github.com/ROCm/TheRock/pull/4580))
proposes merging `THEROCK_HOST_MARCH` upstream; if it lands, this patch file
becomes unnecessary.
