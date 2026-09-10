"""Build a deterministic QingJuan v1 package without executing plugin code."""
from __future__ import annotations

import argparse
import io
import sys
import zipfile
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT / "python-backend"))

from app.plugin_system.manifest import PluginPackageError  # noqa: E402
from app.plugin_system.packages import inspect_package  # noqa: E402


def build_package(directory: Path) -> tuple[bytes, str, str]:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for filename in ("manifest.json", "plugin.py"):
            path = directory / filename
            if path.is_symlink() or not path.is_file():
                raise PluginPackageError(f"插件目录必须包含普通文件 {filename}")
            info = zipfile.ZipInfo(filename, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())
    data = output.getvalue()
    manifest, _ = inspect_package(data)
    return data, manifest.id, manifest.version


def main() -> int:
    parser = argparse.ArgumentParser(description="打包青卷站点插件（仅校验格式与语法，不执行插件代码）")
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true", help="仅校验，不生成插件包")
    args = parser.parse_args()
    try:
        data, plugin_id, version = build_package(args.directory)
        if args.check:
            print(f"格式校验通过：{plugin_id} v{version}")
            return 0
        target = args.output or REPOSITORY_ROOT / "dist" / "plugins" / f"{plugin_id}-{version}.qjplugin"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        print(f"已生成插件包：{target.resolve()}")
        return 0
    except (OSError, PluginPackageError) as error:
        print(f"插件打包失败：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
