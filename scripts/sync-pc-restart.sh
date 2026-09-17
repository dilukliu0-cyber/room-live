#!/usr/bin/env bash
# Run ON the PC (C:\Users\diluk\room-live) after CopyFromBox or git pull.
set -euo pipefail
ROOT="${1:-C:/Users/diluk/room-live}"
cd "$ROOT" || cd /c/Users/diluk/room-live
git pull --ff-only origin main || true
if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command "Get-NetTCPConnection -LocalPort 8787 -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }"
fi
cd server
node index.js
