# Deploy freshly-built .dp64 to x64dbg, restart, smoke test, full regression.
# Usage: powershell -ExecutionPolicy Bypass -File deploy-and-test.ps1 [-SkipBuild]
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$x64dbgDir = 'D:\Program Files\IDA\x64dbg\release\x64'
$x64dbgExe = Join-Path $x64dbgDir 'x64dbg.exe'
$pluginDir = Join-Path $x64dbgDir 'plugins'
$pluginDst = Join-Path $pluginDir 'x64dbg_mcp.dp64'
$dist = Join-Path $root 'dist'
$pluginSrc = Join-Path $dist 'x64dbg_mcp.dp64'

# ---- helpers -------------------------------------------------------------
function Read-PluginPort {
    # The plugin config ships server.port (default 3000). Read the deployed
    # config; fall back to scanning the PCB/plugin dir next to the plugin.
    $candidates = @(
        (Join-Path $pluginDir 'x64dbg-mcp\config.json'),
        (Join-Path $pluginDir 'config.json')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            try {
                $j = Get-Content $c -Raw | ConvertFrom-Json
                if ($j.server -and $j.server.port) {
                    return [int]$j.server.port
                }
            } catch { }
        }
    }
    return 3000
}

function Rpc([string]$tool, $arguments) {
    if ($null -eq $arguments) { $arguments = @{} }
    # Invoke-RestMethod drops empty hashtables; use raw JSON text instead.
    $argJson = '{}'
    if ($arguments.Count -gt 0) {
        $argJson = $arguments | ConvertTo-Json -Depth 10 -Compress
    }
    $body = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"' + $tool +
            '","arguments":' + $argJson + '}}'
    $raw = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $script:RpcPort + "/rpc") `
        -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60
    if ($raw.result -and $raw.result.content) {
        try { return ($raw.result.content[0].text | ConvertFrom-Json) }
        catch { return $raw.result.content[0].text }
    }
    return $raw
}

# ---- build ---------------------------------------------------------------
if ($args -notcontains '-SkipBuild') {
    Write-Host '==> Step 0: Build x64'
    & (Join-Path $root 'build-local.ps1') --x64-only
    if ($LASTEXITCODE -ne 0) { throw 'build failed' }
}

if (-not (Test-Path $pluginSrc)) { throw "Build artifact missing: $pluginSrc" }
if (-not (Test-Path $x64dbgExe))  { throw "x64dbg not found at: $x64dbgExe" }
if (-not (Test-Path $pluginDir))  { New-Item -ItemType Directory $pluginDir | Out-Null }

# ---- deploy --------------------------------------------------------------
Write-Host '==> Step 1: Stop running x64dbg (if any)'
Get-Process x64dbg -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("    killing x64dbg pid=" + $_.Id)
    Stop-Process -Id $_.Id -Force
}
Start-Sleep -Milliseconds 800

Write-Host ("==> Step 2: Install " + $pluginSrc + " -> " + $pluginDst)
if (Test-Path $pluginDst) {
    Copy-Item $pluginDst ($pluginDst + '.bak.prev') -Force
    Write-Host '    backup: x64dbg_mcp.dp64.bak.prev'
}
Copy-Item $pluginSrc $pluginDst -Force
Write-Host ("    installed " + (Get-Item $pluginDst).Length + " bytes")

$script:RpcPort = Read-PluginPort
Write-Host ("    RPC port from deployed config: " + $script:RpcPort)

# ---- restart -------------------------------------------------------------
Write-Host '==> Step 3: Launch x64dbg'
$proc = Start-Process -FilePath $x64dbgExe -PassThru -WorkingDirectory $x64dbgDir
Write-Host ("    x64dbg pid=" + $proc.Id)

Write-Host '==> Step 4: Wait for plugin HTTP RPC (max 20s)'
$ready = $false
$probeBody = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $r = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $script:RpcPort + '/rpc') `
             -Method Post -ContentType 'application/json' -Body $probeBody -TimeoutSec 2 -ErrorAction Stop
        if ($r.result -and $r.result.tools) {
            $ready = $true
            Write-Host ("    ready (" + $r.result.tools.Count + " tools)")
            break
        }
    } catch { }
}
if (-not $ready) { throw 'plugin HTTP RPC did not come up within 20s (check x64dbg log)' }

# ---- smoke: new tools registered ------------------------------------------
Write-Host '==> Step 5: Verify v1.1.0 tool registry'
$toolNames = @((Rpc 'debug_get_state' @{ }).PSObject)  # dummy warmup call never used
$r = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $script:RpcPort + '/rpc') `
     -Method Post -ContentType 'application/json' -Body $probeBody -TimeoutSec 10
$toolNames = $r.result.tools | ForEach-Object { $_.name }
$expected = @('debug_detach','debug_get_pid','debug_get_exit_code','debug_run_until_break','register_get_all')
$missing = $expected | Where-Object { $toolNames -notcontains $_ }
if ($missing) { throw ('MISSING tools: ' + ($missing -join ',')) }
Write-Host ('    all ' + $expected.Count + ' new tools present')

# ---- full regression (the rc2/rs3 10-step chain) --------------------------
Write-Host '==> Step 6: Regression chain — init/erun'
Rpc 'debug_init' @{ path = 'C:/Windows/System32/notepad.exe' } | Out-Null
Rpc 'script_execute' @{ command = 'erun' } | Out-Null
Start-Sleep -Seconds 3

Write-Host '==> Step 7: get_pid'
$pidR = Rpc 'debug_get_pid' @{ }
$targetPid = $pidR.pid
if (-not $targetPid) { throw 'debug_get_pid returned no pid' }
Write-Host ("    debuggee pid=" + $targetPid)

Write-Host '==> Step 8: pause + DETACH (rc2 crash scenario) — x64dbg must survive'
Rpc 'script_execute' @{ command = 'pause' } | Out-Null
Start-Sleep -Milliseconds 800
$detach = Rpc 'debug_detach' @{ timeout_ms = 8000 }
if (-not $detach.success) { throw ('detach failed: ' + ($detach | ConvertTo-Json -Compress)) }
Start-Sleep -Seconds 2
$x = Get-Process x64dbg -ErrorAction SilentlyContinue
if (-not $x) { throw 'x64dbg DIED after detach — crash regression!' }
Write-Host ('    x64dbg ALIVE pid=' + $x.Id)

$dbgAlive = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
Write-Host ("    debuggee survived detach: " + [bool]$dbgAlive)

Write-Host '==> Step 9: re-attach same PID (W7 wedge scenario)'
$attach = Rpc 'debug_attach_pid' @{ pid = $targetPid; timeout_ms = 20000 }
if (-not $attach.success) { throw ('re-attach failed: ' + ($attach | ConvertTo-Json -Compress)) }
Write-Host ('    re-attach OK state=' + $attach.state)

Write-Host '==> Step 10: force-kill debuggee → exit_code capture'
Rpc 'script_execute' @{ command = 'pause' } | Out-Null
Start-Sleep -Milliseconds 800
taskkill /PID $targetPid /F | Out-Null
Start-Sleep -Seconds 2
$exitR = Rpc 'debug_get_exit_code' @{ }
Write-Host ('    exited=' + $exitR.exited + ' code=' + $exitR.exit_code + ' cached=' + [bool]$exitR.cached)

Rpc 'debug_stop' @{ } | Out-Null
Start-Sleep -Seconds 1

Write-Host '==> Step 11: post-stop cached exit code'
$exitR2 = Rpc 'debug_get_exit_code' @{ }
Write-Host ('    exited=' + $exitR2.exited + ' code=' + $exitR2.exit_code + ' cached=' + [bool]$exitR2.cached)
if (-not $exitR2.exited) { Write-Host '    WARN: exit code cache missing after stop' }

Write-Host '==> Step 12: fresh session → register_get_all + stack_get_trace'
Rpc 'debug_init' @{ path = 'C:/Windows/System32/notepad.exe' } | Out-Null
Rpc 'script_execute' @{ command = 'erun' } | Out-Null
Start-Sleep -Seconds 2
Rpc 'script_execute' @{ command = 'pause' } | Out-Null
Start-Sleep -Milliseconds 800
$regs = Rpc 'register_get_all' @{ include_extended = $false }
$hasRip = $regs.registers.PSObject.Properties.Name -contains 'rip'
$hasRflags = $regs.registers.PSObject.Properties.Name -contains 'rflags'
Write-Host ('    register_get_all count=' + $regs.count + ' rip=' + $hasRip + ' rflags=' + $hasRflags)

$trace = Rpc 'stack_get_trace' @{ }
Write-Host ('    stack_get_trace frames=' + $trace.count)
if ($trace.frames.Count -ge 1) {
    $f0 = $trace.frames[0]
    $placeholderFields = @('rsp','rbp','is_user','party') |
        Where-Object { $f0.PSObject.Properties.Name -contains $_ }
    Write-Host ('    frame0 placeholder fields present (should be none): ' + ($placeholderFields -join ','))
}

Rpc 'debug_stop' @{ } | Out-Null

$x = Get-Process x64dbg -ErrorAction SilentlyContinue
if (-not $x) { throw 'x64dbg DIED during regression — new crash introduced!' }
Write-Host ("==> DONE — x64dbg pid=" + $x.Id + " survived the full chain")