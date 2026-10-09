# Local build script — VS2022 Enterprise @ D:, no vcpkg; uses FetchContent
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$cmake = 'D:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'

if (-not (Test-Path $cmake)) { throw "cmake not found: $cmake" }

$arch = if ($args -contains '--x86-only') { 'x86' } elseif ($args -contains '--x64-only') { 'x64' } else { '' }
if ($args -contains '--clean') {
    Remove-Item -Recurse -Force $root\build_x64, $root\build_x86, $root\dist -ErrorAction SilentlyContinue
}

$vcvarsX64 = 'D:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat'
$vcvarsX86 = 'D:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars32.bat'

function Invoke-Build([string]$target, [string]$vcvars, [string]$gen, [string]$out_suffix) {
    Write-Host ("=== Configure {0} ===" -f $target)
    # Bake vcvars into env so cl is found
    $savedEnv = @{}
    foreach ($kv in (cmd /c "`"$vcvars`" >nul 2>&1 && set")) {
        if ($kv -match '^([^=]+)=(.*)$') {
            $savedEnv[$matches[1]] = [System.Environment]::GetEnvironmentVariable($matches[1])
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    try {
        $buildDir = Join-Path $root ("build_" + $target)
        & $cmake -B $buildDir -G 'Visual Studio 17 2022' -A $gen -DCMAKE_BUILD_TYPE=Release -DXDBG_ARCH="$target"
        if ($LASTEXITCODE -ne 0) { throw ("configure failed: " + $target) }

        Write-Host ("=== Build " + $target + " ===")
        & $cmake --build $buildDir --config Release -j
        if ($LASTEXITCODE -ne 0) { throw ("build failed: " + $target) }

        $outDir = Join-Path $root 'dist'
        if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }

        $srcBin = Join-Path $buildDir ("bin\Release\" + $out_suffix)
        if (-not (Test-Path $srcBin)) { throw ("output missing: " + $srcBin) }
        Copy-Item $srcBin $outDir\ -Force
        Write-Host ("[OK] " + $outDir + "\" + $out_suffix)
    } finally {
        foreach ($k in $savedEnv.Keys) {
            [System.Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process')
        }
    }
}

if (-not $arch -or $arch -eq 'x64') {
    Invoke-Build 'x64' $vcvarsX64 'x64' 'x64dbg_mcp.dp64'
}
if (-not $arch -or $arch -eq 'x86') {
    Invoke-Build 'x86' $vcvarsX86 'Win32' 'x32dbg_mcp.dp32'
}
Write-Host '=== Done ==='
