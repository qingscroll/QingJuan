[CmdletBinding()]
param([string]$IsccPath)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($IsccPath)) {
    $IsccPath = & (Join-Path $PSScriptRoot 'get_inno_setup.ps1')
}
$testId = [Guid]::NewGuid().ToString('N')
$testRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot ".dart_tool/installer-test-$testId"))
$workspacePrefix = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\') + '\'
if (-not $testRoot.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installer test directory must be inside the workspace.'
}
$source = Join-Path $testRoot 'source'
$target = Join-Path $testRoot 'installed'
$uninstalled = $false
$installStarted = $false
$ownerProcess = $null
$upgradeProcess = $null
New-Item -ItemType Directory -Force -Path (Join-Path $source 'backend') | Out-Null
Set-Content -LiteralPath (Join-Path $source 'qingjuan.exe') -Value 'client version one'
Set-Content -LiteralPath (Join-Path $source 'backend/qingjuan-desktop.exe') -Value 'backend fixture'

function Invoke-TestSetup {
    param([string]$Executable, [string[]]$ExtraArguments)
    $process = Start-Process -FilePath $Executable -WindowStyle Hidden -Wait -PassThru -ArgumentList (
        @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', '/TASKS=""') + $ExtraArguments
    )
    if ($process.ExitCode -ne 0) { throw "Installer process failed with exit code $($process.ExitCode)." }
}

function Build-TestSetup {
    param([string]$Version)
    # Use a separate registration and mutex; never touch the user's installed app.
    & $IsccPath '/Qp' "/DAppVersion=$Version" '/DBuildNumber=1' `
        "/DAppId=QingJuan.InstallerTest.$testId" "/DAppMutex=QingJuan.InstallerTest.$testId" `
        "/DSourceDir=$source" "/DOutputDir=$testRoot" (Join-Path $projectRoot 'deploy/windows/qingjuan.iss') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup fixture compilation failed: $LASTEXITCODE" }
    return Join-Path $testRoot "QingJuan-v$Version-windows-x64-setup.exe"
}

try {
    $setup = Build-TestSetup '1.0.0'
    $installStarted = $true
    Invoke-TestSetup $setup @("/DIR=`"$target`"", "/LOG=`"$(Join-Path $testRoot 'install.log')`"")
    $data = Join-Path $target 'backend/data'
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    $sentinel = Join-Path $data 'qingjuan.db'
    Set-Content -LiteralPath $sentinel -Value 'user data must survive'
    $hash = (Get-FileHash -LiteralPath $sentinel).Hash

    Set-Content -LiteralPath (Join-Path $source 'qingjuan.exe') -Value 'client version two'
    # Cover migration from the old single-file backend to the directory bundle.
    $runtimeSource = Join-Path $source 'backend/_internal'
    New-Item -ItemType Directory -Force -Path (Join-Path $runtimeSource 'certifi') | Out-Null
    Set-Content -LiteralPath (Join-Path $runtimeSource 'python313.dll') -Value 'runtime fixture'
    Set-Content -LiteralPath (Join-Path $runtimeSource 'certifi/cacert.pem') -Value 'public certificate fixture'
    $setup = Build-TestSetup '1.1.0'
    $releaseOwner = Join-Path $testRoot 'exit-owner'
    $ownerScript = Join-Path $testRoot 'owner.ps1'
    Set-Content -LiteralPath $ownerScript -Value @'
param([string]$ReleaseFile)
while (-not (Test-Path -LiteralPath $ReleaseFile)) { Start-Sleep -Milliseconds 100 }
'@
    $ownerProcess = Start-Process -FilePath (Get-Process -Id $PID).Path -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', "`"$ownerScript`"", '-ReleaseFile', "`"$releaseOwner`""
    )
    $upgradeProcess = Start-Process -FilePath $setup -WindowStyle Hidden -PassThru -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', '/TASKS=""',
        "/DIR=`"$target`"", "/UPDATEPID=$($ownerProcess.Id)", "/LOG=`"$(Join-Path $testRoot 'upgrade.log')`""
    )
    Start-Sleep -Seconds 2
    if ($upgradeProcess.HasExited -or (Get-Content -LiteralPath (Join-Path $target 'qingjuan.exe') -Raw).Trim() -ne 'client version one') {
        throw 'Installer did not wait for the original process to exit.'
    }
    Set-Content -LiteralPath $releaseOwner -Value 'exit'
    if (-not $upgradeProcess.WaitForExit(30000) -or $upgradeProcess.ExitCode -ne 0) {
        throw 'Upgrade failed after the original process exited.'
    }
    if ((Get-Content -LiteralPath (Join-Path $target 'qingjuan.exe') -Raw).Trim() -ne 'client version two') {
        throw 'Upgrade did not replace the client.'
    }
    if ((Get-FileHash -LiteralPath $sentinel).Hash -ne $hash) { throw 'Upgrade changed user data.' }
    $installedRuntime = Join-Path $target 'backend/_internal'
    foreach ($relative in @('python313.dll', 'certifi/cacert.pem')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installedRuntime $relative))) {
            throw "Upgrade did not install runtime dependency: $relative"
        }
    }
    Invoke-TestSetup (Join-Path $target 'unins000.exe') @()
    $uninstalled = $true
    if (Test-Path -LiteralPath (Join-Path $target 'qingjuan.exe')) { throw 'Uninstall did not remove the client.' }
    if ((Get-FileHash -LiteralPath $sentinel).Hash -ne $hash) { throw 'Uninstall changed user data.' }
    if (Test-Path -LiteralPath (Join-Path $installedRuntime 'python313.dll')) {
        throw 'Uninstall did not remove the bundled runtime.'
    }
    Write-Host 'Installer smoke passed: install, wait for process exit, upgrade, uninstall and user data preservation.'
}
finally {
    foreach ($ownedProcess in @($ownerProcess, $upgradeProcess)) {
        if ($null -ne $ownedProcess -and -not $ownedProcess.HasExited) {
            $ownedProcess.Kill()
            $ownedProcess.WaitForExit()
        }
    }
    if ($installStarted -and -not $uninstalled -and (Test-Path -LiteralPath (Join-Path $target 'unins000.exe'))) {
        Invoke-TestSetup (Join-Path $target 'unins000.exe') @()
    }
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
    if ($resolvedTestRoot -ne $testRoot -or -not $resolvedTestRoot.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a test directory outside the verified workspace path.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
