[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$compilerRoot = Join-Path $projectRoot '.dart_tool/inno-setup/6.7.3'
$compilerPath = Join-Path $compilerRoot 'ISCC.exe'
if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
    $cacheRoot = Join-Path $projectRoot '.dart_tool/inno-setup'
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $installer = Join-Path $cacheRoot 'innosetup-6.7.3.exe'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        Invoke-WebRequest -Uri 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe' -OutFile $installer
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid' -or
        -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') {
        throw 'Inno Setup installer signature is invalid. Remove the cached installer and retry.'
    }
    $process = Start-Process -FilePath $installer -WindowStyle Hidden -Wait -PassThru -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', '/NOICONS',
        "/DIR=`"$compilerRoot`""
    )
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $compilerPath)) {
        throw "Inno Setup installation failed: $($process.ExitCode)"
    }
}
return $compilerPath
