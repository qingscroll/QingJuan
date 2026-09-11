"""Regression coverage for public CA files exposed by directory packaging."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest


def test_only_known_public_ca_files_are_allowed(tmp_path: Path) -> None:
    powershell = shutil.which("pwsh") or shutil.which("powershell")
    if powershell is None:
        pytest.skip("PowerShell is required for Windows package validation")
    script = tmp_path / "check.ps1"
    script.write_text(
        """
param([string]$Helper, [string]$Root)
$ErrorActionPreference = 'Stop'
. $Helper
$certificate = '-----BEGIN CERTIFICATE-----' + "`nPUBLIC`n" + '-----END CERTIFICATE-----'
foreach ($relative in @('backend/_internal/certifi/cacert.pem', 'backend/_internal/curl_cffi/cacert.pem')) {
    $candidate = Join-Path $Root $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $candidate) | Out-Null
    Set-Content -LiteralPath $candidate -Value $certificate
    if (-not (Test-PackagedPublicCertificate -File (Get-Item -LiteralPath $candidate) -ReleaseRoot $Root)) {
        throw 'A bundled public trust store was rejected.'
    }
    Set-Content -LiteralPath $candidate -Value ($certificate + '-----BEGIN PRIVATE KEY-----')
    if (Test-PackagedPublicCertificate -File (Get-Item -LiteralPath $candidate) -ReleaseRoot $Root) {
        throw 'A private key hidden in the CA path was allowed.'
    }
    Set-Content -LiteralPath $candidate -Value 'not a public certificate'
    if (Test-PackagedPublicCertificate -File (Get-Item -LiteralPath $candidate) -ReleaseRoot $Root) {
        throw 'A non-certificate file in the CA path was allowed.'
    }
}
$unknown = Join-Path $Root 'user.pem'
Set-Content -LiteralPath $unknown -Value $certificate
if (Test-PackagedPublicCertificate -File (Get-Item -LiteralPath $unknown) -ReleaseRoot $Root) {
    throw 'An arbitrary user certificate was allowed.'
}
""",
        encoding="utf-8",
    )
    helper = Path(__file__).resolve().parents[2] / "tool/windows_payload_validation.ps1"
    result = subprocess.run(
        [powershell, "-NoProfile", "-NonInteractive", "-File", str(script), "-Helper", str(helper), "-Root", str(tmp_path)],
        text=True, capture_output=True, check=False, timeout=30,
    )
    assert result.returncode == 0, result.stderr
