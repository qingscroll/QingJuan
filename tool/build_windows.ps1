[CmdletBinding()]
param(
    [switch]$SkipBackend,
    [switch]$AllowFlutterVersionMismatch
)

$ErrorActionPreference = "Stop"
$requiredFlutterVersion = "3.44.4"
$nugetVersion = "6.12.1"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$flutterOutput = Join-Path $projectRoot "build/windows/x64/runner/Release"
$releaseOutput = Join-Path $projectRoot "release/qingjuan-windows"
$backendRoot = Join-Path $projectRoot "python-backend"

function Assert-FlutterVersion {
    $versionOutput = flutter --version --machine
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query Flutter version; flutter exited with code $LASTEXITCODE."
    }
    $versionText = $versionOutput -join [Environment]::NewLine
    $jsonStart = $versionText.IndexOf("{")
    if ($jsonStart -lt 0) {
        throw "Unable to parse Flutter version; machine output did not contain JSON."
    }
    try {
        $version = $versionText.Substring($jsonStart) | ConvertFrom-Json
    }
    catch {
        throw "Unable to parse Flutter version JSON: $($_.Exception.Message)"
    }
    if ($version.frameworkVersion -eq $requiredFlutterVersion) {
        return
    }

    $message = "Flutter $requiredFlutterVersion is required; found $($version.frameworkVersion)."
    if (-not $AllowFlutterVersionMismatch) {
        throw "$message Pass -AllowFlutterVersionMismatch only for migration testing."
    }
    Write-Warning $message
}

function Enable-NuGet {
    if (Get-Command "nuget.exe" -ErrorAction SilentlyContinue) {
        return
    }

    $nugetDirectory = Join-Path $projectRoot ".dart_tool/nuget/$nugetVersion"
    $nugetPath = Join-Path $nugetDirectory "nuget.exe"
    if (-not (Test-Path -LiteralPath $nugetPath)) {
        New-Item -ItemType Directory -Path $nugetDirectory -Force | Out-Null
        $downloadUrl = "https://dist.nuget.org/win-x86-commandline/v$nugetVersion/nuget.exe"
        Write-Host "NuGet was not found. Downloading official version $nugetVersion..."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $nugetPath
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $nugetPath
    $signedByMicrosoft = $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match "Microsoft Corporation"
    if ($signature.Status -ne "Valid" -or -not $signedByMicrosoft) {
        Remove-Item -LiteralPath $nugetPath -Force -ErrorAction SilentlyContinue
        throw "NuGet signature validation failed. The downloaded file was removed."
    }

    $env:Path = "$nugetDirectory;$env:Path"
}

Push-Location $projectRoot
try {
    Assert-FlutterVersion
    Enable-NuGet
    flutter config --enable-windows-desktop
    if ($LASTEXITCODE -ne 0) {
        throw "flutter config --enable-windows-desktop failed with exit code $LASTEXITCODE."
    }
    flutter pub get
    if ($LASTEXITCODE -ne 0) {
        throw "flutter pub get failed with exit code $LASTEXITCODE."
    }
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows --release failed with exit code $LASTEXITCODE."
    }

    if (Test-Path -LiteralPath $releaseOutput) {
        $resolvedOutput = (Resolve-Path -LiteralPath $releaseOutput).Path
        $expectedOutput = [IO.Path]::GetFullPath((Join-Path $projectRoot 'release/qingjuan-windows'))
        if ($resolvedOutput -ne $expectedOutput -or (Get-Item -LiteralPath $releaseOutput).LinkType) {
            throw 'Refusing to replace a release directory outside the expected workspace path.'
        }
        $runtimeData = Join-Path $releaseOutput 'backend/data'
        if ((Test-Path -LiteralPath $runtimeData) -and
            (Get-ChildItem -LiteralPath $runtimeData -Force | Select-Object -First 1)) {
            throw "Release directory contains user data: $runtimeData. Back it up before rebuilding."
        }
        Remove-Item -LiteralPath $releaseOutput -Recurse -Force
    }
    New-Item -ItemType Directory -Path $releaseOutput | Out-Null
    Copy-Item -Path (Join-Path $flutterOutput "*") -Destination $releaseOutput -Recurse

    if (-not $SkipBackend) {
        $adminStatic = Join-Path $backendRoot "app/admin_static"
        if (-not (Test-Path -LiteralPath (Join-Path $adminStatic "index.html") -PathType Leaf)) {
            throw "Built admin assets are missing. Run npm ci --prefix admin-web and npm run build --prefix admin-web first."
        }

        python -m PyInstaller `
            --noconfirm `
            --clean `
            --distpath $releaseOutput `
            --workpath (Join-Path $backendRoot "build") `
            (Join-Path $projectRoot "deploy/windows/backend.spec")
        if ($LASTEXITCODE -ne 0) {
            throw "PyInstaller failed with exit code $LASTEXITCODE."
        }
    }

    Write-Host "Windows client package created: $releaseOutput"
}
finally {
    Pop-Location
}
