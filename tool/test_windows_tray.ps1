param(
    [ValidateSet('All', 'Shim', 'Real')]
    [string]$Mode = 'All'
)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runnerDirectory = Join-Path $workspace 'windows/runner'
$testSource = Join-Path $workspace 'tool/tests/windows_tray_smoke.cpp'
$artifactDirectory = Join-Path $workspace 'build/windows-tray-smoke'
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio Installer vswhere.exe was not found.'
}
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) {
    throw 'Visual Studio C++ build tools were not found.'
}
$developerCommand = Join-Path $visualStudio 'Common7/Tools/VsDevCmd.bat'
$resourceObject = Join-Path $artifactDirectory 'windows_tray_smoke.res'
$testObject = Join-Path $artifactDirectory 'windows_tray_smoke.obj'
$testExecutable = Join-Path $artifactDirectory 'windows_tray_smoke.exe'

# Build only: cmd is used for the Visual Studio batch environment, never for
# deletion or user-data operations. Compile the existing app icon resource.
$compile = 'call "{0}" -no_logo -arch=x64 -host_arch=x64 && rc.exe /nologo /fo "{1}" Runner.rc && cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DNOMINMAX /DUNICODE /D_UNICODE /Fo"{2}" /Fe"{3}" "{4}" "{1}" /link user32.lib shell32.lib gdi32.lib' -f $developerCommand, $resourceObject, $testObject, $testExecutable, $testSource
Push-Location $runnerDirectory
try {
    & $env:ComSpec /d /s /c $compile
    if ($LASTEXITCODE -ne 0) { throw "Native tray smoke compilation failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

$testModes = switch ($Mode) {
    'Shim' { @('shim') }
    'Real' { @('real') }
    default { @('shim', 'real') }
}
foreach ($testMode in $testModes) {
    $stdout = Join-Path $artifactDirectory "$testMode.stdout.log"
    $stderr = Join-Path $artifactDirectory "$testMode.stderr.log"
    $process = Start-Process -FilePath $testExecutable -ArgumentList "--$testMode" -WorkingDirectory $artifactDirectory -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    if (-not $process.WaitForExit(15000)) {
        # Only this newly launched, PID-owned smoke helper may be terminated.
        $process.Kill()
        throw "Tray smoke timed out in $testMode mode."
    }
    $process.Refresh()
    Get-Content -LiteralPath $stdout
    if ((Get-Item -LiteralPath $stderr).Length -gt 0) {
        Get-Content -LiteralPath $stderr
    }
    if ($process.ExitCode -ne 0) {
        throw "Tray smoke failed in $testMode mode: $($process.ExitCode)"
    }
}
