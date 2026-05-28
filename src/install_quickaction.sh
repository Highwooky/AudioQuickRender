#!/bin/bash
# Quick Action 자동 설치 + 활성화 안내
# - .app 첫 실행 시 ~/Library/Services/에 워크플로 설치
# - 사용자에게 시스템 설정에서 활성화 안내 (macOS 15 Sequoia 필수 단계)

set -eu

APP_BUNDLE="${1:-}"
if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ .app 번들 경로가 필요합니다"
    exit 1
fi

RESOURCES="$APP_BUNDLE/Contents/Resources"
SERVICES_DIR="$HOME/Library/Services"
WORKFLOW_NAME="WAV로 믹스다운.workflow"
WF_PATH="$SERVICES_DIR/$WORKFLOW_NAME"

# 마커 파일로 첫 설치 여부 추적 (활성화 안내는 첫 설치 때만)
FIRST_INSTALL_MARKER="$HOME/Library/Application Support/AudioMixer/.first_install_done"
mkdir -p "$(dirname "$FIRST_INSTALL_MARKER")"

INSTALLED_MARKER="$WF_PATH/.installed_from_app"
CURRENT_MARKER_VALUE="$APP_BUNDLE"

# 같은 위치의 .app으로 이미 설치되어 있으면 스킵
if [ -f "$INSTALLED_MARKER" ]; then
    INSTALLED_PATH=$(cat "$INSTALLED_MARKER" 2>/dev/null || echo "")
    if [ "$INSTALLED_PATH" = "$CURRENT_MARKER_VALUE" ]; then
        echo "✅ Quick Action 이미 설치됨"
        exit 0
    fi
fi

echo "📥 Quick Action 설치 중..."

mkdir -p "$SERVICES_DIR"
rm -rf "$WF_PATH"
mkdir -p "$WF_PATH/Contents"

gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        python3 -c "import uuid; print(str(uuid.uuid4()).upper())"
    fi
}

# ─── Info.plist ──────────────────────────────────────────────
cat > "$WF_PATH/Contents/Info.plist" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>WAV로 믹스다운</string>
            </dict>
            <key>NSMessage</key>
            <string>runWorkflowAsService</string>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.audio</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST_EOF

# ─── document.wflow ─────────────────────────────────────────
# Quick Action이 셸 스크립트를 직접 실행 (.app 안 거침)
# - inputMethod=1: stdin으로 파일 경로 받음
# - shell=/bin/bash: bash 명시
# - 모든 XML special character는 entity로 escape (&, <, >)
cat > "$WF_PATH/Contents/document.wflow" << WFLOW_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AMApplicationBuild</key><string>492</string>
    <key>AMApplicationVersion</key><string>2.10</string>
    <key>AMDocumentVersion</key><string>2</string>
    <key>actions</key>
    <array>
        <dict>
            <key>action</key>
            <dict>
                <key>AMAccepts</key>
                <dict>
                    <key>Container</key><string>List</string>
                    <key>Optional</key><true/>
                    <key>Types</key>
                    <array><string>com.apple.cocoa.path</string></array>
                </dict>
                <key>AMActionVersion</key><string>2.0.3</string>
                <key>AMParameterProperties</key><dict/>
                <key>AMProvides</key>
                <dict>
                    <key>Container</key><string>List</string>
                    <key>Types</key>
                    <array><string>com.apple.cocoa.string</string></array>
                </dict>
                <key>ActionBundlePath</key>
                <string>/System/Library/Automator/Run Shell Script.action</string>
                <key>ActionName</key><string>Run Shell Script</string>
                <key>ActionParameters</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <string>export FFMPEG_PATH="$RESOURCES/ffmpeg"
export FFPROBE_PATH="$RESOURCES/ffprobe"

LOG="/tmp/audiomixer.log"
echo "=== \$(date) === Quick Action 실행" &gt;&gt; "\$LOG"

files=()
while IFS= read -r line; do
    [ -n "\$line" ] &amp;&amp; files+=("\$line")
done

echo "수신된 파일 수: \${#files[@]}" &gt;&gt; "\$LOG"
for f in "\${files[@]}"; do
    echo "  - \$f" &gt;&gt; "\$LOG"
done

chmod +x "$RESOURCES/ffmpeg" "$RESOURCES/ffprobe" "$RESOURCES/mix_audio.py" 2&gt;/dev/null || true

/usr/bin/python3 "$RESOURCES/mix_audio.py" "\${files[@]}" &gt;&gt; "\$LOG" 2&gt;&amp;1
EXIT_CODE=\$?
echo "종료 코드: \$EXIT_CODE" &gt;&gt; "\$LOG"
echo "" &gt;&gt; "\$LOG"

if [ \$EXIT_CODE -ne 0 ]; then
    /usr/bin/osascript -e "display dialog \"믹스다운 실패 (코드 \$EXIT_CODE)\\n\\n로그 확인: tail /tmp/audiomixer.log\" buttons {\"확인\"} with icon stop with title \"Audio Mixer\"" &gt;/dev/null 2&gt;&amp;1 || true
fi

exit \$EXIT_CODE
</string>
                    <key>CheckedForUserDefaultShell</key><true/>
                    <key>inputMethod</key><integer>1</integer>
                    <key>shell</key><string>/bin/bash</string>
                </dict>
                <key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
                <key>CFBundleVersion</key><string>2.0.3</string>
                <key>CanShowSelectedItemsWhenRun</key><false/>
                <key>CanShowWhenRun</key><true/>
                <key>Class Name</key><string>RunShellScriptAction</string>
                <key>UUID</key><string>$(gen_uuid)</string>
            </dict>
            <key>isViewVisible</key><integer>1</integer>
        </dict>
    </array>
    <key>connectors</key><dict/>
    <key>workflowMetaData</key>
    <dict>
        <key>inputTypeIdentifier</key>
        <string>com.apple.Automator.fileSystemObject.audio</string>
        <key>outputTypeIdentifier</key>
        <string>com.apple.Automator.nothing</string>
        <key>presentationMode</key><integer>15</integer>
        <key>processesInput</key><integer>0</integer>
        <key>serviceInputTypeIdentifier</key>
        <string>com.apple.Automator.fileSystemObject.audio</string>
        <key>serviceOutputTypeIdentifier</key>
        <string>com.apple.Automator.nothing</string>
        <key>serviceProcessesInput</key><integer>0</integer>
        <key>useAutomaticInputType</key><integer>0</integer>
        <key>workflowTypeIdentifier</key>
        <string>com.apple.Automator.servicesMenu</string>
    </dict>
</dict>
</plist>
WFLOW_EOF

# 설치 마커
echo "$CURRENT_MARKER_VALUE" > "$INSTALLED_MARKER"

# Services 캐시 새로고침 (중요!)
/System/Library/CoreServices/pbs -flush 2>/dev/null || true

# Launch Services 등록 (Sequoia에서 추가로 필요)
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f "$WF_PATH" 2>/dev/null || true

echo "✅ Quick Action 설치 완료: $WF_PATH"

# 첫 설치인 경우: 활성화 안내
if [ ! -f "$FIRST_INSTALL_MARKER" ]; then
    echo "📢 첫 설치 - 활성화 안내 표시"
    
    # 다이얼로그 표시 + 시스템 설정 자동 열기
    /usr/bin/osascript <<'APPLESCRIPT' 2>/dev/null || true
set msg to "Audio Mixer가 설치되었습니다! 🎉" & return & return ¬
    & "마지막 단계: macOS Sequoia에서는 빠른 동작을 수동으로 활성화해야 합니다." & return & return ¬
    & "곧 열릴 시스템 설정 창에서:" & return ¬
    & "1. 왼쪽 사이드바에서 'Audio Mixer' 찾기" & return ¬
    & "2. 'WAV로 믹스다운' 항목 켜기 (토글)" & return & return ¬
    & "이후 Finder에서 오디오 파일 우클릭 → '빠른 동작'에 메뉴가 나타납니다."

display dialog msg with title "Audio Mixer 설치 완료" buttons {"확인"} default button "확인" with icon note
APPLESCRIPT
    
    # 시스템 설정의 확장 프로그램(Extensions) 페이지 열기
    # macOS 15+: System Settings > 개인정보 보호 및 보안 > 확장 프로그램 > Finder
    /usr/bin/open "x-apple.systempreferences:com.apple.ExtensionsPreferences" 2>/dev/null || \
    /usr/bin/open "/System/Library/PreferencePanes/Extensions.prefPane" 2>/dev/null || \
    /usr/bin/open "x-apple.systempreferences:" 2>/dev/null || true
    
    # 마커 저장 (다음부터는 안내 안 함)
    touch "$FIRST_INSTALL_MARKER"
fi

exit 0
