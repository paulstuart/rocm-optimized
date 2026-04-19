#!/usr/bin/env bash
# Build an optimized ROCm stack from upstream TheRock source.
#
# Runs entirely inside the TheRock manylinux container (GCC 13, AlmaLinux 8).
# No host compiler or system packages required beyond Docker or Podman.
#
# Usage:
#   ./build.sh [OPTIONS]
#
# Options:
#   --gpu-family FAMILY   AMDGPU family to build for (default: gfx1151)
#                         Examples: gfx1151 (Strix Halo), gfx1100 (Navi31),
#                                   gfx942 (MI300X), gfx1100-all
#   --march ARCH          Host CPU -march value (default: native)
#                         "native"  - auto-detect build host CPU
#                         "znver5"  - explicit Zen 5, e.g. for cross-builds
#                         "none"    - disable CPU tuning (stock upstream)
#   --therock-dir DIR     Path to TheRock source tree
#                         (default: ../TheRock, or $THEROCK_DIR env var)
#   --output-dir DIR      Build tree and ccache location
#                         (default: ./output)
#   --docker CMD          Docker or Podman binary (default: docker)
#   --no-pull             Skip pulling the latest container image
#   --interactive         Drop into a shell inside the container
#   --fetch               Fetch/update TheRock submodules before building
#   -h, --help            Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
GPU_FAMILY="gfx1151"
HOST_MARCH="native"
THEROCK_DIR="${THEROCK_DIR:-$(cd "${SCRIPT_DIR}/../TheRock" 2>/dev/null && pwd || echo "")}"
OUTPUT_DIR="${SCRIPT_DIR}/output"
DOCKER="docker"
PULL="--pull"
INTERACTIVE=""
FETCH=0

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --gpu-family)   GPU_FAMILY="$2";  shift ;;
    --march)        HOST_MARCH="$2";  shift ;;
    --therock-dir)  THEROCK_DIR="$2"; shift ;;
    --output-dir)   OUTPUT_DIR="$2";  shift ;;
    --docker)       DOCKER="$2";      shift ;;
    --no-pull)      PULL="--no-pull" ;;
    --interactive)  INTERACTIVE="--interactive" ;;
    --fetch)        FETCH=1 ;;
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown option: $1 (use --help)" >&2; exit 1 ;;
  esac
  shift
done

# ── Locate TheRock ─────────────────────────────────────────────────────────────
if [[ -z "${THEROCK_DIR}" || ! -d "${THEROCK_DIR}" ]]; then
  echo "TheRock source tree not found."
  echo "Clone it with:"
  echo "  git clone https://github.com/ROCm/TheRock.git '${SCRIPT_DIR}/../TheRock'"
  echo "Or specify its location with --therock-dir <path> or THEROCK_DIR=<path>."
  exit 1
fi
THEROCK_DIR="$(cd "${THEROCK_DIR}" && pwd)"
echo "Using TheRock at: ${THEROCK_DIR}"

# ── Validate TheRock ──────────────────────────────────────────────────────────
if [[ ! -f "${THEROCK_DIR}/build_tools/linux_portable_build.py" ]]; then
  echo "ERROR: '${THEROCK_DIR}' does not look like a TheRock checkout." >&2
  echo "Expected: ${THEROCK_DIR}/build_tools/linux_portable_build.py" >&2
  exit 1
fi

# ── Optionally fetch submodules ───────────────────────────────────────────────
if [[ ${FETCH} -eq 1 ]]; then
  echo "Fetching TheRock submodules..."
  (
    cd "${THEROCK_DIR}"
    python3 -m venv .venv 2>/dev/null || true
    source .venv/bin/activate
    pip install --quiet -r requirements.txt
    python3 build_tools/fetch_sources.py --jobs 16
  )
fi

# ── Apply patch ────────────────────────────────────────────────────────────────
# Apply the THEROCK_HOST_MARCH patch if not already present. This is the only
# modification made to the upstream TheRock source tree.
PATCH="${SCRIPT_DIR}/native_march.patch"
MARKER="THEROCK_HOST_MARCH"

if ! grep -q "${MARKER}" "${THEROCK_DIR}/cmake/therock_compiler_config.cmake" 2>/dev/null; then
  echo "Applying native_march.patch..."
  git -C "${THEROCK_DIR}" apply "${PATCH}"
  echo "Patch applied."
else
  echo "native_march.patch already applied."
fi

# ── Compose cmake args ─────────────────────────────────────────────────────────
CMAKE_ARGS=(
  "--preset" "linux-release-package"
  "-DTHEROCK_AMDGPU_FAMILIES=${GPU_FAMILY}"
)

if [[ "${HOST_MARCH}" != "none" ]]; then
  CMAKE_ARGS+=("-DTHEROCK_HOST_MARCH=${HOST_MARCH}")
fi

# ── Build ──────────────────────────────────────────────────────────────────────
echo ""
echo "  GPU family : ${GPU_FAMILY}"
echo "  Host march : ${HOST_MARCH}"
echo "  TheRock    : ${THEROCK_DIR}"
echo "  Output     : ${OUTPUT_DIR}"
echo ""

PORTABLE_BUILD_ARGS=(
  "--docker=${DOCKER}"
  "${PULL}"
  "--output-dir=${OUTPUT_DIR}"
  "--repo-dir=${THEROCK_DIR}"
)
[[ -n "${INTERACTIVE}" ]] && PORTABLE_BUILD_ARGS+=("${INTERACTIVE}")

exec python3 "${THEROCK_DIR}/build_tools/linux_portable_build.py" \
  "${PORTABLE_BUILD_ARGS[@]}" \
  -- \
  "${CMAKE_ARGS[@]}"
