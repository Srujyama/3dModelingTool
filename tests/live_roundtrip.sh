#!/usr/bin/env bash
# live_roundtrip.sh — drives a REAL Studio session through the robloxstudio MCP server
# over HTTP and runs the full Forge round-trip: build a 3D model + a native GUI tree,
# verify they landed with correct properties, then delete them (leaving the place clean).
#
# Prereq: Studio open with the MCP Server panel CONNECTED (pluginConnected:true).
# Usage:  MCP_URL=http://localhost:PORT/mcp ./live_roundtrip.sh
#         (PORT defaults to 58741; check the MCP Server panel for the actual port.)
set -uo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-58741}"
BASE="http://localhost:${PORT}"
export MCP_URL="${MCP_URL:-${BASE}/mcp}"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$1"; exit 1; }
okmsg() { printf "\033[32m✓ %s\033[0m\n" "$1"; }

# --- preflight: is the plugin connected? ---
bold "Preflight: checking MCP server + plugin connection"
HEALTH="$(curl -s -m 5 "${BASE}/health" || true)"
if [ -z "$HEALTH" ]; then
  fail "MCP server not reachable at ${BASE}. Is Studio open with the MCP Server running?"
fi
CONNECTED="$(printf '%s' "$HEALTH" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pluginConnected"))' 2>/dev/null || echo "?")"
if [ "$CONNECTED" != "True" ]; then
  fail "Studio plugin is NOT connected (pluginConnected=$CONNECTED). Open the MCP Server panel in Studio and click Connect, then re-run."
fi
okmsg "Plugin connected."

call() { # call <tool>  (args on stdin)
  ./mcp.sh "$1"
}

# --- 1. 3D model: wooden crate via create_build + import_build ---
bold "1/4  Building a 3D model (wooden crate)"
call create_build <<'EOF' | grep -q '"success": true' && okmsg "create_build ok" || fail "create_build failed"
{"id":"misc/forge_live_crate","style":"misc",
 "palette":{"wood":["Brown","WoodPlanks"],"frame":["Dark orange","Wood"]},
 "parts":[[0,0,0,4,0.3,4,0,0,0,"wood"],[0,4,0,4,0.3,4,0,0,0,"wood"],
   [0,2,-2,4,4,0.3,0,0,0,"wood"],[0,2,2,4,4,0.3,0,0,0,"wood"],
   [-2,2,0,0.3,4,4,0,0,0,"wood"],[2,2,0,0.3,4,4,0,0,0,"wood"],
   [-2,2,-2,0.45,4,0.45,0,0,0,"frame"],[2,2,-2,0.45,4,0.45,0,0,0,"frame"],
   [-2,2,2,0.45,4,0.45,0,0,0,"frame"],[2,2,2,0.45,4,0.45,0,0,0,"frame"]]}
EOF
echo '{"buildData":"misc/forge_live_crate","targetPath":"game.Workspace","position":[0,5,0]}' \
  | call import_build | grep -q '"success": true' && okmsg "import_build ok" || fail "import_build failed"

# --- 2. verify the model ---
bold "2/4  Verifying the model landed with correct properties"
echo '{"instancePath":"game.Workspace.forge_live_crate","classFilter":"BasePart"}' \
  | call get_descendants | grep -q '"count": 10' && okmsg "model has 10 parts" || fail "wrong part count"
echo '{"instancePath":"game.Workspace.forge_live_crate.Part"}' | call get_instance_properties \
  | grep -q 'WoodPlanks' && okmsg "material applied (WoodPlanks)" || fail "material not applied"

# --- 3. GUI: native instance tree via create_object (verified-working path) ---
bold "3/4  Building a native GUI tree (shop panel)"
echo '{"className":"ScreenGui","parent":"game.StarterGui","name":"ForgeLiveUI","properties":{"ResetOnSpawn":false}}' | call create_object >/dev/null
echo '{"className":"Frame","parent":"game.StarterGui.ForgeLiveUI","name":"Panel","properties":{"Size":{"UDim2":[0,420,0,320]},"Position":{"UDim2":[0.5,-210,0.5,-160]},"BackgroundColor3":{"Color3":[0.08,0.07,0.10]},"BorderSizePixel":0}}' | call create_object >/dev/null
echo '{"className":"UICorner","parent":"game.StarterGui.ForgeLiveUI.Panel","properties":{"CornerRadius":{"UDim":[0,10]}}}' | call create_object >/dev/null
echo '{"className":"TextLabel","parent":"game.StarterGui.ForgeLiveUI.Panel","name":"Title","properties":{"Size":{"UDim2":[1,0,0,44]},"BackgroundTransparency":1,"Text":"Fantasy Shop","TextColor3":{"Color3":[0.93,0.91,0.84]},"Font":"GothamBold","TextSize":24}}' | call create_object >/dev/null
echo '{"className":"TextButton","parent":"game.StarterGui.ForgeLiveUI.Panel","name":"ClaimButton","properties":{"Size":{"UDim2":[0,160,0,40]},"Position":{"UDim2":[0.5,-80,1,-52]},"BackgroundColor3":{"Color3":[0.78,0.64,0.29]},"Text":"Claim","TextColor3":{"Color3":[0.1,0.08,0.06]},"Font":"GothamBold","TextSize":18,"BorderSizePixel":0}}' | call create_object >/dev/null
echo '{"instancePath":"game.StarterGui.ForgeLiveUI"}' | call get_descendants \
  | grep -q '"count": 5' && okmsg "UI tree has 5 descendants (Frame, UICorner, Title, Button)" || fail "UI tree incomplete"

# --- 4. cleanup ---
bold "4/4  Cleaning up test artifacts"
echo '{"instancePath":"game.Workspace.forge_live_crate"}' | call delete_object >/dev/null 2>&1 && okmsg "deleted crate" || echo "  (crate delete failed — remove manually)"
echo '{"instancePath":"game.StarterGui.ForgeLiveUI"}' | call delete_object >/dev/null 2>&1 && okmsg "deleted UI" || echo "  (UI delete failed — remove manually)"

bold "LIVE ROUND-TRIP COMPLETE ✓  (3D model + native GUI built, verified, cleaned up)"
