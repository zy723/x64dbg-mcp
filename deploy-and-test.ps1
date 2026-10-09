# Deploy freshly-built .dp64 to x64dbg, restart x64dbg, run smoke tests
# Usage: powershell -ExecutionPolicy Bypass -File deploy-and-test.ps1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$x64dbgDir = 'D:\Program Files\IDA\x64dbg\release\x64'
$x64dbgExe = Join-Path $x64dbgDir 'x64dbg.exe'
$pluginDir = Join-Path $x64dbgDir 'plugins'
$pluginDst = Join-Path $pluginDir 'x64dbg_mcp.dp64'
$dist = Join-Path $root 'dist'
$pluginSrc = Join-Path $dist 'x64dbg_mcp.dp64'

if (-not (Test-Path $pluginSrc)) { throw "Build artifact missing: $pluginSrc" }
if (-not (Test-Path $x64dbgExe))  { throw "x64dbg not found at: $x64dbgExe" }
if (-not (Test-Path $pluginDir))  { New-Item -ItemType Directory $pluginDir | Out-Null }

Write-Host "==> Step 1: Stop running x64dbg (if any)"
Get-Process x64dbg -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("    killing x64dbg pid=" + $_.Id)
    Stop-Process -Id $_.Id -Force
}
Start-Sleep -Milliseconds 800

Write-Host ("==> Step 2: Install " + $pluginSrc + " -> " + $pluginDst)
# Backup existing plugin once
if (Test-Path $pluginDst) {
    $backup = $pluginDst + ".bak.prev"
    Copy-Item $pluginDst $backup -Force
    Write-Host ("    backup: " + $backup)
}
Copy-Item $pluginSrc $pluginDst -Force
$size = (Get-Item $pluginDst).Length
Write-Host ("    installed " + $size + " bytes")

Write-Host ("==> Step 3: Launch x64dbg (no target; will init from MCP)")
$proc = Start-Process -FilePath $x64dbgExe -PassThru -WorkingDirectory $x64dbgDir
Write-Host ("    x64dbg pid=" + $proc.Id)

Write-Host "==> Step 4: Wait for plugin HTTP/MCP to come up (max 15s)"
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $r = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/rpc' -Method Post `
             -ContentType 'application/json' `
             -Body '{"jsonrpc":"2.0","id":1,"method":"debug.get_state"}' `
             -TimeoutSec 2 -ErrorAction Stop
        if ($r.result) {
            $ready = $true
            Write-Host ("    ready (state=" + $r.result.state + ")")
            break
        }
    } catch { }
}
if (-not $ready) { Write-Host "    HTTP /rpc not reachable — MCP via stdio may still work; continue" }

Write-Host "==> Step 5: Smoke tests (debug.get_state + tools/list presence)"
try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/rpc' -Method Post `
         -ContentType 'application/json' `
         -Body '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' `
         -TimeoutSec 5 -ErrorAction Stop
    $toolNames = $r.result.tools | ForEach-Object { $_.name }
    $expected = @('debug_detach','debug_get_pid','debug_get_exit_code','debug_run_until_break','register_get_all')
    $missing = $expected | Where-Object { $toolNames -notcontains $_ }
    if ($missing) {
        Write-Host ("    MISS tools: " + ($missing -join ','))
        exit 2
    } else {
        Write-Host ("    all " + $expected.Count + " new tools registered")
    }
    Write-Host ("    total tools: " + $toolNames.Count)
} catch {
    Write-Host ("    tools/list failed: " + $_.Exception.Message)
    exit 3
}

Write-Host "==> DONE — x64dbg is running with new plugin"
Write-Host ("    pid: " + $proc.Id)
