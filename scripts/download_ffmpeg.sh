#!/bin/bash
# FFmpeg/ffprobe 정적 바이너리 다운로드
# - 다중 소스 폴백 (evermeet.cx, osxexperts.net)
# - Apple Silicon / Intel 자동 감지

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$PROJECT_ROOT/vendor"

mkdir -p "$VENDOR_DIR"
cd "$VENDOR_DIR"

ARCH="${ARCH:-$(uname -m)}"

# evermeet.cx는 동일 zip이 arm64+intel 둘 다 포함 (universal binary)
EVERMEET_FFMPEG="https://evermeet.cx/ffmpeg/getrelease/zip"
EVERMEET_FFPROBE="https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"

case "$ARCH" in
    arm64|aarch64)
        ARCH_LABEL="Apple Silicon"
        OSXEXPERTS_FFMPEG="https://www.osxexperts.net/ffmpeg71arm.zip"
        OSXEXPERTS_FFPROBE="https://www.osxexperts.net/ffprobe71arm.zip"
        ;;
    x86_64)
        ARCH_LABEL="Intel"
        OSXEXPERTS_FFMPEG="https://www.osxexperts.net/ffmpeg71intel.zip"
        OSXEXPERTS_FFPROBE="https://www.osxexperts.net/ffprobe71intel.zip"
        ;;
    *)
        echo "❌ 지원하지 않는 아키텍처: $ARCH"
        exit 1
        ;;
esac

echo "📥 FFmpeg 다운로드 시작 ($ARCH_LABEL)"
echo ""

if [ -f "$VENDOR_DIR/ffmpeg" ] && [ -f "$VENDOR_DIR/ffprobe" ]; then
    echo "✅ vendor/ffmpeg, ffprobe 이미 존재 (스킵)"
    echo "   재다운로드: rm -rf vendor/"
    exit 0
fi

# 폴백 다운로드 함수
download_with_fallback() {
    local target=$1
    shift
    local urls=("$@")
    
    for url in "${urls[@]}"; do
        echo "   ▼ 시도: $url"
        if curl -fL --retry 2 --retry-delay 2 --max-time 120 -o "${target}.zip" "$url"; then
            echo "      ✅ 다운로드 성공"
            return 0
        else
            echo "      ⚠️  실패, 다음 소스 시도..."
        fi
    done
    
    echo "   ❌ 모든 소스 실패"
    return 1
}

echo "🔽 ffmpeg 다운로드..."
download_with_fallback "ffmpeg" \
    "$EVERMEET_FFMPEG" \
    "$OSXEXPERTS_FFMPEG"

echo ""
echo "🔽 ffprobe 다운로드..."
download_with_fallback "ffprobe" \
    "$EVERMEET_FFPROBE" \
    "$OSXEXPERTS_FFPROBE"

echo ""
echo "📦 압축 해제..."
unzip -o -q ffmpeg.zip && rm ffmpeg.zip
unzip -o -q ffprobe.zip && rm ffprobe.zip

chmod +x ffmpeg ffprobe

if [ "$(uname)" = "Darwin" ]; then
    xattr -d com.apple.quarantine ffmpeg 2>/dev/null || true
    xattr -d com.apple.quarantine ffprobe 2>/dev/null || true
fi

echo ""
echo "📦 다운로드 완료:"
ls -lh ffmpeg ffprobe

if [ "$(uname)" = "Darwin" ]; then
    echo ""
    echo "🔍 동작 검증:"
    ./ffmpeg -version | head -1 && echo "   ✅ ffmpeg OK"
    ./ffprobe -version | head -1 && echo "   ✅ ffprobe OK"
    
    if ./ffmpeg -filters 2>/dev/null | awk '{print $2}' | grep -qx "amix"; then
        echo "   ✅ amix 필터 포함"
    else
        echo "   ⚠️  amix 필터 없음 (이상)"
    fi
fi

echo ""
echo "✅ vendor/ 준비 완료"
