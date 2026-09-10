[CmdletBinding()]
param(
    [ValidateRange(0, 65535)]
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"

function Get-SmokeTestPort {
    param([int]$RequestedPort)
    $reservation = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback, $RequestedPort
    )
    $reservation.Server.ExclusiveAddressUse = $true
    try {
        $reservation.Start()
        return ([System.Net.IPEndPoint]$reservation.LocalEndpoint).Port
    }
    catch {
        throw "Smoke-test port $RequestedPort is already occupied or unavailable; no requests were sent."
    }
    finally {
        $reservation.Stop()
    }
}

function Get-SmokeOwnedProcess {
    param([int]$ProcessId)
    $lineage = @()
    $visited = @{}
    $candidateId = $ProcessId
    $childStart = [long]::MaxValue
    while (-not $visited.ContainsKey($candidateId)) {
        $visited[$candidateId] = $true
        $candidate = Get-Process -Id $candidateId -ErrorAction SilentlyContinue
        if ($null -eq $candidate) { return $null }
        try { $started = $candidate.StartTime.ToUniversalTime().Ticks }
        catch { return $null }
        if ($started -gt $childStart) { return $null }
        if ($ownedProcessStarts.ContainsKey($candidateId)) {
            if ($ownedProcessStarts[$candidateId] -ne $started) { return $null }
            foreach ($entry in $lineage) {
                $ownedProcessStarts[$entry.Id] = $entry.Start
            }
            return Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        }
        $lineage += @{ Id = $candidateId; Start = $started }
        $metadata = Get-CimInstance Win32_Process -Filter "ProcessId = $candidateId" -ErrorAction Stop
        if ($null -eq $metadata) { return $null }
        # A PID can be reused between querying Process and its parent metadata.
        if ([math]::Abs(($metadata.CreationDate.ToUniversalTime().Ticks - $started)) -gt 10000) {
            return $null
        }
        $candidateId = [int]$metadata.ParentProcessId
        $childStart = $started
    }
    return $null
}

function Assert-SmokeListenerOwnership {
    param([switch]$AllowNotListening)
    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0') })
    if ($listeners.Count -eq 0) {
        if ($AllowNotListening) { return $false }
        throw "The smoke-test backend no longer owns a listening socket on port $Port."
    }
    foreach ($listener in $listeners) {
        if ($null -eq (Get-SmokeOwnedProcess -ProcessId $listener.OwningProcess)) {
            throw "Refusing HTTP on port ${Port}: its listener is outside the smoke-test process tree."
        }
    }
    return $true
}

function Stop-SmokeOwnedProcesses {
    # Discover descendants before terminating parents. Port ownership and an
    # executable path alone never authorize terminating another process.
    $snapshot = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    do {
        $previousCount = $ownedProcessStarts.Count
        foreach ($candidate in $snapshot) {
            if ($ownedProcessStarts.ContainsKey([int]$candidate.ParentProcessId)) {
                $null = Get-SmokeOwnedProcess -ProcessId $candidate.ProcessId
            }
        }
    } while ($ownedProcessStarts.Count -gt $previousCount)
    $failures = @()
    $identities = @($ownedProcessStarts.GetEnumerator() | Sort-Object Value -Descending)
    foreach ($identity in $identities) {
        $owned = Get-Process -Id $identity.Key -ErrorAction SilentlyContinue
        if ($null -eq $owned) { continue }
        try {
            if ($owned.StartTime.ToUniversalTime().Ticks -ne $identity.Value) { continue }
            $owned.Kill()
            if (-not $owned.WaitForExit(10000)) {
                $failures += "Owned process $($identity.Key) did not exit."
            }
        }
        catch {
            if (-not $owned.HasExited) { $failures += "Could not stop owned process $($identity.Key)." }
        }
    }
    if ($failures.Count -gt 0) { throw ($failures -join ' ') }
}

function Test-SmokeReadingProgress {
    $boundary = 'qingjuan-smoke-' + [Guid]::NewGuid().ToString('N')
    # Keep source ASCII so Windows PowerShell 5.1 also constructs valid UTF-8.
    $bookKind = -join ([char[]](0x957F, 0x5C0F, 0x8BF4))
    $language = -join ([char[]](0x4E2D, 0x6587))
    $fixture = "Chapter 1 Smoke import`r`nThis is the first isolated chapter.`r`n`r`nChapter 2 Reading position`r`n"
    $fixture += (1..12 | ForEach-Object { "Paragraph $_ - fixture text for packaged database and reading-position verification." }) -join "`r`n"
    $parts = @(
        "--$boundary`r`nContent-Disposition: form-data; name=`"bookKind`"`r`n`r`n$bookKind`r`n"
        "--$boundary`r`nContent-Disposition: form-data; name=`"language`"`r`n`r`n$language`r`n"
        "--$boundary`r`nContent-Disposition: form-data; name=`"title`"`r`n`r`nSmoke reading position`r`n"
        "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"smoke-position.txt`"`r`nContent-Type: text/plain; charset=utf-8`r`n`r`n$fixture`r`n"
        "--$boundary--`r`n"
    )
    $requestHeaders = @{ 'X-QingJuan-Local-Request' = '1' }
    Assert-SmokeListenerOwnership | Out-Null
    $book = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/v1/books/import-local" `
        -Method Post -Headers $requestHeaders -ContentType "multipart/form-data; boundary=$boundary" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes(($parts -join ''))) -TimeoutSec 20
    if ([string]::IsNullOrWhiteSpace($book.id) -or $book.chapterCount -ne 2) {
        throw 'Packaged backend did not import the two-chapter smoke fixture.'
    }
    $bookId = [Uri]::EscapeDataString($book.id)
    $position = @{
        chapterIndex = 2; scrollRatio = 0.4
        anchorType = 'paragraph'; anchorIndex = 1; anchorOffsetRatio = 0.25
        pageIndex = 2; pageCount = 6; layoutKey = 'smoke-layout-v1'
        contentMode = 'original'; characterOffset = 96
    }
    $body = [System.Text.Encoding]::UTF8.GetBytes(($position | ConvertTo-Json -Compress))
    Assert-SmokeListenerOwnership | Out-Null
    $saved = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/v1/books/$bookId/progress" `
        -Method Put -Headers $requestHeaders -ContentType 'application/json; charset=utf-8' `
        -Body $body -TimeoutSec 5
    Assert-SmokeListenerOwnership | Out-Null
    $detail = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/v1/books/$bookId" -TimeoutSec 5
    $expected = @{
        lastChapterIndex = 2; lastScrollRatio = 0.4
        lastAnchorType = 'paragraph'; lastAnchorIndex = 1; lastAnchorOffsetRatio = 0.25
        lastPageIndex = 2; lastPageCount = 6; lastLayoutKey = 'smoke-layout-v1'
        lastContentMode = 'original'; lastCharacterOffset = 96
    }
    foreach ($field in $expected.Keys) {
        if ($saved.$field -ne $expected[$field] -or $detail.progress.$field -ne $expected[$field]) {
            throw "Packaged backend did not persist reading-progress field $field."
        }
    }
    if ($detail.book.lastReadPageIndex -ne 2 -or $detail.book.lastReadPageCount -ne 6) {
        throw 'Packaged backend did not expose page position in the book summary.'
    }
    Assert-SmokeListenerOwnership | Out-Null
    $chapter = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$Port/api/v1/books/$bookId/chapters/2?mode=original" -TimeoutSec 5
    if ($chapter.chapter.index -ne 2 -or [string]::IsNullOrWhiteSpace($chapter.content)) {
        throw 'Packaged backend could not read the chapter referenced by saved progress.'
    }
    Write-Output 'Packaged reading progress passed: imported fixture, chapter, page, layout, character and paragraph anchors.'
}

function Test-SmokeSitePlugin {
    Add-Type -AssemblyName System.IO.Compression
    $archiveBytes = New-Object System.IO.MemoryStream
    $archive = [System.IO.Compression.ZipArchive]::new(
        $archiveBytes, [System.IO.Compression.ZipArchiveMode]::Create, $true
    )
    try {
        foreach ($name in @('manifest.json', 'plugin.py')) {
            $entry = $archive.CreateEntry($name)
            $stream = $entry.Open()
            try {
                $bytes = [System.IO.File]::ReadAllBytes((Join-Path $projectRoot "examples/plugins/demo-novel/$name"))
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally { $stream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
    $boundary = 'qingjuan-plugin-' + [Guid]::NewGuid().ToString('N')
    $bodyStream = New-Object System.IO.MemoryStream
    try {
        $prefix = "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"demo.qjplugin`"`r`nContent-Type: application/zip`r`n`r`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($prefix)
        $bodyStream.Write($bytes, 0, $bytes.Length)
        $archiveBytes.Position = 0
        $archiveBytes.CopyTo($bodyStream)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n")
        $bodyStream.Write($bytes, 0, $bytes.Length)
        $body = $bodyStream.ToArray()
    }
    finally { $bodyStream.Dispose(); $archiveBytes.Dispose() }

    $headers = @{ 'X-QingJuan-Local-Request' = '1' }
    $base = "http://127.0.0.1:$Port/api/v1"
    Assert-SmokeListenerOwnership | Out-Null
    $inspection = Invoke-RestMethod -Uri "$base/plugins/inspect" -Method Post -Headers $headers `
        -ContentType "multipart/form-data; boundary=$boundary" -Body $body -TimeoutSec 20
    if ($inspection.plugin.id -ne 'demo-novel') { throw 'Plugin package inspection failed.' }
    Assert-SmokeListenerOwnership | Out-Null
    $installed = Invoke-RestMethod -Uri "$base/plugins/import" -Method Post -Headers $headers `
        -ContentType "multipart/form-data; boundary=$boundary" -Body $body -TimeoutSec 20
    if ($installed.origin -ne 'installed') { throw 'Packaged backend did not install the external plugin.' }

    $keyword = -join ([char[]](0x9752, 0x5377))
    $json = [System.Text.Encoding]::UTF8.GetBytes((@{ keyword = $keyword; limit = 10 } | ConvertTo-Json -Compress))
    Assert-SmokeListenerOwnership | Out-Null
    $results = @(Invoke-RestMethod -Uri "$base/plugins/search" -Method Post -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body $json -TimeoutSec 20)
    if ($results.Count -ne 1) { throw 'Installed plugin search failed in the frozen backend.' }
    $payload = @{
        sourceUrl = $results[0].sourceUrl
        bookKind = $inspection.plugin.bookKinds[0]
        language = -join ([char[]](0x4E2D, 0x6587))
    }
    $json = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
    Assert-SmokeListenerOwnership | Out-Null
    $book = Invoke-RestMethod -Uri "$base/books/import" -Method Post -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body $json -TimeoutSec 30
    if ($book.chapterCount -ne 2) { throw 'Installed plugin did not download its two chapters.' }
    $bookId = [Uri]::EscapeDataString($book.id)
    Assert-SmokeListenerOwnership | Out-Null
    Invoke-RestMethod -Uri "$base/plugins/demo-novel" -Method Delete -Headers $headers -TimeoutSec 10 | Out-Null
    Assert-SmokeListenerOwnership | Out-Null
    $chapter = Invoke-RestMethod -Uri "$base/books/$bookId/chapters/1?mode=original" -TimeoutSec 10
    if ([string]::IsNullOrWhiteSpace($chapter.content)) { throw 'Plugin uninstall removed cached chapter content.' }
    Write-Output 'Packaged site plugins passed: inspect, install, search, download, uninstall and cached reading.'
}

# Reserve an unused loopback port before starting a backend or sending HTTP.
# Listener ownership is checked again after launch to handle reservation races.
$Port = Get-SmokeTestPort -RequestedPort $Port
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseOutput = Join-Path $projectRoot "release/qingjuan-windows"
$versionLine = Get-Content -LiteralPath (Join-Path $projectRoot "pubspec.yaml") -Encoding UTF8 |
    Where-Object { $_ -match "^version:\s*" } |
    Select-Object -First 1
if (-not $versionLine -or $versionLine -notmatch "^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$") {
    throw "pubspec.yaml must contain version: major.minor.patch+build."
}
$expectedVersion = $Matches[1]
$clientPath = Join-Path $releaseOutput "qingjuan.exe"
$flutterLibrary = Join-Path $releaseOutput "flutter_windows.dll"
$flutterAssets = Join-Path $releaseOutput "data/flutter_assets"
$backendPath = Join-Path $releaseOutput "backend/qingjuan-desktop.exe"

foreach ($requiredPath in @($clientPath, $flutterLibrary, $flutterAssets, $backendPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Windows release is missing required client content: $requiredPath"
    }
}

$clientVersion = (Get-Item -LiteralPath $clientPath).VersionInfo
if ($clientVersion.FileVersion -ne $expectedVersion -or
    $clientVersion.ProductVersion -ne $expectedVersion) {
    throw "qingjuan.exe version does not match $expectedVersion."
}

$forbiddenFiles = @(
    Get-ChildItem -LiteralPath $releaseOutput -Recurse -File |
        Where-Object {
            $_.Extension.ToLowerInvariant() -in @(".db", ".sqlite", ".sqlite3", ".pem", ".key")
        }
)
if ($forbiddenFiles.Count -gt 0) {
    throw "Windows release contains runtime data or secret files: $($forbiddenFiles.FullName -join ', ')"
}

$smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "qingjuan-release-smoke-" + [Guid]::NewGuid().ToString("N")
)
New-Item -ItemType Directory -Path $smokeRoot -Force | Out-Null
$previousDataDir = $env:QINGJUAN_DATA_DIR
$previousTrustLocalAdmin = $env:QINGJUAN_TRUST_LOCAL_ADMIN
$previousDisableAdminWeb = $env:QINGJUAN_DISABLE_ADMIN_WEB
$previousAuthTokenDigest = $env:QINGJUAN_AUTH_TOKEN_SHA256
$previousMultiUser = $env:QINGJUAN_MULTI_USER
$previousTwoFactorEncryptionKey = $env:QINGJUAN_2FA_ENCRYPTION_KEY
$env:QINGJUAN_DATA_DIR = Join-Path $smokeRoot "data"
$env:QINGJUAN_TRUST_LOCAL_ADMIN = "1"
$env:QINGJUAN_DISABLE_ADMIN_WEB = "1"
$env:QINGJUAN_AUTH_TOKEN_SHA256 = ""
$env:QINGJUAN_MULTI_USER = "0"
$env:QINGJUAN_2FA_ENCRYPTION_KEY = ""
$stdout = Join-Path $smokeRoot "backend.stdout.log"
$stderr = Join-Path $smokeRoot "backend.stderr.log"
$ownedProcessStarts = @{}
$cleanupFailure = $null
try {
    $process = Start-Process -FilePath $backendPath -ArgumentList @(
        "serve", "--host", "127.0.0.1", "--port", "$Port", "--parent-pid", "$PID"
    ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $ownedProcessStarts[$process.Id] = $process.StartTime.ToUniversalTime().Ticks
    $health = $null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if ($process.HasExited) {
            $errorOutput = Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
            throw "Packaged backend exited early: $errorOutput"
        }
        if (-not (Assert-SmokeListenerOwnership -AllowNotListening)) {
            Start-Sleep -Milliseconds 250
            continue
        }
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/healthz" -TimeoutSec 2
            break
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if ($null -eq $health -or $health.status -ne "ok") {
        throw "Packaged backend health check timed out."
    }

    Assert-SmokeListenerOwnership | Out-Null
    $meta = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/v1/meta" -TimeoutSec 5
    if ($meta.service -ne "qingjuan-backend" -or $meta.appVersion -ne $expectedVersion.Split("+")[0]) {
        throw "Packaged backend metadata does not match the client version."
    }
    if ($meta.capabilities.adminWeb) {
        throw "Windows local backend unexpectedly advertises the admin web interface."
    }

    Assert-SmokeListenerOwnership | Out-Null
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$Port/admin/" -TimeoutSec 5 -UseBasicParsing | Out-Null
        throw "Windows local backend unexpectedly serves the admin web interface."
    }
    catch {
        $statusCode = [int]$_.Exception.Response.StatusCode
        if ($statusCode -ne 404) {
            throw
        }
    }

    foreach ($hiddenMultiUserPath in @(
        "/api/v1/auth/registration-policy",
        "/api/v1/auth/account/security",
        "/admin/api/registration-settings",
        "/admin/api/users"
    )) {
        Assert-SmokeListenerOwnership | Out-Null
        try {
            Invoke-WebRequest `
                -Uri "http://127.0.0.1:$Port$hiddenMultiUserPath" `
                -TimeoutSec 5 `
                -UseBasicParsing | Out-Null
            throw "Windows local backend unexpectedly exposes $hiddenMultiUserPath."
        }
        catch {
            $hiddenResponse = $_.Exception.Response
            if ($null -eq $hiddenResponse -or [int]$hiddenResponse.StatusCode -ne 404) {
                throw
            }
        }
    }

    $hiddenMultiUserPosts = @(
        @{ Path = "/api/v1/auth/email-code"; Body = @{ email = "reader@example.com" } },
        @{
            Path = "/api/v1/auth/register"
            Body = @{
                username = "reader"
                email = "reader@example.com"
                password = "release-smoke-password"
            }
        },
        @{
            Path = "/api/v1/auth/login"
            Body = @{ username = "reader"; password = "release-smoke-password" }
        },
        @{
            Path = "/api/v1/auth/login/2fa"
            Body = @{ challengeToken = ("x" * 43); code = "123456" }
        },
        @{
            Path = "/api/v1/auth/github/device/start"
            Body = @{ purpose = "login" }
        },
        @{
            Path = "/api/v1/auth/github/device/poll"
            Body = @{ flowId = ("x" * 43) }
        },
        @{
            Path = "/api/v1/auth/account/github/unbind"
            Body = @{ password = "release-smoke-password" }
        },
        @{
            Path = "/api/v1/auth/account/2fa/setup"
            Body = @{ password = "release-smoke-password" }
        },
        @{
            Path = "/api/v1/auth/account/2fa/enable"
            Body = @{ setupId = ("x" * 43); code = "123456" }
        },
        @{
            Path = "/api/v1/auth/account/2fa/disable"
            Body = @{ password = "release-smoke-password"; code = "123456" }
        },
        @{
            Path = "/api/v1/auth/account/2fa/recovery-codes"
            Body = @{ password = "release-smoke-password"; code = "123456" }
        }
    )
    foreach ($hiddenPost in $hiddenMultiUserPosts) {
        Assert-SmokeListenerOwnership | Out-Null
        try {
            Invoke-WebRequest `
                -Uri "http://127.0.0.1:$Port$($hiddenPost.Path)" `
                -Method Post `
                -ContentType "application/json" `
                -Body ($hiddenPost.Body | ConvertTo-Json -Compress) `
                -TimeoutSec 5 `
                -UseBasicParsing | Out-Null
            throw "Windows local backend unexpectedly exposes $($hiddenPost.Path)."
        }
        catch {
            $hiddenResponse = $_.Exception.Response
            if ($null -eq $hiddenResponse -or [int]$hiddenResponse.StatusCode -ne 404) {
                throw
            }
        }
    }

    Assert-SmokeListenerOwnership | Out-Null
    $settings = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/v1/settings" -TimeoutSec 5
    $settings.translationModel.enabled = $false
    $settings.translationModel | Add-Member -NotePropertyName apiKey -NotePropertyValue "" -Force
    $settings.translationModel | Add-Member -NotePropertyName apiKeyAction -NotePropertyValue "keep" -Force
    $settings.mangaOcr | Add-Member -NotePropertyName apiKey -NotePropertyValue "" -Force
    $settings.mangaOcr | Add-Member -NotePropertyName apiKeyAction -NotePropertyValue "keep" -Force
    $settings.bika = @{
        email = ""
        password = ""
        passwordAction = "keep"
    }
    # Windows PowerShell 5.1 otherwise encodes a string request body with the
    # active ANSI code page even when the media type is JSON. Send explicit
    # UTF-8 bytes so settings containing Chinese text round-trip correctly.
    $settingsJson = $settings | ConvertTo-Json -Depth 8 -Compress
    $settingsBody = [System.Text.Encoding]::UTF8.GetBytes($settingsJson)
    Assert-SmokeListenerOwnership | Out-Null
    $savedSettings = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$Port/api/v1/settings" `
        -Method Put `
        -Headers @{ "X-QingJuan-Local-Request" = "1" } `
        -ContentType "application/json; charset=utf-8" `
        -Body $settingsBody `
        -TimeoutSec 5
    if ($savedSettings.translationModel.enabled) {
        throw "Windows client model settings API did not persist the update."
    }

    Test-SmokeReadingProgress
    Test-SmokeSitePlugin
    Write-Output "Windows combined package smoke test passed: version=$expectedVersion port=$Port"
}
finally {
    try { Stop-SmokeOwnedProcesses }
    catch { $cleanupFailure = $_ }
    if ($null -eq $previousDataDir) {
        Remove-Item Env:QINGJUAN_DATA_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:QINGJUAN_DATA_DIR = $previousDataDir
    }
    if ($null -eq $previousTrustLocalAdmin) {
        Remove-Item Env:QINGJUAN_TRUST_LOCAL_ADMIN -ErrorAction SilentlyContinue
    }
    else {
        $env:QINGJUAN_TRUST_LOCAL_ADMIN = $previousTrustLocalAdmin
    }
    if ($null -eq $previousDisableAdminWeb) {
        Remove-Item Env:QINGJUAN_DISABLE_ADMIN_WEB -ErrorAction SilentlyContinue
    }
    else {
        $env:QINGJUAN_DISABLE_ADMIN_WEB = $previousDisableAdminWeb
    }
    if ($null -eq $previousAuthTokenDigest) {
        Remove-Item Env:QINGJUAN_AUTH_TOKEN_SHA256 -ErrorAction SilentlyContinue
    }
    else {
        $env:QINGJUAN_AUTH_TOKEN_SHA256 = $previousAuthTokenDigest
    }
    if ($null -eq $previousMultiUser) {
        Remove-Item Env:QINGJUAN_MULTI_USER -ErrorAction SilentlyContinue
    }
    else {
        $env:QINGJUAN_MULTI_USER = $previousMultiUser
    }
    if ($null -eq $previousTwoFactorEncryptionKey) {
        Remove-Item Env:QINGJUAN_2FA_ENCRYPTION_KEY -ErrorAction SilentlyContinue
    }
    else {
        $env:QINGJUAN_2FA_ENCRYPTION_KEY = $previousTwoFactorEncryptionKey
    }
    if ($null -ne $cleanupFailure) { throw $cleanupFailure }
}
