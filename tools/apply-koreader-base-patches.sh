#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly BASE_DIR="${ROOT_DIR}/base"
readonly PATCH_DIR="${ROOT_DIR}/patches/koreader-base"
readonly EXPECTED_BASE_COMMIT="0309968402ce4f695e12e0a200506037e75225a3"

if ! git -C "${BASE_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Initializing the public koreader-base submodule..."
    git -C "${ROOT_DIR}" submodule update --init base
fi

actual_base_commit="$(git -C "${BASE_DIR}" rev-parse HEAD)"
if [[ "${actual_base_commit}" != "${EXPECTED_BASE_COMMIT}" ]]; then
    printf 'ERROR: koreader-base is at %s; patches expect %s.\n' \
        "${actual_base_commit}" "${EXPECTED_BASE_COMMIT}" >&2
    echo "Update or rebase patches/koreader-base before changing the base gitlink." >&2
    exit 1
fi

shopt -s nullglob
patches=("${PATCH_DIR}"/*.patch)
if [[ "${#patches[@]}" -eq 0 ]]; then
    echo "ERROR: no koreader-base patches found in ${PATCH_DIR}." >&2
    exit 1
fi

for patch in "${patches[@]}"; do
    if git -C "${BASE_DIR}" apply --check "${patch}" 2>/dev/null; then
        echo "Applying koreader-base patch: $(basename "${patch}")"
        git -C "${BASE_DIR}" apply --whitespace=nowarn "${patch}"
    elif git -C "${BASE_DIR}" apply --reverse --check "${patch}" 2>/dev/null; then
        echo "Already applied: $(basename "${patch}")"
    else
        echo "ERROR: cannot cleanly apply $(basename "${patch}")." >&2
        echo "Inspect local base changes or rebase the patch queue." >&2
        exit 1
    fi
done

git -C "${BASE_DIR}" diff --check
