#!/bin/bash
# Run already-built opt-in Swift tests from the project root. Existing shader
# files/links are left untouched. Only a link created by this run is removed.
set -euo pipefail

benchmark_project_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$benchmark_project_root"

benchmark_shader_link="$benchmark_project_root/default.metallib"
benchmark_created_shader_link=0
cleanup_benchmark_shader() {
    if [ "$benchmark_created_shader_link" -eq 1 ] && [ -L "$benchmark_shader_link" ]; then
        if [ "$(readlink "$benchmark_shader_link")" = "BuildSupport/default.metallib" ]; then
            rm -- "$benchmark_shader_link"
        fi
    fi
}
trap cleanup_benchmark_shader EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -e "$benchmark_shader_link" ] && [ ! -L "$benchmark_shader_link" ]; then
    if [ ! -f "$benchmark_project_root/BuildSupport/default.metallib" ]; then
        echo "Missing BuildSupport/default.metallib; build the app shader library first." >&2
        exit 2
    fi
    ln -s "BuildSupport/default.metallib" "$benchmark_shader_link"
    benchmark_created_shader_link=1
fi

# No implicit compile or download. Configure SEKITIRI_PIPELINE_* variables in
# the calling environment and pass --filter for the intended benchmark case.
swift test --skip-build "$@"
