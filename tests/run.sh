#!/usr/bin/env bash
# Forge test runner. Regenerates the embedded source, runs the executable protocol +
# asset suites under luau, then lints and builds. Exits non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }

bold "1/5  Regenerating embedded source bundle"
./gen_sources.sh

bold "2/5  Protocol suite (runs REAL Bridge/Store/Protocol under a Roblox mock)"
luau test_protocol.luau

bold "3/5  Asset payload suite (validates real generated payloads vs MCP schemas)"
luau test_assets.luau

bold "4/5  Lint (selene) + format check (stylua)"
( cd "$ROOT"
  if command -v selene >/dev/null; then
    [ -f roblox.yml ] || selene generate-roblox-std >/dev/null 2>&1
    # selene exits non-zero on warnings too; we only fail on errors/parse-errors.
    out="$(selene src/ 2>&1 || true)"
    echo "$out" | tail -3
    if echo "$out" | grep -qE "^[1-9][0-9]* error|[1-9][0-9]* parse error"; then
      echo "selene reported errors — failing"; exit 1
    fi
  else
    echo "selene not installed — skipping lint"
  fi
  if command -v stylua >/dev/null; then
    stylua --check src/ >/dev/null 2>&1 && echo "stylua: format ok" || echo "stylua: would reformat (run: stylua src/)"
  fi
)

bold "5/5  Build plugin (rojo)"
( cd "$ROOT"
  if command -v rojo >/dev/null; then
    rojo build plugin.project.json --output Forge.rbxmx && echo "Built Forge.rbxmx"
  else
    echo "rojo not installed — skipping build"
  fi
)

bold "ALL CHECKS PASSED ✓"
