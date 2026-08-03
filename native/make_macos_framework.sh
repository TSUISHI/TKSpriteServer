#!/usr/bin/env bash
#
# TKSpriteServer — macOS の .framework バンドルを仕上げる
# 設計書 §11.6
#
# SCons が作るのは framework ディレクトリとその中の共有ライブラリだけです。
# Godot は "<name>.framework/<name>"（拡張子なし）を dlopen し、codesign は
# バンドルに Resources/Info.plist を要求するため、この 2 点をここで整えます。
# 併せて ad-hoc 署名（無署名だと Apple Silicon 機でロードを拒否されることがある）と、
# 検証用の lipo / otool / codesign 出力を行います。
#
# 使い方:
#   ./make_macos_framework.sh <template_debug|template_release> [version]
#
# 単体の Mac でも同じ手順で使えるよう、CI 専用の記述は入れていません。

set -euo pipefail

TARGET="${1:?usage: make_macos_framework.sh <template_debug|template_release> [version]}"
# 第2引数を省略した場合は plugin.cfg から読みます。呼び出し側が渡し忘れても
# 配布物のバージョンがずれないようにするためです。
VERSION="${2:-}"
if [ -z "${VERSION}" ]; then
	VERSION="$(sed -n 's/^version="\(.*\)"$/\1/p' "$(dirname "$0")/../addons/tk_sprite_server/plugin.cfg")"
fi
if [ -z "${VERSION}" ]; then
	echo "error: plugin.cfg から version を読めませんでした。" >&2
	exit 1
fi

BIN_DIR="$(cd "$(dirname "$0")/../addons/tk_sprite_server/bin" && pwd)"
NAME="libtksprite.macos.${TARGET}"
FRAMEWORK="${BIN_DIR}/${NAME}.framework"

if [ ! -d "${FRAMEWORK}" ]; then
	echo "error: ${FRAMEWORK} がありません。先に scons を実行してください。" >&2
	exit 1
fi

# SCons は SHLIBSUFFIX（macOS では .dylib）を付けて出力することがあります。
# Godot が開くのは framework 名と同じ「拡張子なし」のファイルだけなので、
# 拡張子付きで出ていればここで改名します。既に正しい名前ならそのままです。
if [ ! -f "${FRAMEWORK}/${NAME}" ]; then
	for candidate in "${FRAMEWORK}/${NAME}".*; do
		if [ -f "${candidate}" ]; then
			mv "${candidate}" "${FRAMEWORK}/${NAME}"
			break
		fi
	done
fi

if [ ! -f "${FRAMEWORK}/${NAME}" ]; then
	echo "error: ${FRAMEWORK} に実行バイナリが見つかりません。" >&2
	ls -la "${FRAMEWORK}" >&2
	exit 1
fi

chmod +x "${FRAMEWORK}/${NAME}"

# バージョン無しの最小 framework 構成のため、Info.plist は Resources/ 直下に置きます。
mkdir -p "${FRAMEWORK}/Resources"
cat > "${FRAMEWORK}/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>jp.tsuishi.tkspriteserver.${TARGET//_/-}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${NAME}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>10.13</string>
</dict>
</plist>
PLIST

# 正式な Developer ID 署名・公証は利用者側の責務です（設計書 §11.6(3)）。
# ここで行うのは、ロード拒否を避けるための ad-hoc 署名のみです。
codesign --force --deep --sign - "${FRAMEWORK}"

echo "=== lipo -info ==="
lipo -info "${FRAMEWORK}/${NAME}"
echo "=== otool -L ==="
otool -L "${FRAMEWORK}/${NAME}"
echo "=== codesign -dv ==="
codesign -dv "${FRAMEWORK}" 2>&1
echo "=== tree ==="
find "${FRAMEWORK}" -print
