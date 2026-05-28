#!/bin/bash
# Audio Mixer .app 빌드 스크립트
# - FFmpeg/ffprobe 동봉 .app 번들 생성
# - 사용법: ./scripts/build_app.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Audio Mixer.app"
BUILD_DIR="$PROJECT_ROOT/build"
APP_PATH="$BUILD_DIR/$APP_NAME"

echo "🔨 Audio Mixer.app 빌드 시작..."
echo "   프로젝트: $PROJECT_ROOT"
echo "   출력: $APP_PATH"

# ─── 1. 깨끗하게 시작 ───────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# ─── 2. Info.plist 복사 ─────────────────────────────────────
cp "$PROJECT_ROOT/src/Info.plist" "$APP_PATH/Contents/Info.plist"

# ─── 3. PkgInfo 파일 (구식이지만 일부 macOS 기능에 필요) ──
echo -n "APPL????" > "$APP_PATH/Contents/PkgInfo"

# ─── 4. 런처 스크립트 (실행 파일) ───────────────────────────
cp "$PROJECT_ROOT/src/launcher.sh" "$APP_PATH/Contents/MacOS/AudioMixer"
chmod +x "$APP_PATH/Contents/MacOS/AudioMixer"

# ─── 5. Python 엔진 + Quick Action 설치 스크립트 ────────────
cp "$PROJECT_ROOT/src/mix_audio.py" "$APP_PATH/Contents/Resources/"
chmod +x "$APP_PATH/Contents/Resources/mix_audio.py"

cp "$PROJECT_ROOT/src/install_quickaction.sh" "$APP_PATH/Contents/Resources/"
chmod +x "$APP_PATH/Contents/Resources/install_quickaction.sh"

# ─── 6. FFmpeg/ffprobe 동봉 ─────────────────────────────────
FFMPEG_SRC="${FFMPEG_SOURCE:-$PROJECT_ROOT/vendor/ffmpeg}"
FFPROBE_SRC="${FFPROBE_SOURCE:-$PROJECT_ROOT/vendor/ffprobe}"

if [ ! -f "$FFMPEG_SRC" ]; then
    echo "❌ FFmpeg 바이너리가 없습니다: $FFMPEG_SRC"
    echo "   먼저 ./scripts/download_ffmpeg.sh 를 실행하세요."
    exit 1
fi

if [ ! -f "$FFPROBE_SRC" ]; then
    echo "❌ ffprobe 바이너리가 없습니다: $FFPROBE_SRC"
    exit 1
fi

cp "$FFMPEG_SRC" "$APP_PATH/Contents/Resources/ffmpeg"
cp "$FFPROBE_SRC" "$APP_PATH/Contents/Resources/ffprobe"
chmod +x "$APP_PATH/Contents/Resources/ffmpeg"
chmod +x "$APP_PATH/Contents/Resources/ffprobe"

# ─── 7. 아이콘 빌드 및 적용 ─────────────────────────────────
ICON_SCRIPT="$PROJECT_ROOT/scripts/build_icon.sh"
ICNS_FILE="$PROJECT_ROOT/build/AppIcon.icns"

if [ -f "$PROJECT_ROOT/src/AppIcon.svg" ] && [ -x "$ICON_SCRIPT" ]; then
    echo ""
    echo "🎨 아이콘 빌드..."
    if "$ICON_SCRIPT" > /tmp/audiomixer_icon_build.log 2>&1; then
        if [ -f "$ICNS_FILE" ]; then
            cp "$ICNS_FILE" "$APP_PATH/Contents/Resources/AppIcon.icns"
            # Info.plist에 아이콘 등록
            if command -v plutil >/dev/null 2>&1; then
                plutil -replace CFBundleIconFile -string "AppIcon" \
                    "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
            else
                # plistlib로 수정 (Linux/CI)
                python3 <<PYEOF
import plistlib
p = plistlib.load(open('$APP_PATH/Contents/Info.plist', 'rb'))
p['CFBundleIconFile'] = 'AppIcon'
with open('$APP_PATH/Contents/Info.plist', 'wb') as f:
    plistlib.dump(p, f)
PYEOF
            fi
            echo "   ✅ 아이콘 적용: AppIcon.icns"
        else
            echo "   ⚠️  .icns 생성 실패 (PNG만 있음)"
            # 폴백: 512px PNG라도 사용
            if [ -f "$PROJECT_ROOT/build/AppIcon.iconset/icon_512x512.png" ]; then
                cp "$PROJECT_ROOT/build/AppIcon.iconset/icon_512x512.png" \
                   "$APP_PATH/Contents/Resources/AppIcon.png"
                echo "   ✅ 폴백 PNG 아이콘 적용"
            fi
        fi
    else
        echo "   ⚠️  아이콘 빌드 실패. 기본 아이콘 사용"
        cat /tmp/audiomixer_icon_build.log | tail -5
    fi
fi

# ─── 8. quarantine 속성 제거 ────────────────────────────────
xattr -cr "$APP_PATH" 2>/dev/null || true

# ─── 9. 검증 ───────────────────────────────────────────────
echo ""
echo "🔍 빌드 결과 검증..."

# Info.plist 유효성
if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$APP_PATH/Contents/Info.plist" > /dev/null; then
        echo "❌ Info.plist 검증 실패"
        exit 1
    fi
    echo "   ✅ Info.plist 유효 (plutil)"
else
    # plutil이 없는 환경 (Linux CI 등): Python plistlib로 검증
    if ! python3 -c "import plistlib; plistlib.load(open('$APP_PATH/Contents/Info.plist', 'rb'))" 2>/dev/null; then
        echo "❌ Info.plist 검증 실패 (plistlib)"
        exit 1
    fi
    echo "   ✅ Info.plist 유효 (plistlib)"
fi

# 실행 권한 확인
for f in MacOS/AudioMixer Resources/ffmpeg Resources/ffprobe Resources/mix_audio.py Resources/install_quickaction.sh; do
    if [ ! -x "$APP_PATH/Contents/$f" ]; then
        echo "❌ 실행 권한 없음: $f"
        exit 1
    fi
done
echo "   ✅ 모든 실행 파일 권한 OK"

# FFmpeg 실제 동작 확인 (macOS에서 빌드 시에만 가능)
if [ "$(uname)" = "Darwin" ]; then
    if "$APP_PATH/Contents/Resources/ffmpeg" -version > /dev/null 2>&1; then
        VER=$("$APP_PATH/Contents/Resources/ffmpeg" -version | head -1)
        echo "   ✅ FFmpeg 동작 확인: $VER"
    else
        echo "   ⚠️  FFmpeg 실행 테스트 실패 (Apple Silicon에서 정상 동작할 수 있음)"
    fi
fi

# 크기
TOTAL_SIZE=$(du -sh "$APP_PATH" | cut -f1)
echo "   📦 .app 크기: $TOTAL_SIZE"

echo ""
echo "✅ 빌드 완료: $APP_PATH"
echo ""
echo "테스트:"
echo "  open '$APP_PATH'"
