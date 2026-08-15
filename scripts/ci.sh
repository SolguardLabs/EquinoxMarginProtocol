#!/usr/bin/env bash
set -euo pipefail

run_npm() {
    if command -v cmd.exe >/dev/null 2>&1 && cmd.exe /C exit >/dev/null 2>&1; then
        cmd.exe /C npm.cmd "$@"
    elif command -v npm >/dev/null 2>&1 && npm --version >/dev/null 2>&1; then
        npm "$@"
    else
        echo "npm is not available in this shell" >&2
        exit 127
    fi
}

run_npm run lint
run_npm run compile
run_npm run typecheck
run_npm test
run_npm run loc
run_npm run size
run_npm audit --omit=dev --audit-level=high
run_npm run verify:release

if [[ "${CI:-}" == "true" ]] && [[ -z "${WSL_DISTRO_NAME:-}" ]] && [[ -n "$(git status --porcelain --untracked-files=no -- . ':(exclude)typechain-types')" ]]; then
    echo "La verificacion ha modificado archivos versionados." >&2
    git status --short
    exit 1
fi
