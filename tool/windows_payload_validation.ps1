function Test-PackagedPublicCertificate {
    param([System.IO.FileInfo]$File, [string]$ReleaseRoot)
    $relativePath = $File.FullName.Substring($ReleaseRoot.Length + 1).Replace('\', '/')
    # HTTPS trust stores are dependencies, not user credentials. Permit only
    # these known locations and reject any PEM containing private key material.
    if ($relativePath -notin @(
        'backend/_internal/certifi/cacert.pem',
        'backend/_internal/curl_cffi/cacert.pem'
    )) { return $false }
    $content = [System.IO.File]::ReadAllText($File.FullName)
    return $content.Contains('-----BEGIN CERTIFICATE-----') -and
        -not $content.Contains('PRIVATE KEY')
}

function Assert-WindowsBackendRuntime {
    param([string]$ReleaseRoot)
    $runtimeRoot = Join-Path $ReleaseRoot 'backend/_internal'
    foreach ($relative in @('python313.dll', 'pubspec.yaml', 'app/windows_ocr.ps1', 'cv2/cv2.pyd')) {
        if (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot $relative) -PathType Leaf)) {
            throw "Windows backend runtime is incomplete: $relative"
        }
    }
    $models = @(Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'rapidocr/models') -Filter '*.onnx' -File)
    if ($models.Count -lt 2) { throw 'Offline OCR models are missing from the Windows package.' }
}
