# End-to-end test of detach crash fix + exit code cache via HTTP /rpc
$ErrorActionPreference = 'Continue'
$url = 'http://127.0.0.1:3030/rpc'

function Call($tool, $args) {
    if ($null -eq $args) { $args = @{} }
    if ($args.Count -eq 0) { $args = @{ _ = $null } }    # empty object workaround
    $body = @{jsonrpc='2.0'; id=1; method='tools/call'; params=@{name=$tool; arguments=$args}} | ConvertTo-Json -Depth 10 -Compress
    # Strip the dummy _=null member for empty calls
    $body = $body -replace '"_":null,?', ''
    $body = $body -replace ',}', '}'
    $r = Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60
    if ($r.result.content) {
        $text = $r.result.content[0].text
        try { return ($text | ConvertFrom-Json) } catch { return $text }
    }
    return $r
}

Write-Host '== 1. debug.get_state'
$state = Call 'debug_get_state' @{}
$state

Write-Host '== 2. init notepad'
$init = Call 'debug_init' @{ path = 'C:\Windows\System32\notepad.exe' }
$init

Write-Host '== 3. erun (skip system bp)'
Call 'script_execute' @{ command='erun' } | Out-Null
Start-Sleep -Seconds 3

Write-Host '== 4. get_pid'
$pid_r = Call 'debug_get_pid' @{}
$pid_r
$targetPid = $pid_r.pid

Write-Host ("== 5. pause and detach, expect NOT to crash x64dbg")
Call 'script_execute' @{ command='pause' } | Out-Null
Start-Sleep -Milliseconds 800
$detach = Call 'debug_detach' @{ timeout_ms = 5000 }
$detach

Write-Host '== 6. confirm x64dbg still alive'
$x = Get-Process x64dbg -ErrorAction SilentlyContinue
if ($x) {
    Write-Host ("    x64dbg pid=" + $x.Id + " ALIVE")
} else {
    Write-Host '    x64dbg DEAD'
    exit 99
}

Write-Host ("== 7. re-attach to pid=" + $targetPid + " (tests stop+retry)")
$attach = Call 'debug_attach_pid' @{ pid=$targetPid; timeout_ms=20000 }
$attach

Write-Host '== 8. x64dbg still alive after attach?'
$x = Get-Process x64dbg -ErrorAction SilentlyContinue
if ($x) { Write-Host ("    ALIVE pid=" + $x.Id) } else { Write-Host '    DEAD'; exit 98 }

Write-Host ("== 9. taskkill the notepad, then get_exit_code should be cached")
taskkill /PID $targetPid /F 2>&1 | Out-Null
Start-Sleep -Seconds 2
$exit_r = Call 'debug_get_exit_code' @{}
$exit_r

Write-Host '== 10. x64dbg still alive at end?'
$x = Get-Process x64dbg -ErrorAction SilentlyContinue
if ($x) { Write-Host ("    ALIVE pid=" + $x.Id); exit 0 } else { Write-Host '    DEAD'; exit 97 }
