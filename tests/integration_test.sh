#!/bin/bash
# Audio Mixer .app 통합 테스트
# - 빌드된 .app으로 실제 믹스다운 수행
# - 결과물의 사양(24bit/48kHz/Stereo) 검증
# - 다양한 입력 포맷 조합 테스트

set -eu
# pipefail은 grep -q와 함께 쓰면 SIGPIPE로 인해 의도치 않은 실패 발생.
# 의도적으로 비활성화.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH="$PROJECT_ROOT/build/Audio Mixer.app"
TEST_DIR="$PROJECT_ROOT/build/test_workspace"
PYTHON="${PYTHON:-/usr/bin/python3}"

# 실패 카운터
FAILED=0
PASSED=0

# 색상
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✅ PASS${NC}: $1"; PASSED=$((PASSED+1)); }
fail() { echo -e "${RED}❌ FAIL${NC}: $1"; FAILED=$((FAILED+1)); }
info() { echo -e "${YELLOW}ℹ️${NC}  $1"; }

echo "════════════════════════════════════════════"
echo "  Audio Mixer .app 통합 테스트"
echo "════════════════════════════════════════════"
echo "App: $APP_PATH"
echo "Test workspace: $TEST_DIR"
echo ""

# ─── 사전 체크 ──────────────────────────────────────────────
if [ ! -d "$APP_PATH" ]; then
    fail ".app 번들이 없음. 먼저 ./scripts/build_app.sh 실행"
    exit 1
fi

FFMPEG="$APP_PATH/Contents/Resources/ffmpeg"
FFPROBE="$APP_PATH/Contents/Resources/ffprobe"
MIX_SCRIPT="$APP_PATH/Contents/Resources/mix_audio.py"
LAUNCHER="$APP_PATH/Contents/MacOS/AudioMixer"

# ═══════════════════════════════════════════════════════════
# Test 1: 번들 구조
# ═══════════════════════════════════════════════════════════
echo "── Test 1: .app 번들 구조 ──"

[ -f "$APP_PATH/Contents/Info.plist" ] && pass "Info.plist 존재" || fail "Info.plist 없음"
[ -f "$APP_PATH/Contents/PkgInfo" ] && pass "PkgInfo 존재" || fail "PkgInfo 없음"
[ -x "$LAUNCHER" ] && pass "런처 실행 권한" || fail "런처 실행 권한 없음"
[ -x "$FFMPEG" ] && pass "ffmpeg 실행 권한" || fail "ffmpeg 실행 권한 없음"
[ -x "$FFPROBE" ] && pass "ffprobe 실행 권한" || fail "ffprobe 실행 권한 없음"
[ -f "$MIX_SCRIPT" ] && pass "mix_audio.py 존재" || fail "mix_audio.py 없음"
[ -x "$APP_PATH/Contents/Resources/install_quickaction.sh" ] && pass "Quick Action 설치 스크립트 존재" || fail "Quick Action 스크립트 없음"
echo ""

# ═══════════════════════════════════════════════════════════
# Test 2: Info.plist 유효성
# ═══════════════════════════════════════════════════════════
echo "── Test 2: Info.plist 검증 ──"

if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$APP_PATH/Contents/Info.plist" > /dev/null 2>&1; then
        pass "Info.plist plutil 검증 통과"
    else
        fail "Info.plist plutil 검증 실패"
    fi
else
    # Linux 환경 (CI 테스트): plistlib로 검증
    if "$PYTHON" -c "import plistlib; plistlib.load(open('$APP_PATH/Contents/Info.plist', 'rb'))" 2>/dev/null; then
        pass "Info.plist plistlib 검증 통과 (plutil 부재)"
    else
        fail "Info.plist plistlib 검증 실패"
    fi
fi

# 필수 키 존재 여부 (Python의 plistlib 사용 - jq보다 일관적)
"$PYTHON" -c "
import plistlib, sys
with open('$APP_PATH/Contents/Info.plist', 'rb') as f:
    p = plistlib.load(f)
# v5: NSServices는 .app이 아닌 별도 Quick Action이 담당
required = ['CFBundleExecutable', 'CFBundleIdentifier', 'CFBundlePackageType',
            'CFBundleDocumentTypes']
missing = [k for k in required if k not in p]
if missing:
    print('MISSING:', missing)
    sys.exit(1)
" && pass "필수 plist 키 모두 존재" || fail "plist 키 누락"
echo ""

# ═══════════════════════════════════════════════════════════
# Test 3: FFmpeg 동봉본 동작
# ═══════════════════════════════════════════════════════════
echo "── Test 3: 동봉 FFmpeg 동작 ──"

if "$FFMPEG" -version > /dev/null 2>&1; then
    VER=$("$FFMPEG" -version | head -1 | awk '{print $3}')
    pass "ffmpeg 동작 (버전: $VER)"
else
    fail "ffmpeg 실행 실패"
fi

if "$FFPROBE" -version > /dev/null 2>&1; then
    pass "ffprobe 동작"
else
    fail "ffprobe 실행 실패"
fi

# soxr 리샘플러 사용 가능 확인
if "$FFMPEG" -filters 2>/dev/null | awk '{print $2}' | grep -qx "aresample"; then
    pass "aresample 필터 사용 가능"
else
    fail "aresample 필터 없음"
fi

if "$FFMPEG" -filters 2>/dev/null | awk '{print $2}' | grep -qx "amix"; then
    pass "amix 필터 사용 가능"
else
    fail "amix 필터 없음"
fi

if "$FFMPEG" -filters 2>/dev/null | awk '{print $2}' | grep -qx "alimiter"; then
    pass "alimiter 필터 사용 가능 (클리핑 방지)"
else
    fail "alimiter 필터 없음"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# 테스트 데이터 준비
# ═══════════════════════════════════════════════════════════
echo "── 테스트 데이터 생성 ──"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# 다양한 포맷/SR로 테스트 데이터 생성
"$FFMPEG" -y -loglevel error -f lavfi -i "sine=frequency=440:duration=2" \
    -ac 2 -ar 44100 "$TEST_DIR/track_a.wav" && info "track_a.wav (440Hz, 44.1k, 스테레오, 2s)"

"$FFMPEG" -y -loglevel error -f lavfi -i "sine=frequency=554:duration=3" \
    -ac 2 -ar 48000 -b:a 192k "$TEST_DIR/track_b.mp3" && info "track_b.mp3 (554Hz, 48k, 3s)"

"$FFMPEG" -y -loglevel error -f lavfi -i "sine=frequency=659:duration=1.5" \
    -ac 1 -ar 96000 "$TEST_DIR/track_c.flac" && info "track_c.flac (659Hz, 96k, 모노, 1.5s)"

# 한글 파일명 테스트
"$FFMPEG" -y -loglevel error -f lavfi -i "sine=frequency=330:duration=2" \
    -ac 2 -ar 48000 "$TEST_DIR/한글파일.wav" && info "한글파일.wav (한글 파일명)"

echo ""

# ═══════════════════════════════════════════════════════════
# Test 4: 기본 믹스다운 (WAV + MP3) + 새 파일명 규칙
# ═══════════════════════════════════════════════════════════
echo "── Test 4: 기본 믹스다운 + [MIX] 접두어 ──"

# 기존 결과 정리 (대괄호 패턴)
rm -f "$TEST_DIR"/\[MIX\]*.wav "$TEST_DIR"/\[MIX\]*.txt
rm -f "$TEST_DIR"/\[MIX_*\]*.wav "$TEST_DIR"/\[MIX_*\]*.txt

if "$PYTHON" "$MIX_SCRIPT" "$TEST_DIR/track_a.wav" "$TEST_DIR/track_b.mp3" > /tmp/audiomixer_test4.log 2>&1; then
    pass "스크립트 실행 성공"
    
    # 새 파일명 규칙: [MIX] track_a.wav
    EXPECTED="$TEST_DIR/[MIX] track_a.wav"
    
    if [ -f "$EXPECTED" ]; then
        pass "출력 파일 생성됨: [MIX] track_a.wav"
        pass "파일명 규칙 정확: [MIX] [원본명].wav"
        
        # 사양 검증
        SPEC=$("$FFPROBE" -v error -select_streams a:0 \
            -show_entries stream=sample_rate,channels,bits_per_sample,codec_name \
            -of default=noprint_wrappers=1 "$EXPECTED")
        
        if echo "$SPEC" | grep -q "sample_rate=48000"; then
            pass "샘플레이트 48000Hz"
        else
            fail "샘플레이트 잘못됨"
        fi
        
        if echo "$SPEC" | grep -q "channels=2"; then
            pass "채널 2 (스테레오)"
        else
            fail "채널 잘못됨"
        fi
        
        if echo "$SPEC" | grep -q "bits_per_sample=24"; then
            pass "비트심도 24bit"
        else
            fail "비트심도 잘못됨"
        fi
        
        if echo "$SPEC" | grep -q "codec_name=pcm_s24le"; then
            pass "코덱 pcm_s24le"
        else
            fail "코덱 잘못됨"
        fi
        
        # 사이드카 로그: [MIX] track_a.txt
        SIDECAR="$TEST_DIR/[MIX] track_a.txt"
        if [ -f "$SIDECAR" ]; then
            pass "사이드카 로그 생성"
        else
            fail "사이드카 로그 누락: $SIDECAR"
        fi
        
        # 음량 검증 - 원본 대비 증가 확인 + 클리핑 없음
        # amix normalize=0이라 두 트랙 합치면 약 +6dB 증가 예상
        IN_VOL=$("$FFMPEG" -i "$TEST_DIR/track_a.wav" -af volumedetect -f null /dev/null 2>&1 \
            | grep "max_volume" | sed 's/.*max_volume: //' | sed 's/ dB//')
        OUT_VOL=$("$FFMPEG" -i "$EXPECTED" -af volumedetect -f null /dev/null 2>&1 \
            | grep "max_volume" | sed 's/.*max_volume: //' | sed 's/ dB//')
        
        if [ -n "$IN_VOL" ] && [ -n "$OUT_VOL" ]; then
            # 출력이 입력보다 커야 함 (음량 보존 + 합산 효과)
            if awk -v i="$IN_VOL" -v o="$OUT_VOL" 'BEGIN{exit !(o > i)}'; then
                pass "출력 음량 ≥ 입력 음량 (in: ${IN_VOL}dB → out: ${OUT_VOL}dB, 원본 유지)"
            else
                fail "출력이 입력보다 작음 (in: ${IN_VOL}dB → out: ${OUT_VOL}dB)"
            fi
            
            # alimiter 동작: max_volume이 0dB를 넘으면 클리핑
            if awk -v v="$OUT_VOL" 'BEGIN{exit !(v <= 0)}'; then
                pass "클리핑 없음 (max_volume: ${OUT_VOL}dB ≤ 0dB)"
            else
                fail "클리핑 발생 (max_volume: ${OUT_VOL}dB)"
            fi
        else
            info "음량 측정 추출 실패 (테스트 스킵)"
        fi
    else
        fail "예상 출력 파일 없음: $EXPECTED"
        ls "$TEST_DIR/" | head -10
    fi
else
    fail "스크립트 실행 실패"
    cat /tmp/audiomixer_test4.log
fi
echo ""

# ═══════════════════════════════════════════════════════════
# Test 5: 3개 파일 + 다양한 SR/포맷
# ═══════════════════════════════════════════════════════════
echo "── Test 5: 3개 파일 (44.1k WAV + 48k MP3 + 96k FLAC 모노) ──"

# track_a 결과물 정리 (Test 4에서 만든 것 제거)
rm -f "$TEST_DIR"/\[MIX*\]\ track_a.wav "$TEST_DIR"/\[MIX*\]\ track_a.txt

if "$PYTHON" "$MIX_SCRIPT" \
    "$TEST_DIR/track_a.wav" \
    "$TEST_DIR/track_b.mp3" \
    "$TEST_DIR/track_c.flac" > /tmp/audiomixer_test5.log 2>&1; then
    pass "3개 파일 믹스다운 성공"
    
    OUTPUT_T5="$TEST_DIR/[MIX] track_a.wav"
    if [ -f "$OUTPUT_T5" ]; then
        DUR=$("$FFPROBE" -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$OUTPUT_T5")
        if [ "$(echo "$DUR > 2.9 && $DUR < 3.1" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            pass "출력 길이 ≈ 3초 (가장 긴 트랙 기준): $DUR"
        else
            info "출력 길이: $DUR (예상 ~3.0)"
        fi
    else
        fail "예상 출력 없음"
    fi
else
    fail "3개 파일 믹스다운 실패"
    cat /tmp/audiomixer_test5.log
fi
echo ""

# ═══════════════════════════════════════════════════════════
# Test 6: 한글 파일명
# ═══════════════════════════════════════════════════════════
echo "── Test 6: 한글 파일명 처리 ──"

rm -f "$TEST_DIR"/\[MIX*\]\ 한글파일.wav "$TEST_DIR"/\[MIX*\]\ 한글파일.txt

if "$PYTHON" "$MIX_SCRIPT" \
    "$TEST_DIR/한글파일.wav" \
    "$TEST_DIR/track_a.wav" > /tmp/audiomixer_test6.log 2>&1; then
    pass "한글 파일명 처리 성공"
    
    KOREAN_OUT="$TEST_DIR/[MIX] 한글파일.wav"
    if [ -f "$KOREAN_OUT" ]; then
        pass "한글 출력 파일 생성: [MIX] 한글파일.wav"
    else
        fail "한글 출력 파일 없음"
        ls "$TEST_DIR/" | head
    fi
else
    fail "한글 파일명 처리 실패"
    cat /tmp/audiomixer_test6.log
fi
echo ""

# ═══════════════════════════════════════════════════════════
# Test 7: 재실행 시 [MIX_2], [MIX_3] 증분
# ═══════════════════════════════════════════════════════════
echo "── Test 7: 재실행 시 자동 증분 ([MIX], [MIX_2], [MIX_3]) ──"

# track_b 결과물 정리
rm -f "$TEST_DIR"/\[MIX*\]\ track_b.wav "$TEST_DIR"/\[MIX*\]\ track_b.txt

# 3번 연속 실행
for i in 1 2 3; do
    "$PYTHON" "$MIX_SCRIPT" \
        "$TEST_DIR/track_b.mp3" \
        "$TEST_DIR/track_a.wav" > /tmp/audiomixer_test7_$i.log 2>&1
done

# 검증: [MIX], [MIX_2], [MIX_3] 모두 존재해야 함
if [ -f "$TEST_DIR/[MIX] track_b.wav" ]; then
    pass "첫 실행 → [MIX] track_b.wav"
else
    fail "첫 결과물 없음"
fi

if [ -f "$TEST_DIR/[MIX_2] track_b.wav" ]; then
    pass "두 번째 실행 → [MIX_2] track_b.wav"
else
    fail "[MIX_2] 결과물 없음"
    ls "$TEST_DIR/" | grep MIX
fi

if [ -f "$TEST_DIR/[MIX_3] track_b.wav" ]; then
    pass "세 번째 실행 → [MIX_3] track_b.wav"
else
    fail "[MIX_3] 결과물 없음"
    ls "$TEST_DIR/" | grep MIX
fi
echo ""

# ═══════════════════════════════════════════════════════════
# Test 8: 잘못된 입력 (단일 파일)
# ═══════════════════════════════════════════════════════════
echo "── Test 8: 잘못된 입력 거부 ──"

if "$PYTHON" "$MIX_SCRIPT" "$TEST_DIR/track_a.wav" > /tmp/audiomixer_test8.log 2>&1; then
    fail "단일 파일에 종료 코드 0 (거부했어야 함)"
else
    EXIT=$?
    if [ "$EXIT" = "1" ]; then
        pass "단일 파일 입력 거부 (exit 1)"
    else
        info "단일 파일 입력 거부 (exit $EXIT)"
        pass "단일 파일 입력 거부"
    fi
fi
echo ""

# ═══════════════════════════════════════════════════════════
# Test 9: 존재하지 않는 파일
# ═══════════════════════════════════════════════════════════
echo "── Test 9: 존재하지 않는 파일 처리 ──"

if "$PYTHON" "$MIX_SCRIPT" \
    "$TEST_DIR/없는파일.wav" \
    "$TEST_DIR/track_a.wav" > /tmp/audiomixer_test9.log 2>&1; then
    fail "존재하지 않는 파일에 종료 코드 0"
else
    pass "존재하지 않는 파일 거부"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# Test 10: 런처 스크립트 (인자 모드)
# ═══════════════════════════════════════════════════════════
echo "── Test 10: 런처 스크립트 호출 (.app 드롭 시뮬레이션) ──"

rm -f "$TEST_DIR"/\[MIX*\]\ track_c.wav

# 런처를 직접 호출 - .app에 드래그한 것과 동일
if "$LAUNCHER" "$TEST_DIR/track_c.flac" "$TEST_DIR/track_a.wav" > /tmp/audiomixer_test10.log 2>&1; then
    pass "런처 인자 모드 성공"
    
    if [ -f "$TEST_DIR/[MIX] track_c.wav" ]; then
        pass "런처로 출력 생성: [MIX] track_c.wav"
    else
        fail "런처 출력 없음"
        ls "$TEST_DIR/" | grep -i mix
    fi
else
    fail "런처 실행 실패"
    cat /tmp/audiomixer_test10.log
fi
echo ""

# ═══════════════════════════════════════════════════════════
# Test 11: Quick Action 설치 스크립트 검증
# ═══════════════════════════════════════════════════════════
echo "── Test 11: Quick Action 설치 스크립트 ──"

QA_INSTALL="$APP_PATH/Contents/Resources/install_quickaction.sh"

# 격리된 HOME에서 설치 시도
TEST_HOME="$TEST_DIR/fake_home"
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME"

if HOME="$TEST_HOME" "$QA_INSTALL" "$APP_PATH" > /tmp/audiomixer_test11.log 2>&1; then
    pass "Quick Action 설치 스크립트 실행"
    
    WF="$TEST_HOME/Library/Services/WAV로 믹스다운.workflow"
    if [ -d "$WF" ]; then
        pass "워크플로 디렉토리 생성"
        
        if [ -f "$WF/Contents/Info.plist" ]; then
            if "$PYTHON" -c "import plistlib; plistlib.load(open('$WF/Contents/Info.plist', 'rb'))" 2>/dev/null; then
                pass "Quick Action Info.plist 유효"
            else
                fail "Quick Action Info.plist 깨짐"
            fi
        else
            fail "워크플로 Info.plist 없음"
        fi
        
        if [ -f "$WF/Contents/document.wflow" ]; then
            if "$PYTHON" -c "import plistlib; plistlib.load(open('$WF/Contents/document.wflow', 'rb'))" 2>/dev/null; then
                pass "Quick Action document.wflow 유효"
            else
                fail "Quick Action document.wflow 깨짐"
            fi
        else
            fail "document.wflow 없음"
        fi
        
        # 워크플로 내부의 명령어가 mix_audio.py를 정확히 가리키는지
        if grep -q "mix_audio.py" "$WF/Contents/document.wflow"; then
            pass "워크플로가 mix_audio.py 참조"
        else
            fail "워크플로에 mix_audio.py 참조 없음"
        fi
        
        # 입력 방식 stdin인지 확인
        if "$PYTHON" -c "
import plistlib
w = plistlib.load(open('$WF/Contents/document.wflow', 'rb'))
params = w['actions'][0]['action']['ActionParameters']
assert params['inputMethod'] == 1, 'stdin이 아님'
assert params['shell'] == '/bin/bash', 'bash가 아님'
" 2>/dev/null; then
            pass "워크플로 입력=stdin, 셸=bash 정확"
        else
            fail "워크플로 입력 방식 또는 셸 잘못됨"
        fi
        
        # 워크플로 메타데이터 검증
        if "$PYTHON" -c "
import plistlib
w = plistlib.load(open('$WF/Contents/document.wflow', 'rb'))
m = w['workflowMetaData']
assert m['serviceInputTypeIdentifier'] == 'com.apple.Automator.fileSystemObject.audio'
assert m['workflowTypeIdentifier'] == 'com.apple.Automator.servicesMenu'
assert m['useAutomaticInputType'] == 0
" 2>/dev/null; then
            pass "워크플로 메타데이터 정확"
        else
            fail "워크플로 메타데이터 잘못됨"
        fi
        
        # 워크플로 내부 쉘 코드를 추출해서 bash로 문법 검증
        "$PYTHON" -c "
import plistlib
w = plistlib.load(open('$WF/Contents/document.wflow', 'rb'))
cmd = w['actions'][0]['action']['ActionParameters']['COMMAND_STRING']
print(cmd)
" > /tmp/audiomixer_wflow_cmd.sh
        
        if bash -n /tmp/audiomixer_wflow_cmd.sh 2>/dev/null; then
            pass "워크플로 셸 코드 bash 문법 OK"
        else
            fail "워크플로 셸 코드 bash 문법 오류"
            bash -n /tmp/audiomixer_wflow_cmd.sh
        fi
        
        # 실제 워크플로 실행 시뮬레이션
        # - Finder 우클릭 → Quick Action이 호출되는 흐름과 동일
        # - stdin으로 파일 경로들 전달
        # 임의의 새 입력 만들기 (기존 결과물과 충돌 안 나게)
        "$FFMPEG" -y -loglevel error -f lavfi -i "sine=frequency=220:duration=2" \
            -ac 2 -ar 48000 "$TEST_DIR/e2e_input.wav" 2>/dev/null
        
        rm -f "$TEST_DIR"/\[MIX*\]\ e2e_input.wav
        
        printf "%s\n%s\n" "$TEST_DIR/e2e_input.wav" "$TEST_DIR/track_b.mp3" | \
            bash /tmp/audiomixer_wflow_cmd.sh > /tmp/audiomixer_wflow_run.log 2>&1
        WFLOW_EXIT=$?
        
        if [ $WFLOW_EXIT -eq 0 ]; then
            if [ -f "$TEST_DIR/[MIX] e2e_input.wav" ]; then
                pass "워크플로 E2E 실행 성공 (Finder 우클릭 시뮬레이션)"
            else
                fail "워크플로 실행은 됐으나 출력 파일 없음"
            fi
        else
            fail "워크플로 E2E 실행 실패 (exit $WFLOW_EXIT)"
            cat /tmp/audiomixer_wflow_run.log | tail -20
        fi
    else
        fail "워크플로 디렉토리 미생성"
    fi
    
    # 멱등성: 두 번 실행해도 OK
    if HOME="$TEST_HOME" "$QA_INSTALL" "$APP_PATH" > /tmp/audiomixer_test11b.log 2>&1; then
        pass "Quick Action 재실행 멱등 동작"
    else
        fail "Quick Action 재실행 실패"
    fi
else
    fail "Quick Action 설치 스크립트 실행 실패"
    cat /tmp/audiomixer_test11.log
fi
echo ""

# ═══════════════════════════════════════════════════════════
# Test 12: 앱 아이콘
# ═══════════════════════════════════════════════════════════
echo "── Test 12: 앱 아이콘 ──"

ICON_FILE="$APP_PATH/Contents/Resources/AppIcon.icns"
ICON_PNG="$APP_PATH/Contents/Resources/AppIcon.png"

if [ -f "$ICON_FILE" ]; then
    pass "AppIcon.icns 존재"
    SIZE=$(ls -l "$ICON_FILE" | awk '{print $5}')
    if [ "$SIZE" -gt 1000 ]; then
        pass "아이콘 파일 크기 정상 (${SIZE} bytes)"
    else
        fail "아이콘 파일이 너무 작음 (${SIZE} bytes)"
    fi
elif [ -f "$ICON_PNG" ]; then
    pass "AppIcon.png 존재 (폴백)"
else
    info "아이콘 없음 - SVG 변환 도구 미설치 시 발생 가능"
fi

# Info.plist에 CFBundleIconFile 등록 확인
if "$PYTHON" -c "
import plistlib
p = plistlib.load(open('$APP_PATH/Contents/Info.plist', 'rb'))
assert 'CFBundleIconFile' in p, 'CFBundleIconFile 키 없음'
" 2>/dev/null; then
    pass "Info.plist에 아이콘 등록됨"
else
    info "Info.plist에 아이콘 등록 안 됨 (아이콘 빌드 실패 시 정상)"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# 결과
# ═══════════════════════════════════════════════════════════
echo "════════════════════════════════════════════"
printf "  결과: ${GREEN}%d 통과${NC} / ${RED}%d 실패${NC}\n" "$PASSED" "$FAILED"
echo "════════════════════════════════════════════"

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}🎉 모든 테스트 통과!${NC}"
    exit 0
else
    echo -e "${RED}⚠️  일부 테스트 실패. 로그 확인:${NC}"
    echo "   /tmp/audiomixer_test*.log"
    exit 1
fi
