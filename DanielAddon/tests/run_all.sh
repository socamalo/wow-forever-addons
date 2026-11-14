#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== Lua unit tests =="
uv run --with lupa python -I tests/run_tests.py
echo "== MCP tests =="
uv run --with mcp python -I tests/test_mcp.py
