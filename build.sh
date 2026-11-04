#!/bin/bash
# ProxyShare 打包脚本
set -e

VARIANT="${1:-roothide}"
NAME="ProxyShare"
VERSION="1.1.0"

if [ -z "$THEOS" ]; then
    echo "错误: 未设置 THEOS 环境变量" >&2
    exit 1
fi

echo "=== 构建变体: $VARIANT ==="
export PATH="$THEOS/bin:$PATH"

rm -rf .theos packages
mkdir -p packages

make clean >/dev/null 2>&1 || true

# 构建守护进程 + 设置面板
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" DEBUG=0 2>&1 | tail -40

# 子项目构建，产物路径不固定，逐个查找
THEOS_PSD="$(find .theos -type f -name psd   -not -path '*.dSYM*' 2>/dev/null | head -1)"
echo "psd = ${THEOS_PSD:-未找到}"
if [ -z "$THEOS_PSD" ]; then
    echo "错误: psd 未生成" >&2
    exit 1
fi

# Theos 会把 bundle 放在 .theos/obj/ 下
PREFS_BUNDLE="$(find .theos -name 'ProxySharePrefs.bundle' -type d 2>/dev/null | head -1)"
echo "=== 设置面板 bundle: ${PREFS_BUNDLE:-未找到} ==="

STAGE="packages/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R layout/* "$STAGE/"

mkdir -p "$STAGE/usr/libexec" "$STAGE/usr/bin"
cp "$THEOS_PSD" "$STAGE/usr/libexec/psd"
chmod 0755 "$STAGE/usr/libexec/psd-launcher"

# 安装设置面板 bundle
if [ -n "$PREFS_BUNDLE" ] && [ -d "$PREFS_BUNDLE" ]; then
    DEST="$STAGE/Library/PreferenceBundles/ProxySharePrefs"
    rm -rf "$DEST"
    mkdir -p "$DEST"
    cp -R "$PREFS_BUNDLE"/. "$DEST"/

    # 资源（Root.plist / Info.plist / 图标）手动补进去——
    # Theos 的 RESOURCE_DIRS 对 bundle 目标支持不稳定，直接拷更可靠
    if [ -d Prefs/Resources ]; then
        cp -R Prefs/Resources/. "$DEST"/
    fi

    chmod -R 0755 "$DEST"
    echo "已打包设置面板，内容："
    ls -1 "$DEST"
else
    echo "警告: 未找到设置面板 bundle，将只打包守护进程"
fi

# ------------------------------------------------ 签名
echo "=== 用 entitlements 签名 psd ==="
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --entitlements psd.entitlements \
             "$STAGE/usr/libexec/psd" 2>&1 | head -3
    echo "校验:"
    codesign -d --entitlements - "$STAGE/usr/libexec/psd" 2>&1 | head -12
else
    echo "未找到 codesign，回退 ldid"
    LDID="${THEOS}/bin/ldid"; [ -x "$LDID" ] || LDID="$(command -v ldid || true)"
    if [ -n "$LDID" ]; then
        mkdir -p /tmp/sg && rm -f /tmp/sg/psd-*
        for a in arm64 arm64e; do
            lipo -thin "$a" "$STAGE/usr/libexec/psd" -output "/tmp/sg/psd-$a" 2>/dev/null || continue
            "$LDID" -S psd.entitlements "/tmp/sg/psd-$a" || echo "  $a 失败"
        done
        if [ -f /tmp/sg/psd-arm64 ] && [ -f /tmp/sg/psd-arm64e ]; then
            lipo -create /tmp/sg/psd-arm64 /tmp/sg/psd-arm64e -output "$STAGE/usr/libexec/psd"
        fi
    fi
fi
chmod 0755 "$STAGE/usr/libexec/psd"

chmod 0755 "$STAGE/usr/bin/psctl"

# 面板也要签名（否则 Settings 拒绝加载）
if [ -d "$STAGE/Library/PreferenceBundles/ProxySharePrefs" ]; then
    if command -v codesign >/dev/null 2>&1; then
        codesign --force --sign - \
                 "$STAGE/Library/PreferenceBundles/ProxySharePrefs/ProxySharePrefs" 2>&1 | head -2 || true
    fi
fi

# ------------------------------------------------ 控制文件
mkdir -p "$STAGE/DEBIAN"
cp control "$STAGE/DEBIAN/control"
sed -i.bak "s/^Version:.*/Version: ${VERSION}/" "$STAGE/DEBIAN/control"
rm -f "$STAGE/DEBIAN/control.bak"
cp DEBIAN/postinst "$STAGE/DEBIAN/postinst"
cp DEBIAN/prerm    "$STAGE/DEBIAN/prerm"
cp DEBIAN/postrm   "$STAGE/DEBIAN/postrm"

find "$STAGE" -type d -exec chmod 0755 {} \;
find "$STAGE" -type f -name "*.plist" -exec chmod 0644 {} \;
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"
chmod 0755 "$STAGE/usr/libexec/psd" "$STAGE/usr/libexec/psd-launcher"

[ -f "$STAGE/DEBIAN/control" ] || { echo "错误: control 缺失" >&2; exit 1; }

DEB="packages/${NAME}_${VERSION}_${VARIANT}.deb"
dpkg-deb -Zxz --root-owner-group -b "$STAGE" "$DEB"

echo "=== 构建产物 ==="
ls -lh "$DEB"
echo "=== 包含文件 ==="
dpkg-deb -c "$DEB"
