from __future__ import annotations

import getpass
import os
import shlex
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEPLOY_DIR = REPOSITORY_ROOT / "deploy" / "linux"


@pytest.fixture
def bash() -> str:
    if os.name == "nt":
        git = shutil.which("git")
        candidates = [Path(git).parents[1] / "bin" / "bash.exe"] if git else []
        for candidate in candidates:
            if candidate.is_file():
                return str(candidate)
        pytest.skip("Git Bash is required for deployment fault-injection tests on Windows")
    executable = shutil.which("bash")
    if executable is None:
        pytest.skip("Bash is required for deployment fault-injection tests")
    return executable


@pytest.fixture
def python_runner(tmp_path: Path) -> Path:
    # Execute the production heredocs. The Windows shim supplies only POSIX
    # descriptor-relative paths/ownership; SQLite and file copying remain real.
    path = tmp_path / "run_deployment_python.py"
    path.write_text(
        """import os
import shutil
import sys
import types

source = sys.stdin.read()
sys.argv = sys.argv[1:]
if os.name == "nt":
    directories = {}
    files = {}
    closed_for_replace = set()
    original_open, original_close = os.open, os.close
    original_unlink, original_replace = os.unlink, os.replace

    def resolve(path, descriptor):
        return os.path.join(directories[descriptor], path) if descriptor is not None else path

    def open_file(path, flags, mode=0o777, *, dir_fd=None):
        path = resolve(path, dir_fd)
        if os.path.isdir(path):
            descriptor = 1000000 + len(directories)
            directories[descriptor] = path
            return descriptor
        descriptor = original_open(path, flags | os.O_BINARY, mode)
        files[descriptor] = os.path.normpath(path)
        closed_for_replace.discard(descriptor)
        return descriptor

    def close_file(descriptor):
        if descriptor not in directories and descriptor not in closed_for_replace:
            original_close(descriptor)
        files.pop(descriptor, None)

    def replace_file(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
        src, dst = resolve(src, src_dir_fd), resolve(dst, dst_dir_fd)
        # POSIX permits renaming the still-open destination descriptor. Windows
        # requires releasing that handle; production fchown/fchmod are no-ops here.
        for descriptor, path in files.items():
            if path == os.path.normpath(src):
                original_close(descriptor)
                closed_for_replace.add(descriptor)
        original_replace(src, dst)

    os.open = open_file
    os.close = close_file
    os.unlink = lambda path, *, dir_fd=None: original_unlink(resolve(path, dir_fd))
    os.replace = replace_file
    os.fchmod = lambda *args: None
    os.fchown = lambda *args: None
    pwd = types.ModuleType("pwd")
    pwd.getpwnam = lambda name: types.SimpleNamespace(pw_uid=0, pw_gid=0)
    sys.modules["pwd"] = pwd

failure = int(os.environ.get("FAIL_COPY", "0"))
if failure and "def snapshot(" in source:
    original_copy = shutil.copyfileobj
    copies = 0

    def copy_with_failure(source_stream, target_stream, length):
        global copies
        copies += 1
        if copies == failure:
            target_stream.write(source_stream.read(512))
            target_stream.flush()
            raise OSError("injected I/O failure after partial backup write")
        original_copy(source_stream, target_stream, length)

    shutil.copyfileobj = copy_with_failure

exec(compile(source, "<deployment heredoc>", "exec"), {"__name__": "__main__"})
""",
        encoding="utf-8",
    )
    return path


def _run_update_cutover(
    bash: str, python_runner: Path, tmp_path: Path, *, failed_copy: int = 0, mutate: bool = False
) -> subprocess.CompletedProcess[str]:
    script = (DEPLOY_DIR / "update.sh").read_text(encoding="utf-8")
    definitions = script.split('update_succeeded="false"', 1)[1].split("printf '正在从固定上游", 1)[0]
    cutover = script.split('write_online_state "restarting"', 1)[1].split(
        'install -o root -g root -m 0600 "$next_backend_file"', 1
    )[0]
    variables = {
        "DATA_DIR": tmp_path / "data",
        "rollback_dir": tmp_path / "backup",
        "database_file": tmp_path / "data/qingjuan.db",
        "database_backup": tmp_path / "backup/qingjuan.db",
        "database_wal_backup": tmp_path / "backup/qingjuan.db-wal",
        "SERVICE_NAME": "qingjuan-test",
        "SERVICE_USER": getpass.getuser(),
        "REPO_DIR": tmp_path,
        "old_revision": "old",
        "old_version": "old",
        "updater_path_was_enabled": "false",
        "updater_path_was_active": "false",
        "EVENTS": tmp_path / "events.log",
    }
    setup = "\n".join(
        f"{key}={shlex.quote(str(value).replace(chr(92), '/'))}" for key, value in variables.items()
    )
    mutation = (
        """python3 - "$database_file" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute("UPDATE books SET title = 'new release mutation'")
PY
"""
        if mutate
        else ""
    )
    harness = f'''set -Eeuo pipefail
{setup}
update_succeeded="false"{definitions}
python3() {{ "$TEST_PYTHON" "$TEST_PYTHON_RUNNER" "$@"; }}
systemctl() {{ printf 'systemctl %s\\n' "$*" >> "$EVENTS"; }}
git() {{ printf 'git %s\\n' "$*" >> "$EVENTS"; }}
restore_current_link() {{ printf 'restore current\\n' >> "$EVENTS"; }}
restore_repository_permissions() {{ :; }}
restore_installed_artifacts() {{ :; }}
write_online_state() {{ :; }}
wait_for_health() {{ :; }}
remove_rollback_tree() {{ :; }}
write_online_state "restarting"{cutover}
{mutation}
exit 1
'''
    environment = {
        **os.environ,
        "TEST_PYTHON": Path(sys.executable).as_posix(),
        "TEST_PYTHON_RUNNER": python_runner.as_posix(),
        "FAIL_COPY": str(failed_copy),
        "PYTHONUTF8": "1",
    }
    return subprocess.run(
        [bash, "-s"],
        input=harness,
        text=True,
        encoding="utf-8",
        capture_output=True,
        env=environment,
        check=False,
        timeout=30,
    )


@pytest.mark.parametrize("failed_copy", [1, 2], ids=["partial-database", "partial-wal"])
def test_incomplete_snapshot_never_replaces_live_database(
    bash: str, python_runner: Path, tmp_path: Path, failed_copy: int
) -> None:
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    backup_dir = tmp_path / "backup"
    backup_dir.mkdir()
    database = data_dir / "qingjuan.db"
    # An abruptly stopped writer leaves a real WAL without open OS handles,
    # matching the updater's state after systemd has stopped the backend.
    subprocess.run(
        [
            sys.executable,
            "-c",
            """import os, sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("CREATE TABLE books (title TEXT)")
connection.execute("INSERT INTO books VALUES (?)", ("reader data" * 1000,))
connection.commit()
os._exit(0)
""",
            str(database),
        ],
        check=True,
        timeout=10,
    )
    original = {name: (data_dir / name).read_bytes() for name in ("qingjuan.db", "qingjuan.db-wal")}

    result = _run_update_cutover(bash, python_runner, tmp_path, failed_copy=failed_copy)

    assert result.returncode != 0
    assert "injected I/O failure after partial backup write" in result.stderr
    failed_name = "qingjuan.db" if failed_copy == 1 else "qingjuan.db-wal"
    assert (backup_dir / failed_name).stat().st_size == 512
    for name, contents in original.items():
        assert (data_dir / name).read_bytes() == contents, f"production {name} was changed by rollback"
    events = (tmp_path / "events.log").read_text(encoding="utf-8")
    assert "systemctl start qingjuan-test" in events
    assert "restore current" not in events
    assert "git " not in events


def test_completed_snapshot_restores_database_after_cutover_failure(
    bash: str, python_runner: Path, tmp_path: Path
) -> None:
    (tmp_path / "data").mkdir()
    (tmp_path / "backup").mkdir()
    database = tmp_path / "data/qingjuan.db"
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE books (title TEXT)")
        connection.execute("INSERT INTO books VALUES ('original reader data')")
    connection.close()

    result = _run_update_cutover(bash, python_runner, tmp_path, mutate=True)

    assert result.returncode != 0
    assert "Traceback" not in result.stderr, result.stderr
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT title FROM books").fetchone() == ("original reader data",)
        assert connection.execute("PRAGMA quick_check").fetchone() == ("ok",)
    events = (tmp_path / "events.log").read_text(encoding="utf-8")
    assert "restore current" in events
    assert "systemctl start qingjuan-test" in events


@pytest.mark.parametrize("already_running", ["true", "false"])
def test_installer_applies_new_credentials_to_service(bash: str, already_running: str) -> None:
    script = (DEPLOY_DIR / "install.sh").read_text(encoding="utf-8")
    activation = script.split("systemctl daemon-reload", 1)[1].split("print_initial_admin_password()", 1)[0]
    harness = f"""set -Eeuo pipefail
SERVICE_NAME=qingjuan-test
running={already_running}
loaded_token=old
systemctl() {{
  if [[ "$1" == restart ]] || {{ [[ "$1" == start && "$running" == false ]]; }}; then
    loaded_token=new
    running=true
  fi
}}
{activation}
[[ "$loaded_token" == new ]]
"""
    result = subprocess.run([bash, "-s"], input=harness, text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, "an active service still uses credentials from before reinstall"
