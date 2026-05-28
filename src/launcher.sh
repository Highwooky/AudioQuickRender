#!/bin/bash
# Audio Mixer .app 런처
# - 인자 있음: 드래그앤드롭 → 바로 믹스다운
# - 인자 없음: 파일 선택 다이얼로그 (취소 시 종료)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES="$APP_BUNDLE/Resources"

FFMPEG="$RESOURCES/ffmpeg"
FFPROBE="$RESOURCES/ffprobe"
MIX_SCRIPT="$RESOURCES/mix_audio.py"
INSTALL_QA="$RESOURCES/install_quickaction.sh"

LOG="/tmp/audiomixer.log"
echo "=== $(date) === .app 런처 실행" >> "$LOG"
echo "Bundle: $APP_BUNDLE" >> "$LOG"
echo "인자 수: $#" >> "$LOG"

# 권한 보장
chmod +x "$FFMPEG" "$FFPROBE" "$MIX_SCRIPT" "$INSTALL_QA" 2>/dev/null || true

# quarantine 제거
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

# Quick Action 자동 설치 (이미 설치되어 있으면 스킵)
if [ -x "$INSTALL_QA" ]; then
    "$INSTALL_QA" "$APP_BUNDLE" >> "$LOG" 2>&1 || true
fi

export FFMPEG_PATH="$FFMPEG"
export FFPROBE_PATH="$FFPROBE"

# ─────────────────────────────────────────────────────────────
files=()

if [ $# -eq 0 ]; then
    # 인자 없음 → 바로 파일 선택 다이얼로그 (환영 메시지 생략)
    echo "파일 선택 다이얼로그 표시" >> "$LOG"
    
    RESULT=$(osascript <<'APPLESCRIPT' 2>/dev/null
try
    set fileList to choose file with prompt "믹스다운할 오디오 파일을 2개 이상 선택하세요 (Cmd+클릭으로 다중 선택)" ¬
        with multiple selections allowed ¬
        of type {"public.audio"}
    set output to ""
    repeat with f in fileList
        set output to output & POSIX path of f & linefeed
    end repeat
    return output
on error errMsg number errNum
    if errNum = -128 then
        return "CANCEL"
    end if
    return "ERROR:" & errMsg
end try
APPLESCRIPT
)
    
    if [ "$RESULT" = "CANCEL" ] || [ -z "$RESULT" ]; then
        echo "사용자 취소" >> "$LOG"
        exit 0
    fi
    
    if [[ "$RESULT" == ERROR:* ]]; then
        osascript -e "display dialog \"파일 선택 오류: ${RESULT#ERROR:}\" buttons {\"확인\"} with icon stop" 2>/dev/null
        exit 1
    fi
    
    while IFS= read -r line; do
        [ -n "$line" ] && files+=("$line")
    done <<< "$RESULT"
else
    for arg in "$@"; do
        files+=("$arg")
    done
fi

echo "처리할 파일 수: ${#files[@]}" >> "$LOG"

if [ ${#files[@]} -lt 2 ]; then
    osascript -e 'display dialog "믹스다운하려면 오디오 파일을 2개 이상 선택하세요." buttons {"확인"} default button "확인" with icon note with title "Audio Mixer"' 2>/dev/null
    exit 1
fi

# Python 실행
PYTHON_BIN="/usr/bin/python3"
if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="$(which python3 2>/dev/null || echo '')"
fi

if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    osascript -e 'display dialog "Python3가 시스템에 없습니다.\n\n터미널에서 다음 명령을 실행하세요:\nxcode-select --install" buttons {"확인"} with icon stop with title "Audio Mixer 오류"' 2>/dev/null
    exit 1
fi

echo "Python: $PYTHON_BIN" >> "$LOG"
echo "FFmpeg: $FFMPEG" >> "$LOG"

"$PYTHON_BIN" "$MIX_SCRIPT" "${files[@]}" >> "$LOG" 2>&1
EXIT_CODE=$?

echo "종료 코드: $EXIT_CODE" >> "$LOG"
echo "" >> "$LOG"

if [ $EXIT_CODE -ne 0 ]; then
    osascript -e "display dialog \"믹스다운 실패 (코드 $EXIT_CODE)\n\n로그: $LOG\" buttons {\"확인\"} default button \"확인\" with icon stop with title \"Audio Mixer\"" 2>/dev/null
fi

exit $EXIT_CODE
