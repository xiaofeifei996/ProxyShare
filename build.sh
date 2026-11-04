#!/bin/bash
# ProxyShare 打包脚本
set -e

VARIANT="${1:-roothide}"
NAME="ProxyShare"
VERSION="1.0.0"

if [ -z "$THEOS" ]; then
    echo "错误: 未设置 THEOS 环境变量" >&2
    exit 1
fi

echo "=== 构建变体: $VARIANT ==="
export PATH="$THEOS/bin:$PATH"

rm -rf .theos packages
mkdir -p packages

make clean >/dev/null 2>&1 || true
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" DEBUG=0 2>&1 | tail -30

if [ ! -f .theos/obj/psd ]; then
    echo "错误: 未生成 .theos/obj/psd" >&2
    exit 1
fi

STAGE="packages/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R layout/* "$STAGE/"

mkdir -p "$STAGE/usr/libexec"
cp .theos/obj/psd "$STAGE/usr/libexec/psd"
chmod 0755 "$STAGE/usr/libexec/psd"
chmod 0755 "$STAGE/usr/libexec/psd-launcher"

# 用 entitlements 重新签名（关键：脱离 App 沙盒，否则 /var/tmp 等路径不可写）
echo "=== 用 entitlements 签名 psd ==="
LDID="${THEOS}/bin/ldid"
[ -x "$LDID" ] || LDID="$(command -v ldid || true)"
LIPO="$(command -v lipo || true)"
echo "ldid=$LDID"
echo "lipo=$LIPO"

if [ -n "$LDID" ] && [ -x "$LDID" ]; then
    mkdir -p /tmp/signwork
    rm -f /tmp/signwork/psd-*
    # 先去掉原有签名再签（避免 assert）
    "$LDID" -C 1>/dev/null 2>&1 || true
    for a in arm64 arm64e; do
        if "$LIPO" -thin "$a" "$STAGE/usr/libexec/psd" -output "/tmp/signwork/psd-$a" 2>/dev/null; then
            echo "  签名 slice $a"
            "$LDID" -S psd.entitlements "/tmp/signwork/psd-$a" && echo "    ok" || echo "    FAILED"
        fi
    done
    if [ -f /tmp/signwork/psd-arm64 ]; then
        if [ -f /tmp/signwork/psd-arm64e ]; then
            "$LIPO" -create /tmp/signwork/psd-arm64 /tmp/signwork/psd-arm64e \
                 -output "$STAGE/usr/libexec/psd"
        else
            cp /tmp/signwork/psd-arm64 "$STAGE/usr/libexec/psd"
        fi
        chmod 0755 "$STAGE/usr/libexec/psd"
    fi
    echo "校验 entitlements:"
    "$LDID" -e "$STAGE/usr/libexec/psd" 2>&1 | head -15 || echo "(读取失败)"
else
    echo "警告: 未找到 ldid，跳过签名"
fi

mkdir -p "$STAGE/DEBIAN"
cp control "$STAGE/DEBIAN/control"
cp DEBIAN/postinst "$STAGE/DEBIAN/postinst"
cp DEBIAN/prerm "$STAGE/DEBIAN/prerm"
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

find "$STAGE" -type d -exec chmod 0755 {} \;
find "$STAGE" -type f -name "*.plist" -exec chmod 0644 {} \;
chmod 0755 "$STAGE/usr/libexec/psd" "$STAGE/usr/libexec/psd-launcher"

# 确认 DEBIAN 存在（dpkg-deb 要求）
[ -f "$STAGE/DEBIAN/control" ] || { echo "错误: DEBIAN/control 缺失" >&2; exit 1; }

DEB="packages/${NAME}_${VERSION}_${VARIANT}.deb"
dpkg-deb -Zxz --root-owner-group -b "$STAGE" "$DEB"

echo "=== 构建产物 ==="
ls -lh "$DEB"
echo "=== 包含文件 ==="
dpkg-deb -c "$DEB"
