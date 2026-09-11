[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,
    [switch]$ValidateVersionOnly,
    [string]$IsccPath
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pubspecPath = Join-Path $projectRoot "pubspec.yaml"
$releaseOutput = Join-Path $projectRoot "release/qingjuan-windows"
$archiveDirectory = Join-Path $projectRoot "release"
. (Join-Path $PSScriptRoot 'windows_payload_validation.ps1')

$versionLine = Get-Content -LiteralPath $pubspecPath -Encoding UTF8 |
    Where-Object { $_ -match "^version:\s*" } |
    Select-Object -First 1
if (-not $versionLine -or $versionLine -notmatch "^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$") {
    throw "pubspec.yaml must contain version: major.minor.patch+build."
}
$semanticVersion = $Matches[1]
$buildNumber = $Matches[2]
$fullVersion = "$semanticVersion+$buildNumber"

if ($Tag -notmatch "^[vV](\d+\.\d+\.\d+)$") {
    throw "Release tag must use vmajor.minor.patch."
}
$tagVersion = $Matches[1]
if ($tagVersion -ne $semanticVersion) {
    throw "Release tag $Tag does not match pubspec version $semanticVersion."
}

Write-Host "Release version validated: $Tag ($fullVersion)"
if ($ValidateVersionOnly) {
    return
}

$requiredFiles = @(
    (Join-Path $releaseOutput "qingjuan.exe"),
    (Join-Path $releaseOutput "flutter_windows.dll"),
    (Join-Path $releaseOutput "msvcp140.dll"),
    (Join-Path $releaseOutput "vcruntime140.dll"),
    (Join-Path $releaseOutput "vcruntime140_1.dll"),
    (Join-Path $releaseOutput "backend/qingjuan-desktop.exe")
)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Release package is missing required file: $requiredFile"
    }
}
$flutterAssets = Join-Path $releaseOutput "data/flutter_assets"
if (-not (Test-Path -LiteralPath $flutterAssets -PathType Container)) {
    throw "Release package is missing Flutter assets: $flutterAssets"
}
$clientVersion = (Get-Item -LiteralPath (Join-Path $releaseOutput "qingjuan.exe")).VersionInfo
if ($clientVersion.FileVersion -ne $fullVersion -or $clientVersion.ProductVersion -ne $fullVersion) {
    throw "qingjuan.exe version does not match $fullVersion (FileVersion=$($clientVersion.FileVersion), ProductVersion=$($clientVersion.ProductVersion))."
}

$forbiddenExtensions = @(".db", ".sqlite", ".sqlite3", ".log", ".pem", ".key")
$forbiddenNames = @(".env", "settings.json")
$forbiddenFiles = @(
    Get-ChildItem -LiteralPath $releaseOutput -Recurse -Force -File |
        Where-Object {
            ($_.Name -in $forbiddenNames -or
            $_.Extension.ToLowerInvariant() -in $forbiddenExtensions) -and
            -not (Test-PackagedPublicCertificate -File $_ -ReleaseRoot $releaseOutput)
        }
)
if ($forbiddenFiles.Count -gt 0) {
    $relativePaths = $forbiddenFiles |
        ForEach-Object { $_.FullName.Substring($releaseOutput.Length + 1) }
    throw "Release package contains forbidden runtime or secret files: $($relativePaths -join ', ')"
}

New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null
Assert-WindowsBackendRuntime -ReleaseRoot $releaseOutput
$archivePath = Join-Path $archiveDirectory "QingJuan-v$semanticVersion-windows-x64.zip"
Compress-Archive -LiteralPath $releaseOutput -DestinationPath $archivePath -CompressionLevel Optimal -Force

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
    $requiredEntries = @(
        "qingjuan-windows/qingjuan.exe",
        "qingjuan-windows/flutter_windows.dll",
        "qingjuan-windows/msvcp140.dll",
        "qingjuan-windows/vcruntime140.dll",
        "qingjuan-windows/vcruntime140_1.dll",
        "qingjuan-windows/backend/qingjuan-desktop.exe"
    )
    foreach ($requiredEntry in $requiredEntries) {
        if ($requiredEntry -notin $entryNames) {
            throw "Release archive is missing required entry: $requiredEntry"
        }
    }
    if (-not ($entryNames | Where-Object { $_.StartsWith("qingjuan-windows/data/flutter_assets/") })) {
        throw "Release archive is missing data/flutter_assets."
    }
}
finally {
    $archive.Dispose()
}

$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$hashPath = "$archivePath.sha256"
Set-Content -LiteralPath $hashPath -Value "$hash  $([System.IO.Path]::GetFileName($archivePath))" -Encoding ASCII

if ([string]::IsNullOrWhiteSpace($IsccPath)) {
    $IsccPath = & (Join-Path $PSScriptRoot 'get_inno_setup.ps1')
}
& $IsccPath "/DAppVersion=$semanticVersion" "/DBuildNumber=$buildNumber" `
    "/DSourceDir=$releaseOutput" "/DOutputDir=$archiveDirectory" `
    (Join-Path $projectRoot 'deploy/windows/qingjuan.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed: $LASTEXITCODE" }
$installerPath = Join-Path $archiveDirectory "QingJuan-v$semanticVersion-windows-x64-setup.exe"
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Windows installer is missing: $installerPath"
}
$installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$installerHashPath = "$installerPath.sha256"
Set-Content -LiteralPath $installerHashPath -Value "$installerHash  $([System.IO.Path]::GetFileName($installerPath))" -Encoding ASCII

if ($env:GITHUB_OUTPUT) {
    "archive=$archivePath" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding UTF8 -Append
    "checksum=$hashPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding UTF8 -Append
    "version=$semanticVersion" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding UTF8 -Append
    "sha256=$hash" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding UTF8 -Append
    "installer=$installerPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding UTF8 -Append
    "installer_checksum=$installerHashPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding UTF8 -Append
}

Write-Host "Windows release archive created: $archivePath"
Write-Host "SHA-256: $hash"
Write-Host "Windows installer created: $installerPath"
