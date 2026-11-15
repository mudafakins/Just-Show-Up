# Builds the Windows installer on this PC.
# Run from this folder in PowerShell:   powershell -ExecutionPolicy Bypass -File .\build-windows.ps1
# Needs: Node.js LTS, Rust (rustup), and the Visual Studio C++ Build Tools.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

foreach ($tool in "node", "npm", "cargo") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool was not found. Install the prerequisites first, then open a NEW PowerShell window."
    }
}
if (-not (Test-Path ".env.local")) {
    throw ".env.local is missing. It holds the Supabase settings and should have come with this folder."
}

Write-Host "Installing packages..." -ForegroundColor Cyan
npm ci
if ($LASTEXITCODE) { throw "npm ci failed" }

Write-Host "Building (the first build takes 5-10 minutes)..." -ForegroundColor Cyan
npx tauri build
if ($LASTEXITCODE) { throw "The build failed; see the messages above." }

$out = Join-Path $PSScriptRoot "src-tauri\target\release\bundle\nsis"
Write-Host "Done. The installer is in: $out" -ForegroundColor Green
Start-Process explorer.exe $out
