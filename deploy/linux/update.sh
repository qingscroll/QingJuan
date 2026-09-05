#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly APP_ROOT="/opt/qingjuan"
readonly REPO_DIR="$APP_ROOT/app"
readonly CURRENT_LINK="$APP_ROOT/current"
readonly RELEASES_DIR="$APP_ROOT/releases"
readonly UPDATER_STATE_DIR="/var/lib/qingjuan-updater"
readonly SERVICE_NAME="qingjuan-backend"
readonly SERVICE_USER="qingjuan"
readonly CONFIG_DIR="/etc/qingjuan"
readonly DATA_DIR="/var/lib/qingjuan"
readonly BACKEND_FILE="$CONFIG_DIR/backend.env"
readonly CLIENT_FILE="$CONFIG_DIR/client.env"
readonly SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
readonly UPDATER_SERVICE_UNIT="/etc/systemd/system/qingjuan-updater.service"
readonly UPDATER_PATH_UNIT="/etc/systemd/system/qingjuan-updater.path"
readonly INFO_COMMAND="/usr/local/sbin/qingjuan-info"
readonly PASSWORD_COMMAND="/usr/local/sbin/qingjuan-password"
readonly UNINSTALL_COMMAND="/usr/local/sbin/qingjuan-uninstall"
readonly UPDATE_RUNNER_COMMAND="/usr/local/sbin/qingjuan-update-runner"
readonly UPDATE_REQUEST_FILE="/run/qingjuan/update-request.json"
readonly UPDATE_STATUS_FILE="$DATA_DIR/backend-update.json"
readonly MAINTENANCE_LOCK="/run/lock/qingjuan-maintenance.lock"
readonly TRUSTED_UPSTREAM_REF="refs/qingjuan-updater/upstream"

online_mode="false"
expected_revision=""

usage() {
  cat <<'EOF'
用法：sudo bash deploy/linux/update.sh

从当前分支配置的固定上游构建独立 release，并通过 /opt/qingjuan/current 原子切换。
下载、依赖安装和预检期间服务保持在线，仅在最终切换时短暂重启。
--online 与 --expected-revision 仅供受控升级器使用。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --online)
      online_mode="true"
      shift
      ;;
    --expected-revision)
      if [[ $# -lt 2 ]]; then
        printf '%s 缺少参数值。\n' "$1" >&2
        exit 2
      fi
      expected_revision="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '未知参数：%s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  printf '更新脚本必须使用 sudo 或 root 运行。\n' >&2
  exit 1
fi
if [[ "$online_mode" != "true" && -n "$expected_revision" ]]; then
  printf '%s\n' '--expected-revision 仅供在线升级服务使用。' >&2
  exit 2
fi
if [[ -n "$expected_revision" && ! "$expected_revision" =~ ^[0-9a-f]{40,64}$ ]]; then
  printf '候选版本标识无效。\n' >&2
  exit 2
fi
for command_name in curl flock git python3 runuser systemctl tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf '缺少系统命令：%s\n' "$command_name" >&2
    exit 1
  fi
done
if [[ ! -d "$REPO_DIR/.git" ]]; then
  printf '未找到 %s/.git，无法从远端更新。\n' "$REPO_DIR" >&2
  exit 1
fi
if [[ ! -f "$BACKEND_FILE" ]]; then
  printf '现有后端安装不完整，请先运行 deploy/linux/install.sh。\n' >&2
  exit 1
fi
if [[ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ]]; then
  printf '服务器仓库存在已跟踪的未提交改动，已拒绝覆盖。\n' >&2
  exit 1
fi
if [[ -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
  printf '%s 必须是由安装器管理的符号链接。\n' "$CURRENT_LINK" >&2
  exit 1
fi

exec 9>"$MAINTENANCE_LOCK"
if ! flock -n 9; then
  printf '已有安装、更新或维护任务正在运行。\n' >&2
  exit 1
fi

if [[ -L "$UPDATER_STATE_DIR" ]] || { [[ -e "$UPDATER_STATE_DIR" ]] && [[ ! -d "$UPDATER_STATE_DIR" ]]; }; then
  printf '升级器状态目录类型不安全：%s\n' "$UPDATER_STATE_DIR" >&2
  exit 1
fi
install -d -o root -g root -m 0700 "$UPDATER_STATE_DIR"
install -d -o root -g "$SERVICE_USER" -m 0750 "$RELEASES_DIR"

old_revision="$(git -C "$REPO_DIR" rev-parse HEAD)"
old_version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$REPO_DIR/pubspec.yaml" | head -n 1)"
old_pid="$(systemctl show "$SERVICE_NAME" --property MainPID --value 2>/dev/null || printf '0')"
updater_path_was_enabled="false"
updater_path_was_active="false"
if systemctl is-enabled --quiet qingjuan-updater.path 2>/dev/null; then
  updater_path_was_enabled="true"
fi
if systemctl is-active --quiet qingjuan-updater.path 2>/dev/null; then
  updater_path_was_active="true"
fi
rollback_dir="$(mktemp -d "$UPDATER_STATE_DIR/rollback.XXXXXX")"
artifact_backup_dir="$rollback_dir/artifacts"
database_file="$DATA_DIR/qingjuan.db"
database_backup="$rollback_dir/qingjuan.db"
database_wal_backup="$rollback_dir/qingjuan.db-wal"
next_backend_file="$rollback_dir/backend.env.next"
install -d -o root -g root -m 0700 "$artifact_backup_dir"

previous_current_present="false"
previous_current_target=""
if [[ -L "$CURRENT_LINK" ]]; then
  previous_current_present="true"
  previous_current_target="$(readlink -- "$CURRENT_LINK")"
fi

backup_artifact() {
  local source="$1"
  local name="$2"
  if [[ -e "$source" || -L "$source" ]]; then
    cp -a -- "$source" "$artifact_backup_dir/$name"
    : > "$artifact_backup_dir/$name.present"
  fi
}

restore_artifact() {
  local target="$1"
  local name="$2"
  rm -f -- "$target" || return 1
  if [[ -f "$artifact_backup_dir/$name.present" ]]; then
    cp -a -- "$artifact_backup_dir/$name" "$target" || return 1
  fi
}

backup_artifact "$BACKEND_FILE" "backend.env"
backup_artifact "$SERVICE_UNIT" "qingjuan-backend.service"
backup_artifact "$UPDATER_SERVICE_UNIT" "qingjuan-updater.service"
backup_artifact "$UPDATER_PATH_UNIT" "qingjuan-updater.path"
backup_artifact "$INFO_COMMAND" "qingjuan-info"
backup_artifact "$PASSWORD_COMMAND" "qingjuan-password"
backup_artifact "$UNINSTALL_COMMAND" "qingjuan-uninstall"
backup_artifact "$UPDATE_RUNNER_COMMAND" "qingjuan-update-runner"

update_succeeded="false"
service_stop_requested="false"
database_backup_ready="false"
cutover_started="false"
release_created="false"
release_ready="false"
target_revision=""
target_version=""
target_release=""
initial_admin_password=""

remove_rollback_tree() {
  case "$rollback_dir" in
    "$UPDATER_STATE_DIR"/rollback.*) rm -rf -- "$rollback_dir" ;;
    *)
      printf '拒绝删除未授权回滚目录：%s\n' "$rollback_dir" >&2
      return 1
      ;;
  esac
}

remove_created_release() {
  if [[ "$release_created" != "true" || -z "$target_revision" ]]; then
    return
  fi
  case "$target_release" in
    "$RELEASES_DIR"/"$target_revision") rm -rf -- "$target_release" ;;
    *)
      printf '拒绝删除未授权 release：%s\n' "$target_release" >&2
      return 1
      ;;
  esac
}

restore_repository_permissions() {
  chown -R root:"$SERVICE_USER" "$REPO_DIR"
  chmod -R u=rwX,g=rX,o= "$REPO_DIR"
}

write_online_state() {
  local state="$1"
  local message="$2"
  local error_code="${3:-}"
  if [[ "$online_mode" != "true" || -z "${QINGJUAN_ONLINE_UPDATE_JOB_ID:-}" ]]; then
    return
  fi
  python3 - "$UPDATE_STATUS_FILE" "$state" "$message" "$error_code" "$QINGJUAN_ONLINE_UPDATE_JOB_ID" <<'PY'
import datetime
import json
import os
import stat
import sys
import tempfile

path, state, message, error_code, expected_job = sys.argv[1:]
descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 65536:
        raise SystemExit("invalid update status")
    with os.fdopen(descriptor, encoding="utf-8") as stream:
        descriptor = -1
        payload = json.load(stream)
finally:
    if descriptor >= 0:
        os.close(descriptor)
if payload.get("jobId") != expected_job:
    raise SystemExit("update status belongs to another job")
payload["state"] = state
payload["message"] = message
payload["canUpdate"] = False
payload["error"] = error_code or None
now = datetime.datetime.now(datetime.UTC).isoformat().replace("+00:00", "Z")
if state == "verifying":
    payload["startedAt"] = payload.get("startedAt") or now
if state == "failed":
    payload["finishedAt"] = now
directory = os.path.dirname(path)
descriptor, temporary = tempfile.mkstemp(prefix=".backend-update.", suffix=".tmp", dir=directory)
try:
    os.fchown(descriptor, metadata.st_uid, metadata.st_gid)
    os.fchmod(descriptor, 0o640)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

wait_for_health() {
  local expected_version="$1"
  local expected_revision="$2"
  local require_new_pid="$3"
  local bind_host port health_host health_url payload current_pid
  bind_host="$(sed -n 's/^QINGJUAN_BIND_HOST=//p' "$BACKEND_FILE" | tail -n 1)"
  port="$(sed -n 's/^QINGJUAN_PORT=//p' "$BACKEND_FILE" | tail -n 1)"
  case "$bind_host" in
    ""|"0.0.0.0"|"127.0.0.1"|"localhost") health_host="127.0.0.1" ;;
    "::"|"[::]"|"::0") health_host="[::1]" ;;
    *:* )
      health_host="${bind_host#\[}"
      health_host="${health_host%\]}"
      health_host="[${health_host}]"
      ;;
    *) health_host="$bind_host" ;;
  esac
  health_url="http://${health_host}:${port}/healthz"
  local stable_checks=0
  for _ in $(seq 1 90); do
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      payload="$(curl --noproxy '*' --fail --silent --max-time 2 "$health_url" 2>/dev/null || true)"
      if python3 - "$expected_version" "$expected_revision" "$payload" <<'PY'
import json
import sys

expected_version, expected_revision, raw = sys.argv[1:]
try:
    payload = json.loads(raw)
except (TypeError, ValueError):
    raise SystemExit(1)
if payload.get("status") != "ok":
    raise SystemExit(1)
if expected_revision:
    if payload.get("service") != "qingjuan-backend":
        raise SystemExit(1)
    if expected_version and payload.get("appVersion") != expected_version:
        raise SystemExit(1)
    if payload.get("revision") != expected_revision:
        raise SystemExit(1)
else:
    if payload.get("service") not in {None, "qingjuan-backend"}:
        raise SystemExit(1)
    if expected_version and payload.get("appVersion") not in {None, expected_version}:
        raise SystemExit(1)
PY
      then
        stable_checks=$((stable_checks + 1))
        if (( stable_checks >= 3 )); then
          current_pid="$(systemctl show "$SERVICE_NAME" --property MainPID --value)"
          if [[ "$current_pid" =~ ^[1-9][0-9]*$ ]]; then
            if [[ "$require_new_pid" != "true" ]] || \
               [[ ! "$old_pid" =~ ^[1-9][0-9]*$ ]] || [[ "$current_pid" != "$old_pid" ]]; then
              return 0
            fi
          fi
        fi
      else
        stable_checks=0
      fi
    else
      stable_checks=0
    fi
    sleep 1
  done
  return 1
}

switch_current_link() {
  local destination="$1"
  local temporary_link="$APP_ROOT/.current.$$.new"
  rm -f -- "$temporary_link" || return 1
  ln -s -- "$destination" "$temporary_link" || return 1
  mv -Tf -- "$temporary_link" "$CURRENT_LINK"
}

restore_current_link() {
  if [[ "$previous_current_present" == "true" ]]; then
    switch_current_link "$previous_current_target"
  else
    if [[ -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
      printf '拒绝覆盖非符号链接：%s\n' "$CURRENT_LINK" >&2
      return 1
    fi
    rm -f -- "$CURRENT_LINK" || return 1
  fi
}

restore_database() {
  if [[ "$database_backup_ready" != "true" ]]; then
    printf '数据库备份尚未完成验证，拒绝覆盖现有数据库。\n' >&2
    return 1
  fi
  if [[ ! -f "$database_backup" ]]; then
    return
  fi
  python3 - "$DATA_DIR" "$database_backup" "$database_wal_backup" "$SERVICE_USER" <<'PY'
import os
import pwd
import shutil
import stat
import sys

data_dir, database_backup, wal_backup, service_user = sys.argv[1:]
user = pwd.getpwnam(service_user)
directory_descriptor = os.open(
    data_dir,
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
)


def unlink(name: str) -> None:
    try:
        os.unlink(name, dir_fd=directory_descriptor)
    except FileNotFoundError:
        pass


def restore(source: str, name: str) -> bool:
    if not os.path.isfile(source):
        return False
    source_descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    temporary_name = f".{name}.restore.{os.getpid()}"
    try:
        metadata = os.fstat(source_descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise SystemExit("invalid database backup")
        unlink(temporary_name)
        target_descriptor = os.open(
            temporary_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=directory_descriptor,
        )
        try:
            with os.fdopen(source_descriptor, "rb", closefd=False) as source_stream:
                with os.fdopen(target_descriptor, "wb", closefd=False) as target_stream:
                    shutil.copyfileobj(source_stream, target_stream, length=1024 * 1024)
                    target_stream.flush()
                    os.fsync(target_descriptor)
            os.replace(
                temporary_name,
                name,
                src_dir_fd=directory_descriptor,
                dst_dir_fd=directory_descriptor,
            )
            os.fchown(target_descriptor, user.pw_uid, user.pw_gid)
            os.fchmod(target_descriptor, 0o600)
        finally:
            os.close(target_descriptor)
        return True
    finally:
        os.close(source_descriptor)
        unlink(temporary_name)


if not restore(database_backup, "qingjuan.db"):
    raise SystemExit("database backup is missing")
if not restore(wal_backup, "qingjuan.db-wal"):
    unlink("qingjuan.db-wal")
unlink("qingjuan.db-shm")
os.close(directory_descriptor)
PY
}

restore_installed_artifacts() {
  local restore_ok="true"
  restore_artifact "$BACKEND_FILE" "backend.env" || restore_ok="false"
  restore_artifact "$SERVICE_UNIT" "qingjuan-backend.service" || restore_ok="false"
  restore_artifact "$UPDATER_SERVICE_UNIT" "qingjuan-updater.service" || restore_ok="false"
  restore_artifact "$UPDATER_PATH_UNIT" "qingjuan-updater.path" || restore_ok="false"
  restore_artifact "$INFO_COMMAND" "qingjuan-info" || restore_ok="false"
  restore_artifact "$PASSWORD_COMMAND" "qingjuan-password" || restore_ok="false"
  restore_artifact "$UNINSTALL_COMMAND" "qingjuan-uninstall" || restore_ok="false"
  restore_artifact "$UPDATE_RUNNER_COMMAND" "qingjuan-update-runner" || restore_ok="false"
  [[ "$restore_ok" == "true" ]]
}

rollback_update() {
  local exit_code=$?
  trap - EXIT
  if [[ "$update_succeeded" == "true" ]]; then
    return "$exit_code"
  fi

  set +e
  local rollback_ok="true"
  printf '更新未完成，正在恢复升级前版本。\n' >&2

  if [[ "$cutover_started" == "true" ]]; then
    if ! systemctl stop "$SERVICE_NAME" >/dev/null 2>&1; then
      printf '回滚步骤失败：停止新服务。\n' >&2
      rollback_ok="false"
    fi
    if ! restore_current_link; then
      printf '回滚步骤失败：恢复 current 指针。\n' >&2
      rollback_ok="false"
    fi
    if ! git -C "$REPO_DIR" reset --hard "$old_revision" >/dev/null 2>&1; then
      printf '回滚步骤失败：恢复管理仓库。\n' >&2
      rollback_ok="false"
    elif ! restore_repository_permissions; then
      printf '回滚步骤失败：恢复管理仓库权限。\n' >&2
      rollback_ok="false"
    fi
    if ! restore_installed_artifacts; then
      printf '回滚步骤失败：恢复配置、unit 或管理命令。\n' >&2
      rollback_ok="false"
    fi
    if ! restore_database; then
      printf '回滚步骤失败：恢复数据库。\n' >&2
      rollback_ok="false"
    fi
    if ! systemctl daemon-reload; then
      printf '回滚步骤失败：重新加载 systemd。\n' >&2
      rollback_ok="false"
    fi
    if [[ "$updater_path_was_enabled" == "true" ]]; then
      if ! systemctl enable qingjuan-updater.path >/dev/null 2>&1; then
        printf '回滚步骤失败：恢复升级 path 的启用状态。\n' >&2
        rollback_ok="false"
      fi
    else
      systemctl disable qingjuan-updater.path >/dev/null 2>&1 || true
    fi
    if [[ "$updater_path_was_active" == "true" ]]; then
      if ! systemctl start qingjuan-updater.path >/dev/null 2>&1; then
        printf '回滚步骤失败：恢复升级 path 的运行状态。\n' >&2
        rollback_ok="false"
      fi
    else
      systemctl stop qingjuan-updater.path >/dev/null 2>&1 || true
    fi
  fi

  if [[ "$service_stop_requested" == "true" ]]; then
    if ! systemctl start "$SERVICE_NAME"; then
      printf '回滚步骤失败：启动旧服务。\n' >&2
      rollback_ok="false"
    elif ! wait_for_health "$old_version" "" "false"; then
      printf '回滚步骤失败：旧服务未通过健康检查。\n' >&2
      rollback_ok="false"
    fi
  elif ! wait_for_health "$old_version" "" "false"; then
    printf '准备失败后，原服务健康检查异常。\n' >&2
    rollback_ok="false"
  fi

  if [[ "$release_created" == "true" && "$release_ready" != "true" ]]; then
    if ! remove_created_release; then
      rollback_ok="false"
    fi
  fi

  if [[ "$rollback_ok" == "true" ]]; then
    write_online_state "failed" "后端升级失败，已验证恢复升级前版本" "UPDATE_ROLLED_BACK" || true
    if ! remove_rollback_tree; then
      rollback_ok="false"
    fi
  fi

  if [[ "$rollback_ok" != "true" ]]; then
    write_online_state "failed" "后端升级及自动回滚均未完整成功；回滚资料已保留在 $rollback_dir" "ROLLBACK_FAILED" || true
    printf '自动回滚未完整成功；请保留并检查 %s。\n' "$rollback_dir" >&2
  fi

  set -e
  if (( exit_code == 0 )); then
    return 1
  fi
  return "$exit_code"
}
trap rollback_update EXIT

printf '正在从固定上游获取候选版本；准备阶段服务保持在线。\n'
current_branch="$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD)"
remote_name="$(git -C "$REPO_DIR" config --get "branch.${current_branch}.remote")"
merge_ref="$(git -C "$REPO_DIR" config --get "branch.${current_branch}.merge")"
if [[ -z "$remote_name" || "$remote_name" == "." || ! "$merge_ref" =~ ^refs/heads/.+ ]] || \
   ! git check-ref-format "$merge_ref" >/dev/null 2>&1; then
  printf '当前分支没有可供受控升级使用的固定远端上游。\n' >&2
  exit 1
fi
git -C "$REPO_DIR" remote get-url "$remote_name" >/dev/null
(umask 022; git -C "$REPO_DIR" fetch --no-tags "$remote_name" "+${merge_ref}:${TRUSTED_UPSTREAM_REF}")
fetched_revision="$(git -C "$REPO_DIR" rev-parse "${TRUSTED_UPSTREAM_REF}^{commit}")"
if [[ ! "$fetched_revision" =~ ^[0-9a-f]{40,64}$ ]]; then
  printf '固定上游返回了无效候选版本。\n' >&2
  exit 1
fi
if [[ -n "$expected_revision" && "$expected_revision" != "$fetched_revision" ]]; then
  printf '上游版本已变化，请回到管理界面重新检查更新。\n' >&2
  exit 1
fi
target_revision="$fetched_revision"
if ! git -C "$REPO_DIR" merge-base --is-ancestor "$old_revision" "$target_revision"; then
  printf '候选版本不能从当前版本快进更新。\n' >&2
  exit 1
fi

target_release="$RELEASES_DIR/$target_revision"
if [[ -e "$target_release" || -L "$target_release" ]]; then
  if [[ -L "$target_release" || ! -d "$target_release" ]] || \
     [[ "$(cat "$target_release/REVISION" 2>/dev/null || true)" != "$target_revision" ]] || \
     [[ ! -x "$target_release/venv/bin/python" ]] || \
     [[ ! -f "$target_release/app/python-backend/app/main.py" ]]; then
    printf '已存在的目标 release 不完整或不可信：%s\n' "$target_release" >&2
    exit 1
  fi
else
  install -d -o root -g root -m 0700 "$target_release"
  release_created="true"
  install -d -o root -g root -m 0700 "$target_release/app"
  git -C "$REPO_DIR" archive --format=tar "$target_revision" | tar -xf - -C "$target_release/app"
  printf '%s\n' "$target_revision" > "$target_release/REVISION"

  target_version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$target_release/app/pubspec.yaml" | head -n 1)"
  if [[ -z "$target_version" ]]; then
    printf '无法读取目标版本号。\n' >&2
    exit 1
  fi
  admin_static_dir="$target_release/app/python-backend/app/admin_static"
  if [[ ! -f "$admin_static_dir/index.html" ]] || \
     ! grep -Fq 'id="root"' "$admin_static_dir/index.html" || \
     ! compgen -G "$admin_static_dir/assets/*.js" >/dev/null; then
    printf '更新版本缺少已构建的管理界面。\n' >&2
    exit 1
  fi

  python3 -m venv "$target_release/venv"
  "$target_release/venv/bin/python" -m pip install --upgrade pip
  "$target_release/venv/bin/python" -m pip install -r "$target_release/app/python-backend/requirements.txt"
  "$target_release/venv/bin/python" -m pip check
  chown -R root:"$SERVICE_USER" "$target_release"
  chmod -R u=rwX,g=rX,o= "$target_release"
  runuser -u "$SERVICE_USER" -- env PYTHONPATH="$target_release/app/python-backend" \
    "$target_release/venv/bin/python" -c 'from app.application import APP_VERSION; print(APP_VERSION)'
  release_ready="true"
fi

if [[ -z "$target_version" ]]; then
  target_version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$target_release/app/pubspec.yaml" | head -n 1)"
fi
if [[ -z "$target_version" ]]; then
  printf '无法读取目标 release 版本号。\n' >&2
  exit 1
fi

cp -a -- "$BACKEND_FILE" "$next_backend_file"
admin_password_hash="$(sed -n 's/^QINGJUAN_ADMIN_PASSWORD_HASH=//p' "$next_backend_file" | tail -n 1)"
if [[ -z "$admin_password_hash" ]]; then
  initial_admin_password="$(
    PYTHONPATH="$target_release/app/python-backend" "$target_release/venv/bin/python" \
      -c 'from app.admin_auth import generate_admin_password; print(generate_admin_password())'
  )"
  printf '%s' "$initial_admin_password" | PYTHONPATH="$target_release/app/python-backend" \
    "$target_release/venv/bin/python" -m app.admin_password "$next_backend_file"
else
  PYTHONPATH="$target_release/app/python-backend" "$target_release/venv/bin/python" \
    -m app.admin_password --ensure-session-secret "$next_backend_file"
fi

set_backend_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$next_backend_file"; then
    sed -i "s|^${key}=.*$|${key}=${value}|" "$next_backend_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$next_backend_file"
  fi
}

set_backend_value "QINGJUAN_CONNECTION_TOKEN_FILE" "$CLIENT_FILE"
set_backend_value "QINGJUAN_MULTI_USER" "1"
set_backend_value "QINGJUAN_UPDATE_REQUEST_FILE" "$UPDATE_REQUEST_FILE"
set_backend_value "QINGJUAN_UPDATE_STATUS_FILE" "$UPDATE_STATUS_FILE"
two_factor_encryption_key="$(sed -n 's/^QINGJUAN_2FA_ENCRYPTION_KEY=//p' "$next_backend_file" | tail -n 1)"
if [[ -n "$two_factor_encryption_key" && ! "$two_factor_encryption_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
  printf '现有 QINGJUAN_2FA_ENCRYPTION_KEY 格式无效；为避免破坏已有二次验证数据，更新已中止。\n' >&2
  exit 1
fi
if [[ -z "$two_factor_encryption_key" ]]; then
  two_factor_encryption_key="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
fi
set_backend_value "QINGJUAN_2FA_ENCRYPTION_KEY" "$two_factor_encryption_key"
chmod 0600 "$next_backend_file"
chown root:root "$next_backend_file"

release_files=(
  deploy/linux/qingjuan-backend.service
  deploy/linux/qingjuan-updater.service
  deploy/linux/qingjuan-updater.path
  deploy/linux/qingjuan-update-runner.sh
  deploy/linux/qingjuan-info.sh
  deploy/linux/qingjuan-password.sh
  deploy/linux/uninstall.sh
)
for release_file in "${release_files[@]}"; do
  if [[ ! -f "$target_release/app/$release_file" ]]; then
    printf '目标 release 缺少部署文件：%s\n' "$release_file" >&2
    exit 1
  fi
done

write_online_state "restarting" "新 release 准备完成，后端正在短暂重启"
service_stop_requested="true"
systemctl stop "$SERVICE_NAME"

if [[ -e "$database_file" || -L "$database_file" ]]; then
  python3 - "$DATA_DIR" "$rollback_dir" "$SERVICE_USER" <<'PY'
import os
import pwd
import shutil
import sqlite3
import stat
import sys

data_dir, backup_dir, service_user = sys.argv[1:]
expected_uid = pwd.getpwnam(service_user).pw_uid
directory_descriptor = os.open(
    data_dir,
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
)


def snapshot(name: str, *, required: bool) -> None:
    try:
        source_descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_descriptor,
        )
    except FileNotFoundError:
        if required:
            raise
        return
    try:
        metadata = os.fstat(source_descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != expected_uid
            or metadata.st_nlink != 1
        ):
            raise SystemExit("database file ownership or type is unsafe")
        destination = os.path.join(backup_dir, name)
        target_descriptor = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        try:
            os.fchmod(target_descriptor, 0o600)
            with os.fdopen(source_descriptor, "rb", closefd=False) as source_stream:
                with os.fdopen(target_descriptor, "wb", closefd=False) as target_stream:
                    shutil.copyfileobj(source_stream, target_stream, length=1024 * 1024)
                    target_stream.flush()
                    os.fsync(target_descriptor)
        finally:
            os.close(target_descriptor)
    finally:
        os.close(source_descriptor)


snapshot("qingjuan.db", required=True)
snapshot("qingjuan.db-wal", required=False)
os.close(directory_descriptor)
database_backup = os.path.join(backup_dir, "qingjuan.db")
with sqlite3.connect(f"file:{database_backup}?mode=ro", uri=True) as connection:
    result = connection.execute("PRAGMA quick_check").fetchone()
if result is None or result[0] != "ok":
    raise SystemExit("database backup failed integrity check")
try:
    os.unlink(f"{database_backup}-shm")
except FileNotFoundError:
    pass
PY
fi

# A failed copy can leave a partial database or WAL in rollback_dir. Until the
# complete snapshot passes quick_check, rollback must only restart the old service.
database_backup_ready="true"
cutover_started="true"
install -o root -g root -m 0600 "$next_backend_file" "$BACKEND_FILE"
if [[ -f "$CLIENT_FILE" ]]; then
  chmod 0640 "$CLIENT_FILE"
  chown root:"$SERVICE_USER" "$CLIENT_FILE"
fi
install -o root -g root -m 0644 "$target_release/app/deploy/linux/qingjuan-backend.service" "$SERVICE_UNIT"
install -o root -g root -m 0644 "$target_release/app/deploy/linux/qingjuan-updater.service" "$UPDATER_SERVICE_UNIT"
install -o root -g root -m 0644 "$target_release/app/deploy/linux/qingjuan-updater.path" "$UPDATER_PATH_UNIT"
install -o root -g root -m 0755 "$target_release/app/deploy/linux/qingjuan-update-runner.sh" "$UPDATE_RUNNER_COMMAND"
install -o root -g root -m 0755 "$target_release/app/deploy/linux/qingjuan-info.sh" "$INFO_COMMAND"
install -o root -g root -m 0755 "$target_release/app/deploy/linux/qingjuan-password.sh" "$PASSWORD_COMMAND"
install -o root -g root -m 0755 "$target_release/app/deploy/linux/uninstall.sh" "$UNINSTALL_COMMAND"
switch_current_link "$target_release"

systemctl daemon-reload
systemctl start "$SERVICE_NAME"
write_online_state "verifying" "后端已从新 release 启动，正在验证提交与健康状态"

if ! wait_for_health "$target_version" "$target_revision" "true"; then
  printf '更新后端未在 90 秒内通过提交级健康检查。\n' >&2
  journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
  exit 1
fi

git -C "$REPO_DIR" reset --hard "$target_revision"
restore_repository_permissions
systemctl enable qingjuan-updater.path >/dev/null
systemctl start qingjuan-updater.path

remove_rollback_tree
update_succeeded="true"
trap - EXIT

if [[ "$online_mode" != "true" ]]; then
  rm -f -- "$UPDATE_STATUS_FILE"
  "$INFO_COMMAND"
  if [[ -n "$initial_admin_password" ]]; then
    printf '%s\n' '============================================================' \
      '已为管理界面生成首次登录密码（仅显示这一次）' \
      "管理密码：${initial_admin_password}" \
      '请妥善保存；遗失时运行 sudo qingjuan-password --generate。' \
      '============================================================'
  fi
fi
printf '青卷后端已更新到 %s（%s）。\n' "$target_version" "${target_revision:0:12}"
