from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def test_windows_version_gate_accepts_the_ci_and_release_toolchain() -> None:
    workflow_versions = {
        version
        for name in ("ci.yml", "release.yml")
        for version in re.findall(
            r"flutter-version:\s*['\"]([^'\"]+)['\"]",
            (REPOSITORY_ROOT / ".github/workflows" / name).read_text(encoding="utf-8"),
        )
    }
    assert len(workflow_versions) == 1, "CI and release jobs must use the same Flutter SDK"
    build_script = (REPOSITORY_ROOT / "tool/build_windows.ps1").read_text(encoding="utf-8")
    required_version = re.search(r'^\$requiredFlutterVersion = "([^"]+)"', build_script, re.MULTILINE)
    assert required_version is not None
    ci_version = workflow_versions.pop()
    assert required_version[1] == ci_version, "Windows packaging rejects the Flutter SDK installed by CI"

    powershell = shutil.which("pwsh") or shutil.which("powershell")
    if powershell is None:
        pytest.skip("PowerShell is required to execute the Windows version gate")
    gate = re.search(r"(?s)function Assert-FlutterVersion \{.*?\n\}", build_script)
    assert gate is not None
    machine_version = json.dumps({"frameworkVersion": ci_version})
    harness = f"""
$ErrorActionPreference = 'Stop'
{required_version[0]}
$AllowFlutterVersionMismatch = $false
function flutter {{
    $global:LASTEXITCODE = 0
    'Running pub upgrade...'
    '{machine_version}'
}}
{gate[0]}
Assert-FlutterVersion
"""
    result = subprocess.run(
        [powershell, "-NoProfile", "-NonInteractive", "-Command", harness],
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
