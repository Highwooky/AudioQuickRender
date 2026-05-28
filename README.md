# 🎧 Audio Mixer for macOS

Finder 우클릭만으로 여러 오디오 파일을 **24bit / 48kHz Stereo WAV**로 즉시 믹스다운하는 도구.
**FFmpeg 완전 동봉** — 별도 설치 없이 폐쇄망에서도 동작합니다.

## ✨ 특징

- 🖱️ **Finder 우클릭 → 즉시 실행** (앱 안 거침)
- 📦 **FFmpeg 완전 동봉** — 외부 의존성 0
- 📐 **24-bit / 48,000 Hz / Stereo PCM** 정확 출력
- 🎵 WAV / MP3 / FLAC / AIFF / M4A / AAC / OGG 자동 디코딩
- 🔊 **원본 음량 유지** + 클리핑 방지 (alimiter 소프트 리미터)
- 📝 결과 파일명: `[MIX] 원본파일명.wav` (재실행 시 `[MIX_2]`, `[MIX_3]`)
- 🌏 한글 파일명 안전 처리
- 🎨 모던 디자인 아이콘
- 🔔 macOS 알림 센터 연동

## 📥 설치 (한 번만)

1. [Releases](../../releases/latest)에서 최신 ZIP 다운로드
2. 압축 풀기
3. `Audio Mixer.app`을 `/응용 프로그램`으로 드래그
4. **첫 실행**: 우클릭 → 열기 (Apple 서명 우회, 1회만)
5. 안내 다이얼로그 → 자동으로 시스템 설정 열림
6. **개인정보 보호 및 보안 → 확장 프로그램 → Finder** 에서 "WAV로 믹스다운" 켜기 ⚠️ **이 단계 필수!**

> ⚠️ **macOS Sequoia (15.0+)**: 빠른 동작은 보안 정책상 사용자가 직접 활성화해야 합니다.
> 이전 macOS는 자동 등록되지만, Sequoia 이상은 위 6번 단계가 필수입니다.

## 🎬 사용법

### ⭐ 추천: Finder 우클릭

오디오 파일 2개 이상 선택 → 우클릭 → **빠른 동작** → **WAV로 믹스다운**

> 결과물이 같은 폴더에 **즉시** 생성됩니다. 앱 별도 실행 불필요.

### 대안: 파일 드롭

오디오 파일들을 `Audio Mixer.app` 위로 드래그.

### 대안: 더블클릭

`Audio Mixer.app` 더블클릭 → 파일 선택 다이얼로그.

## 📋 출력 사양

| 항목 | 값 |
|---|---|
| 위치 | 첫 입력 파일과 같은 폴더 |
| 이름 | `[MIX] 원본파일명.wav` (재실행 시 `[MIX_2]`, `[MIX_3]` ...) |
| 샘플레이트 | 48,000 Hz |
| 비트심도 | 24-bit PCM |
| 채널 | 2 (Stereo) |
| 길이 | 가장 긴 입력 트랙 기준 |
| 음량 | **원본 그대로** (amix normalize=0) |
| 클리핑 | **alimiter -0.3dBFS 천장으로 자동 방지** |

**파일명 예시**:
- `vocal.wav` + `drum.mp3` → `[MIX] vocal.wav`
- 같은 파일들 다시 믹스 → `[MIX_2] vocal.wav`

## 🔊 음량 처리

이전 버전 대비 약 **+6dB 더 큰 음량**:

```
amix normalize=0     ← 원본 음량 그대로 합산
        ↓
alimiter limit=0.97  ← -0.3dBFS 천장에서 클리핑 자동 차단
        ↓
24-bit PCM WAV
```

소프트 리미터가 lookahead 방식으로 동작하여 자연스러운 압축. 평소 들리는 음량을 보존하면서도 디지털 클리핑을 완벽 방지합니다.

## 🏗️ 아키텍처

```
Audio Mixer.app/
├── Contents/
│   ├── Info.plist                       (드롭/더블클릭)
│   ├── MacOS/AudioMixer                  (Bash 런처)
│   └── Resources/
│       ├── ffmpeg                       (Apple Silicon 정적 빌드)
│       ├── ffprobe
│       ├── mix_audio.py                 (Python 엔진)
│       ├── install_quickaction.sh        (Quick Action 자동 설치)
│       └── AppIcon.icns                 (앱 아이콘)
        ↓ 첫 실행 시
~/Library/Services/WAV로 믹스다운.workflow  (Finder 우클릭 처리)
        ↓
시스템 설정에서 사용자가 활성화 (Sequoia 필수)
```

## 🐛 트러블슈팅

로그: `/tmp/audiomixer.log`

```bash
cat /tmp/audiomixer.log
```

| 증상 | 해결 |
|---|---|
| "확인되지 않은 개발자" | 첫 실행 시 우클릭 → 열기 |
| **우클릭 메뉴에 없음 (Sequoia)** | **시스템 설정 → 개인정보 보호 및 보안 → 확장 프로그램 → Finder → "WAV로 믹스다운" 켜기** |
| 우클릭 메뉴에 없음 (이전 버전) | 시스템 설정 → 키보드 → 키보드 단축키 → 서비스 |
| 우클릭은 보이는데 실행 안 됨 | 앱을 한 번 직접 실행 (Quick Action 재설치) |
| 음량 너무 작음 | 이 버전은 normalize=0이라 원본 음량 유지. 더 작다면 입력이 작은 것 |

## 🏗️ 빌드 (개발자용)

```bash
git clone <repo>
cd audio-mixer-mac

# FFmpeg 정적 빌드 다운로드
./scripts/download_ffmpeg.sh

# 아이콘 빌드 (선택)
./scripts/build_icon.sh

# .app 빌드 (아이콘 자동 통합)
./scripts/build_app.sh

# 통합 테스트 (46종)
./tests/integration_test.sh
```

## 📜 라이선스

이 프로젝트: MIT
FFmpeg: LGPL/GPL (evermeet.cx 빌드는 LGPL)
