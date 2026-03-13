#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONLYOFFICE_EDITOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_ZIP_PATH="$ONLYOFFICE_EDITOR_ROOT/output/onlyoffice-editor.zip"
DEFAULT_TARGET_PATH="$ONLYOFFICE_EDITOR_ROOT/../ai-excel-desktop/tauri/public/onlyoffice/7"

ZIP_PATH="${1:-$DEFAULT_ZIP_PATH}"
TARGET_PATH="${2:-$DEFAULT_TARGET_PATH}"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "构建产物不存在: $ZIP_PATH" >&2
  exit 1
fi

if [[ ! -d "$TARGET_PATH" ]]; then
  echo "目标目录不存在: $TARGET_PATH" >&2
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "缺少 rsync，请先安装 rsync" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "缺少 python3，请先安装 python3" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/onlyoffice-sync.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "解压构建产物: $ZIP_PATH"
python3 - "$ZIP_PATH" "$TEMP_DIR" <<'PY'
import pathlib
import sys
import zipfile

zip_path = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])

with zipfile.ZipFile(zip_path) as archive:
    archive.extractall(dest)
PY

ROOTS=()
ROOTS_FILE="$TEMP_DIR/roots.txt"
python3 - "$ZIP_PATH" > "$ROOTS_FILE" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    roots = sorted({name.split('/', 1)[0] for name in archive.namelist() if name and not name.startswith('__MACOSX/')})
    for root in roots:
        if root:
            print(root)
PY

while IFS= read -r line; do
  [[ -n "$line" ]] && ROOTS+=("$line")
done < "$ROOTS_FILE"

if [[ ${#ROOTS[@]} -eq 0 ]]; then
  echo "zip 中未找到可同步内容: $ZIP_PATH" >&2
  exit 1
fi

echo "开始同步到: $TARGET_PATH"
for root in "${ROOTS[@]}"; do
  SRC_DIR="$TEMP_DIR/$root"
  DEST_DIR="$TARGET_PATH/$root"

  if [[ ! -e "$SRC_DIR" ]]; then
    echo "跳过缺失目录: $SRC_DIR"
    continue
  fi

  mkdir -p "$DEST_DIR"
  echo "同步 $root"
  rsync -a --delete "$SRC_DIR/" "$DEST_DIR/"
done

echo "同步完成"
echo "源 zip: $ZIP_PATH"
echo "目标目录: $TARGET_PATH"
