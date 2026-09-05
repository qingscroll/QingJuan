[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$smokeScript = Join-Path $PSScriptRoot 'smoke_test_windows_release.ps1'
$parseErrors = $null
$tokens = $null
$syntax = [System.Management.Automation.Language.Parser]::ParseFile(
    $smokeScript, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
$portParameter = $syntax.ParamBlock.Parameters |
    Where-Object { $_.Name.VariablePath.UserPath -eq 'Port' }
if ($portParameter.DefaultValue.Value -ne 0) { throw 'Default port must be allocated dynamically.' }
foreach ($definition in $syntax.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    Invoke-Expression $definition.Extent.Text
}

$occupied = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$occupied.Server.ExclusiveAddressUse = $true
$occupied.Start()
$heldPort = ([System.Net.IPEndPoint]$occupied.LocalEndpoint).Port
try {
    $allocated = Get-SmokeTestPort -RequestedPort 0
    if ($allocated -le 0 -or $allocated -eq $heldPort) { throw 'Invalid temporary port allocation.' }
    & {
        $script:safetyHttpRequests = 0
        $script:safetyProcessStarts = 0
        function Invoke-RestMethod { $script:safetyHttpRequests++; throw 'Unexpected HTTP request.' }
        function Invoke-WebRequest { $script:safetyHttpRequests++; throw 'Unexpected HTTP request.' }
        function Start-Process { $script:safetyProcessStarts++; throw 'Unexpected process start.' }
        $rejected = $false
        try { & $smokeScript -Port $heldPort }
        catch { $rejected = $_.Exception.Message -like '*already occupied or unavailable*' }
        if (-not $rejected -or $script:safetyHttpRequests -ne 0 -or $script:safetyProcessStarts -ne 0) {
            throw 'An occupied port must fail before starting a backend or sending HTTP.'
        }
    }
    if ($occupied.Pending()) { throw 'An HTTP/TCP request reached the occupied port.' }
}
finally {
    $occupied.Stop()
}

& {
    function Assert-SmokeListenerOwnership { $script:ownershipChecks++; return $true }
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec)
        $script:progressRequests++
        if ($script:progressRequests -ne $script:ownershipChecks) {
            throw 'Progress smoke request omitted listener ownership verification.'
        }
        if ($Method -eq 'Post') {
            $multipart = [System.Text.Encoding]::UTF8.GetString($Body)
            $expectedKind = -join ([char[]](0x957F, 0x5C0F, 0x8BF4))
            $expectedLanguage = -join ([char[]](0x4E2D, 0x6587))
            if ($multipart -notlike '*smoke-position.txt*' -or $multipart -notlike '*Chapter 2*' -or
                -not $multipart.Contains($expectedKind) -or -not $multipart.Contains($expectedLanguage) -or
                $Headers['X-QingJuan-Local-Request'] -ne '1') {
                throw 'Progress smoke fixture is missing multipart data or its local-request header.'
            }
            return [pscustomobject]@{ id = 'smoke-book'; chapterCount = 2 }
        }
        $expected = @{
            lastChapterIndex = 2; lastScrollRatio = 0.4
            lastAnchorType = 'paragraph'; lastAnchorIndex = 1; lastAnchorOffsetRatio = 0.25
            lastPageIndex = 2; lastPageCount = 6; lastLayoutKey = 'smoke-layout-v1'
            lastContentMode = 'original'; lastCharacterOffset = 96
        }
        if ($Method -eq 'Put') {
            $position = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            if ($position.chapterIndex -ne 2 -or $position.pageIndex -ne 2 -or
                $position.characterOffset -ne 96 -or $Headers['X-QingJuan-Local-Request'] -ne '1') {
                throw 'Progress smoke sent incorrect position metadata.'
            }
            if ($script:omitPageMetadata) { $expected.Remove('lastPageCount') }
            return [pscustomobject]$expected
        }
        if ($Uri -like '*/chapters/2?mode=original') {
            return [pscustomobject]@{ chapter = @{ index = 2 }; content = 'Smoke text' }
        }
        return [pscustomobject]@{
            progress = [pscustomobject]$expected
            book = @{ lastReadPageIndex = 2; lastReadPageCount = 6 }
        }
    }
    $Port = $allocated
    foreach ($omitMetadata in @($false, $true)) {
        $script:ownershipChecks = 0
        $script:progressRequests = 0
        $script:omitPageMetadata = $omitMetadata
        $rejected = $false
        try { Test-SmokeReadingProgress | Out-Null }
        catch {
            if ($_.Exception.Message -notlike '*did not persist reading-progress field lastPageCount*') { throw }
            $rejected = $true
        }
        if ($rejected -ne $omitMetadata) { throw 'Progress smoke did not enforce persisted page fields.' }
    }
}

# Two same-executable helpers prove that executable identity is insufficient.
# Only the child whose ancestry we register may be stopped by smoke cleanup.
$shellPath = (Get-Process -Id $PID).Path
$child = $null
$unrelated = $null
try {
    $child = Start-Process -FilePath $shellPath -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30'
    ) -WindowStyle Hidden -PassThru
    $unrelated = Start-Process -FilePath $shellPath -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30'
    ) -WindowStyle Hidden -PassThru
    $ownedProcessStarts = @{}
    if ($null -ne (Get-SmokeOwnedProcess -ProcessId $unrelated.Id)) {
        throw 'An unregistered process was incorrectly accepted.'
    }
    $ownedProcessStarts[$PID] = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    if ($null -eq (Get-SmokeOwnedProcess -ProcessId $child.Id)) {
        throw 'A real launched child was not recognized through its parent chain.'
    }
    # The test runner is only an ancestry witness, never a cleanup target.
    $ownedProcessStarts.Remove($PID)
    if ($ownedProcessStarts.ContainsKey($PID)) { throw 'Unsafe test cleanup registry.' }
    $Port = $heldPort
    & {
        function Get-NetTCPConnection {
            [pscustomobject]@{ LocalAddress = '127.0.0.1'; OwningProcess = $unrelated.Id }
        }
        $rejected = $false
        try { Assert-SmokeListenerOwnership | Out-Null }
        catch { $rejected = $_.Exception.Message -like '*outside the smoke-test process tree*' }
        if (-not $rejected) { throw 'An unrelated listener was incorrectly accepted.' }
    }
    Stop-SmokeOwnedProcesses
    if (-not $child.HasExited) { throw 'Owned child was not cleaned up.' }
    $unrelated.Refresh()
    if ($unrelated.HasExited) { throw 'Cleanup terminated an unrelated same-executable process.' }
}
finally {
    foreach ($launched in @($child, $unrelated)) {
        if ($null -ne $launched -and -not $launched.HasExited) {
            $launched.Kill()
            $launched.WaitForExit()
        }
    }
}
Write-Output 'Windows smoke safety passed: parser, dynamic port, occupied-port zero requests, guarded progress round-trip, ancestry and isolated cleanup.'
