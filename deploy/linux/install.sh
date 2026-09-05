#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly APP_ROOT="/opt/qingjuan"
readonly REPO_DIR="$APP_ROOT/app"
readonly VENV_DIR="$APP_ROOT/venv"
readonly CURRENT_LINK="$APP_ROOT/current"
readonly RELEASES_DIR="$APP_ROOT/releases"
readonly LEGACY_RELEASE_DIR="$RELEASES_DIR/legacy"
readonly UPDATER_STATE_DIR="/var/lib/qingjuan-updater"
readonly CONFIG_DIR="/etc/qingjuan"
readonly DATA_DIR="/var/lib/qingjuan"
readonly SERVICE_NAME="qingjuan-backend"
readonly SERVICE_USER="qingjuan"
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

public_url=""
bind_host="127.0.0.1"
bind_explicit="false"
port="19453"
rotate_token="false"
install_packages="true"

usage() {
  cat <<'EOF'
用法：sudo bash deploy/linux/install.sh [选项]

默认自动检测服务器私有 IPv4，并生成 Windows 客户端连接地址。

选项：
  --url URL           手动指定 FastAPI 根地址，不含 /api/v1
  --bind HOST         手动指定监听地址
  --port PORT         监听端口，默认 19453
  --rotate-token      重新生成连接 Token
  --skip-packages     不使用 apt 安装系统依赖
  -h, --help          显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      if [[ $# -lt 2 ]]; then
        printf '%s 缺少参数值。\n' "$1" >&2
        exit 2
      fi
      public_url="${2:-}"
      shift 2
      ;;
    --bind)
      if [[ $# -lt 2 ]]; then
        printf '%s 缺少参数值。\n' "$1" >&2
        exit 2
      fi
      bind_host="${2:-}"
      bind_explicit="true"
      shift 2
      ;;
    --port)
      if [[ $# -lt 2 ]]; then
        printf '%s 缺少参数值。\n' "$1" >&2
        exit 2
      fi
      port="${2:-}"
      shift 2
      ;;
    --rotate-token)
      rotate_token="true"
      shift
      ;;
    --skip-packages)
      install_packages="false"
      shift
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
  printf '安装脚本必须使用 sudo 或 root 运行。\n' >&2
  exit 1
fi
if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
  printf '端口必须是 1 到 65535 之间的整数。\n' >&2
  exit 2
fi
if [[ ! -f "$REPO_DIR/python-backend/app/main.py" ]]; then
  printf '未找到 %s，请先将仓库克隆到 /opt/qingjuan/app。\n' "$REPO_DIR" >&2
  exit 1
fi
admin_static_dir="$REPO_DIR/python-backend/app/admin_static"
if [[ ! -f "$admin_static_dir/index.html" ]] || \
   ! grep -Fq 'id="root"' "$admin_static_dir/index.html" || \
   ! compgen -G "$admin_static_dir/assets/*.js" >/dev/null; then
  printf '未找到已构建的管理界面，请获取完整的青卷发布版本后重试。\n' >&2
  exit 1
fi

install_system_packages() {
  if [[ "$install_packages" != "true" ]]; then
    return
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    printf '当前系统没有 apt-get；请手动安装 Python 3.11+、venv、Git、curl、Chromium 与 Noto CJK 字体。\n' >&2
    return
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl fonts-noto-cjk git python3 python3-venv util-linux
  if ! command -v chromium >/dev/null 2>&1 && \
     ! command -v chromium-browser >/dev/null 2>&1 && \
     ! command -v google-chrome >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y chromium
  fi
}

find_browser() {
  local candidate
  for candidate in chromium chromium-browser google-chrome; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

detect_private_ipv4() {
  python3 - <<'PY'
import ipaddress
import shutil
import socket
import subprocess

private_networks = tuple(
    ipaddress.ip_network(value)
    for value in (
        "10.0.0.0/8",
        "100.64.0.0/10",
        "172.16.0.0/12",
        "192.168.0.0/16",
    )
)
candidates = []

if shutil.which("tailscale"):
    try:
        candidates.extend(
            subprocess.check_output(
                ["tailscale", "ip", "-4"],
                text=True,
                stderr=subprocess.DEVNULL,
            ).split()
        )
    except (OSError, subprocess.CalledProcessError):
        pass

try:
    candidates.extend(
        subprocess.check_output(
            ["hostname", "-I"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).split()
    )
except (OSError, subprocess.CalledProcessError):
    pass

try:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        connection.connect(("1.1.1.1", 80))
        candidates.append(connection.getsockname()[0])
except OSError:
    pass

for value in candidates:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        continue
    if address.version == 4 and any(address in network for network in private_networks):
        print(address)
        raise SystemExit(0)

raise SystemExit(1)
PY
}

install_system_packages

for command_name in python3 git curl flock runuser systemctl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf '缺少系统命令：%s\n' "$command_name" >&2
    exit 1
  fi
done

exec 9>"$MAINTENANCE_LOCK"
if ! flock -n 9; then
  printf '已有安装、更新或维护任务正在运行。\n' >&2
  exit 1
fi

python3 - <<'PY'
import sys
if sys.version_info < (3, 11):
    raise SystemExit("青卷 Linux 后端要求 Python 3.11 或更高版本")
PY

if [[ -z "$public_url" ]]; then
  detected_ip="$(detect_private_ipv4 || true)"
  if [[ -z "$detected_ip" ]]; then
    printf '%s\n' \
      '未检测到可供客户端访问的私有 IPv4。' \
      '请先加入局域网、Tailscale 或 WireGuard，或使用 --url https://域名。' >&2
    exit 1
  fi
  public_url="http://${detected_ip}:${port}"
  if [[ "$bind_explicit" != "true" ]]; then
    bind_host="0.0.0.0"
  fi
  printf '已自动检测服务器地址：%s\n' "$public_url"
fi

python3 - "$public_url" "$bind_host" <<'PY'
import ipaddress
import socket
import sys
from urllib.parse import urlsplit

public_url, bind_host = sys.argv[1:]
if any(character.isspace() or not character.isprintable() for character in public_url):
    raise SystemExit("--url 不得包含空白或控制字符")
parsed = urlsplit(public_url)
if parsed.scheme not in {"http", "https"} or not parsed.hostname:
    raise SystemExit("--url 必须是有效的 http/https FastAPI 根地址")
if parsed.username or parsed.password or parsed.query or parsed.fragment:
    raise SystemExit("--url 不得包含账号、密码、查询参数或片段")
if public_url.rstrip("/").endswith("/api/v1"):
    raise SystemExit("--url 不得包含 /api/v1")
try:
    parsed.port
except ValueError as error:
    raise SystemExit("--url 端口无效") from error

private_networks = tuple(
    ipaddress.ip_network(value)
    for value in (
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "::1/128",
        "fc00::/7",
        "fe80::/10",
    )
)
if parsed.scheme == "http":
    try:
        addresses = {ipaddress.ip_address(parsed.hostname)}
    except ValueError:
        try:
            addresses = {
                ipaddress.ip_address(item[4][0])
                for item in socket.getaddrinfo(parsed.hostname, parsed.port or 80)
            }
        except socket.gaierror as error:
            raise SystemExit("HTTP 客户端地址无法解析；请使用私有 IP 或配置 HTTPS") from error
    if not addresses or any(
        not any(address in network for network in private_networks)
        for address in addresses
    ):
        raise SystemExit("HTTP 只允许私有网络地址；公网地址必须使用 HTTPS 反向代理")
if not bind_host.strip() or any(character.isspace() for character in bind_host):
    raise SystemExit("--bind 不能为空或包含空白字符")
try:
    ipaddress.ip_address(bind_host.strip("[]"))
except ValueError:
    if bind_host != "localhost":
        raise SystemExit("--bind 必须是 IP 地址或 localhost")
PY

browser_path="$(find_browser || true)"
if [[ -z "$browser_path" ]]; then
  printf '未找到 Chromium/Chrome，请安装后重试。\n' >&2
  exit 1
fi

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DATA_DIR" --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi
install -d -o root -g root -m 0755 "$APP_ROOT"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA_DIR"
install -d -o root -g "$SERVICE_USER" -m 0750 "$CONFIG_DIR"
install -d -o root -g systemd-journal -m 2755 /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
systemctl restart systemd-journald

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$REPO_DIR/python-backend/requirements.txt"
"$VENV_DIR/bin/python" -m pip check
# umask 077 protects generated secrets, but the unprivileged service must be able to read the venv.
chown -R root:"$SERVICE_USER" "$VENV_DIR"
chmod -R u=rwX,g=rX,o= "$VENV_DIR"
chown -R root:"$SERVICE_USER" "$REPO_DIR"
chmod -R u=rwX,g=rX,o= "$REPO_DIR"

if [[ -L "$UPDATER_STATE_DIR" ]] || { [[ -e "$UPDATER_STATE_DIR" ]] && [[ ! -d "$UPDATER_STATE_DIR" ]]; }; then
  printf '升级器状态目录类型不安全：%s\n' "$UPDATER_STATE_DIR" >&2
  exit 1
fi
install -d -o root -g root -m 0700 "$UPDATER_STATE_DIR"
install -d -o root -g "$SERVICE_USER" -m 0750 "$RELEASES_DIR" "$LEGACY_RELEASE_DIR"

install_legacy_link() {
  local name="$1"
  local destination="$2"
  local temporary="$LEGACY_RELEASE_DIR/.${name}.$$.new"
  rm -f -- "$temporary"
  ln -s -- "$destination" "$temporary"
  mv -Tf -- "$temporary" "$LEGACY_RELEASE_DIR/$name"
}

install_legacy_link "app" "$REPO_DIR"
install_legacy_link "venv" "$VENV_DIR"
if [[ ! -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
  temporary_current="$APP_ROOT/.current.$$.new"
  ln -s -- "$LEGACY_RELEASE_DIR" "$temporary_current"
  mv -Tf -- "$temporary_current" "$CURRENT_LINK"
elif [[ ! -L "$CURRENT_LINK" ]]; then
  printf '%s 必须是由安装器管理的符号链接。\n' "$CURRENT_LINK" >&2
  exit 1
fi

client_file="$CONFIG_DIR/client.env"
backend_file="$CONFIG_DIR/backend.env"
connection_token=""
if [[ "$rotate_token" != "true" && -f "$client_file" ]]; then
  connection_token="$(sed -n 's/^QINGJUAN_CONNECTION_TOKEN=//p' "$client_file" | tail -n 1)"
fi
if [[ ! "$connection_token" =~ ^[0-9a-f]{64}$ ]]; then
  connection_token="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
fi
token_digest="$(printf '%s' "$connection_token" | python3 -c '
import hashlib
import sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
')"

admin_password_hash=""
admin_session_secret=""
two_factor_encryption_key=""
two_factor_encryption_key_present="false"
initial_admin_password=""
model_endpoint_allowlist=""
if [[ -f "$backend_file" ]]; then
  admin_password_hash="$(sed -n 's/^QINGJUAN_ADMIN_PASSWORD_HASH=//p' "$backend_file" | tail -n 1)"
  admin_session_secret="$(sed -n 's/^QINGJUAN_ADMIN_SESSION_SECRET=//p' "$backend_file" | tail -n 1)"
  two_factor_encryption_key="$(sed -n 's/^QINGJUAN_2FA_ENCRYPTION_KEY=//p' "$backend_file" | tail -n 1)"
  if grep -q '^QINGJUAN_2FA_ENCRYPTION_KEY=' "$backend_file"; then
    two_factor_encryption_key_present="true"
  fi
  model_endpoint_allowlist="$(sed -n 's/^QINGJUAN_MODEL_ENDPOINT_ALLOWLIST=//p' "$backend_file" | tail -n 1)"
fi
if [[ -z "$admin_password_hash" ]]; then
  initial_admin_password="$(
    PYTHONPATH="$REPO_DIR/python-backend" "$VENV_DIR/bin/python" -c \
      'from app.admin_auth import generate_admin_password; print(generate_admin_password())'
  )"
  admin_password_hash="$(
    printf '%s' "$initial_admin_password" | \
      PYTHONPATH="$REPO_DIR/python-backend" "$VENV_DIR/bin/python" -c \
        'import sys; from app.admin_auth import hash_admin_password; print(hash_admin_password(sys.stdin.read()))'
  )"
  admin_session_secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
elif [[ -z "$admin_session_secret" ]]; then
  admin_session_secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
fi
if [[ "$two_factor_encryption_key_present" == "true" && -n "$two_factor_encryption_key" && ! "$two_factor_encryption_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
  printf '现有 QINGJUAN_2FA_ENCRYPTION_KEY 格式无效；为避免破坏已有二次验证数据，安装已中止。\n' >&2
  exit 1
fi
if [[ -z "$two_factor_encryption_key" ]]; then
  two_factor_encryption_key="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
fi
public_url="${public_url%/}"

printf '%s\n' \
  "QINGJUAN_AUTH_TOKEN_SHA256=$token_digest" \
  "QINGJUAN_MULTI_USER=1" \
  "QINGJUAN_CONNECTION_TOKEN_FILE=$client_file" \
  "QINGJUAN_DATA_DIR=$DATA_DIR" \
  "QINGJUAN_BROWSER_EXECUTABLE=$browser_path" \
  "QINGJUAN_PUBLIC_URL=$public_url" \
  "QINGJUAN_BIND_HOST=$bind_host" \
  "QINGJUAN_PORT=$port" \
  "QINGJUAN_ADMIN_PASSWORD_HASH=$admin_password_hash" \
  "QINGJUAN_ADMIN_SESSION_SECRET=$admin_session_secret" \
  "QINGJUAN_2FA_ENCRYPTION_KEY=$two_factor_encryption_key" \
  "QINGJUAN_MODEL_ENDPOINT_ALLOWLIST=$model_endpoint_allowlist" \
  "QINGJUAN_UPDATE_REQUEST_FILE=$UPDATE_REQUEST_FILE" \
  "QINGJUAN_UPDATE_STATUS_FILE=$UPDATE_STATUS_FILE" \
  > "$backend_file"

printf '%s\n' \
  "QINGJUAN_BACKEND_URL=$public_url" \
  "QINGJUAN_CONNECTION_TOKEN=$connection_token" \
  > "$client_file"

chmod 0600 "$backend_file"
chown root:root "$backend_file"
chmod 0640 "$client_file"
chown root:"$SERVICE_USER" "$client_file"
rm -f -- "$UPDATE_STATUS_FILE"
install -o root -g root -m 0644 "$REPO_DIR/deploy/linux/qingjuan-backend.service" "$SERVICE_UNIT"
install -o root -g root -m 0644 "$REPO_DIR/deploy/linux/qingjuan-updater.service" "$UPDATER_SERVICE_UNIT"
install -o root -g root -m 0644 "$REPO_DIR/deploy/linux/qingjuan-updater.path" "$UPDATER_PATH_UNIT"
install -o root -g root -m 0755 "$REPO_DIR/deploy/linux/qingjuan-update-runner.sh" "$UPDATE_RUNNER_COMMAND"
install -o root -g root -m 0755 "$REPO_DIR/deploy/linux/qingjuan-info.sh" "$INFO_COMMAND"
install -o root -g root -m 0755 "$REPO_DIR/deploy/linux/qingjuan-password.sh" "$PASSWORD_COMMAND"
install -o root -g root -m 0755 "$REPO_DIR/deploy/linux/uninstall.sh" "$UNINSTALL_COMMAND"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" qingjuan-updater.path
# Reinstallation can rotate credentials or change the listener. An already
# running process must reload EnvironmentFile before reporting installation success.
systemctl restart "$SERVICE_NAME"
systemctl start qingjuan-updater.path

print_initial_admin_password() {
  if [[ -z "$initial_admin_password" ]]; then
    return
  fi
  printf '%s\n' \
    '============================================================' \
    '青卷管理界面首次登录密码（仅显示这一次）' \
    "管理密码：${initial_admin_password}" \
    '请妥善保存；遗失时运行 sudo qingjuan-password --generate。' \
    '============================================================'
}

healthy="false"
health_host="$bind_host"
case "$health_host" in
  ""|"0.0.0.0"|"127.0.0.1"|"localhost") health_host="127.0.0.1" ;;
  "::"|"[::]"|"::0") health_host="[::1]" ;;
  *:* )
    health_host="${health_host#\[}"
    health_host="${health_host%\]}"
    health_host="[${health_host}]"
    ;;
esac
for _ in $(seq 1 60); do
  if curl --noproxy '*' --fail --silent --max-time 2 \
    "http://${health_host}:${port}/healthz" >/dev/null 2>&1; then
    healthy="true"
    break
  fi
  sleep 1
done
if [[ "$healthy" != "true" ]]; then
  print_initial_admin_password
  printf '后端未在 60 秒内通过健康检查。最近日志：\n' >&2
  journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
  exit 1
fi

"$INFO_COMMAND"
print_initial_admin_password
