#!/bin/bash
# 앱 아이콘 빌드 스크립트
# - SVG를 다양한 크기의 PNG로 변환
# - macOS iconutil로 .icns 묶음 생성
#
# 의존성:
#   - rsvg-convert (preferred) 또는 ImageMagick convert
#   - macOS의 iconutil (시스템 내장)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SVG_FILE="$PROJECT_ROOT/src/AppIcon.svg"
ICONSET_DIR="$PROJECT_ROOT/build/AppIcon.iconset"
ICNS_OUT="$PROJECT_ROOT/build/AppIcon.icns"

if [ ! -f "$SVG_FILE" ]; then
    echo "❌ SVG 파일이 없습니다: $SVG_FILE"
    exit 1
fi

# 변환 도구 자동 감지
RSVG=""
CONVERT=""
if command -v rsvg-convert >/dev/null 2>&1; then
    RSVG="rsvg-convert"
elif command -v convert >/dev/null 2>&1; then
    CONVERT="convert"
elif command -v magick >/dev/null 2>&1; then
    CONVERT="magick"
else
    echo "❌ SVG 변환 도구가 없습니다"
    echo "   macOS: brew install librsvg"
    echo "   또는: brew install imagemagick"
    exit 1
fi

mkdir -p "$ICONSET_DIR"

# macOS .icns에 필요한 크기들 (Apple HIG)
# 이름 = icon_{size}x{size}[@2x].png
declare -a sizes=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

echo "🎨 SVG → PNG 변환 중..."
for spec in "${sizes[@]}"; do
    size="${spec%%:*}"
    name="${spec##*:}"
    out="$ICONSET_DIR/$name"
    
    if [ -n "$RSVG" ]; then
        rsvg-convert -w "$size" -h "$size" "$SVG_FILE" -o "$out"
    else
        $CONVERT -background none -resize "${size}x${size}" "$SVG_FILE" "$out"
    fi
    echo "   ✅ $name (${size}x${size})"
done

# .icns 생성 (macOS only)
if command -v iconutil >/dev/null 2>&1; then
    echo ""
    echo "📦 iconutil로 .icns 생성..."
    iconutil -c icns -o "$ICNS_OUT" "$ICONSET_DIR"
    echo "✅ 완성: $ICNS_OUT"
else
    # Linux 폴백: png2icns 또는 그냥 큰 PNG 사용
    echo "⚠️  iconutil 없음 (macOS에서만 동작)"
    echo "   대안: png2icns 또는 ImageMagick"
    
    if command -v png2icns >/dev/null 2>&1; then
        png2icns "$ICNS_OUT" \
            "$ICONSET_DIR/icon_16x16.png" \
            "$ICONSET_DIR/icon_32x32.png" \
            "$ICONSET_DIR/icon_128x128.png" \
            "$ICONSET_DIR/icon_256x256.png" \
            "$ICONSET_DIR/icon_512x512.png" 2>/dev/null && \
            echo "✅ png2icns로 생성: $ICNS_OUT" || true
    elif command -v $CONVERT >/dev/null 2>&1; then
        # ImageMagick convert는 .icns도 지원
        $CONVERT \
            "$ICONSET_DIR/icon_16x16.png" \
            "$ICONSET_DIR/icon_32x32.png" \
            "$ICONSET_DIR/icon_128x128.png" \
            "$ICONSET_DIR/icon_256x256.png" \
            "$ICONSET_DIR/icon_512x512.png" \
            "$ICNS_OUT" 2>/dev/null && \
            echo "✅ ImageMagick으로 생성: $ICNS_OUT" || \
            echo "⚠️  .icns 생성 실패. 빌드 스크립트는 PNG만 사용할 수도 있음"
    fi
fi

# 결과
if [ -f "$ICNS_OUT" ]; then
    echo ""
    echo "📦 결과: $(ls -lh "$ICNS_OUT" | awk '{print $5}')"
fi
