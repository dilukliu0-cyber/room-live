# Run on PC (machineId 764b9165-ec3a-4a70-8abe-0de6df58c4f9)
Set-Location C:\Users\diluk\room-live
git pull --ff-only origin main
Get-NetTCPConnection -LocalPort 8787 -ErrorAction SilentlyContinue | ForEach-Object {
  Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
}
Set-Location .\server
if (-not (Test-Path .\node_modules)) { npm ci }
node index.js
