#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Audio Mixdown Engine
- 여러 오디오 파일을 24bit/48kHz WAV로 amix 믹스다운
- 동봉 FFmpeg를 우선 사용 (스크립트와 같은 디렉토리)

사용법:
    mix_audio.py <file1> <file2> [file3 ...]

종료 코드:
    0: 성공
    1: 입력 검증 실패
    2: FFmpeg 누락
    3: 렌더링 실패
"""

import sys
import os
import subprocess
import json
import shutil
import datetime
from pathlib import Path

# ─────────────────────────────────────────────────────────────
# 설정
# ─────────────────────────────────────────────────────────────
TARGET_SAMPLE_RATE = 48000
TARGET_BIT_DEPTH = 24
TARGET_CHANNELS = 2
OUTPUT_PREFIX = "[MIX]"  # 대괄호 접두어 - Finder 정렬 시 최상단, 원본과 명확히 구분
SUPPORTED_EXT = {".wav", ".mp3", ".flac", ".aiff", ".aif",
                 ".m4a", ".aac", ".ogg", ".opus", ".wma",
                 ".caf", ".alac"}


# ─────────────────────────────────────────────────────────────
# FFmpeg 경로 탐색
# ─────────────────────────────────────────────────────────────
def find_ffmpeg():
    """
    FFmpeg/ffprobe 경로를 찾는다. 우선순위:
    1. 스크립트와 같은 디렉토리 (.app 동봉본)
    2. 환경변수 FFMPEG_PATH
    3. 시스템 PATH
    
    Returns:
        (ffmpeg_path, ffprobe_path) 튜플
    """
    script_dir = Path(__file__).parent.resolve()
    
    # 1순위: 동봉본
    bundled_ffmpeg = script_dir / "ffmpeg"
    bundled_ffprobe = script_dir / "ffprobe"
    if bundled_ffmpeg.is_file() and os.access(bundled_ffmpeg, os.X_OK):
        if bundled_ffprobe.is_file() and os.access(bundled_ffprobe, os.X_OK):
            return str(bundled_ffmpeg), str(bundled_ffprobe)
    
    # 2순위: 환경변수
    env_ffmpeg = os.environ.get("FFMPEG_PATH")
    if env_ffmpeg and Path(env_ffmpeg).is_file():
        env_ffprobe = os.environ.get("FFPROBE_PATH", env_ffmpeg.replace("ffmpeg", "ffprobe"))
        if Path(env_ffprobe).is_file():
            return env_ffmpeg, env_ffprobe
    
    # 3순위: 시스템 PATH + 알려진 경로
    extra_paths = ["/opt/homebrew/bin", "/usr/local/bin"]
    old_path = os.environ.get("PATH", "")
    os.environ["PATH"] = ":".join(extra_paths) + ":" + old_path
    try:
        ffmpeg = shutil.which("ffmpeg")
        ffprobe = shutil.which("ffprobe")
        if ffmpeg and ffprobe:
            return ffmpeg, ffprobe
    finally:
        os.environ["PATH"] = old_path
    
    raise FileNotFoundError(
        "FFmpeg를 찾을 수 없습니다.\n"
        ".app이 손상되었거나 권한이 잘못되었을 수 있습니다."
    )


# ─────────────────────────────────────────────────────────────
# macOS 알림
# ─────────────────────────────────────────────────────────────
def notify(title, message, sound="Glass"):
    """알림 센터로 알림 전송."""
    try:
        safe_title = str(title).replace('"', '\\"').replace('\\', '\\\\')
        safe_msg = str(message).replace('"', '\\"').replace('\\', '\\\\')
        script = (
            f'display notification "{safe_msg}" '
            f'with title "{safe_title}" sound name "{sound}"'
        )
        subprocess.run(
            ["osascript", "-e", script],
            check=False, capture_output=True, timeout=5
        )
    except Exception:
        pass  # 알림 실패는 무시


# ─────────────────────────────────────────────────────────────
# 입력 검증
# ─────────────────────────────────────────────────────────────
def validate_inputs(paths):
    """입력 파일 검증."""
    if not paths:
        raise ValueError("입력 파일이 없습니다.")
    
    valid = []
    skipped = []
    for p in paths:
        path = Path(p).expanduser()
        try:
            path = path.resolve(strict=True)
        except (OSError, RuntimeError):
            skipped.append(f"{p} (파일 없음)")
            continue
        
        if not path.is_file():
            skipped.append(f"{path.name} (디렉토리)")
            continue
        if path.suffix.lower() not in SUPPORTED_EXT:
            skipped.append(f"{path.name} (지원 안 함)")
            continue
        valid.append(path)
    
    if skipped:
        for s in skipped:
            print(f"⚠️  건너뜀: {s}", flush=True)
    
    if len(valid) < 2:
        raise ValueError(
            f"믹스다운하려면 오디오 파일이 2개 이상 필요합니다 (현재 {len(valid)}개)."
        )
    return valid


# ─────────────────────────────────────────────────────────────
# ffprobe 메타데이터
# ─────────────────────────────────────────────────────────────
def probe_audio(ffprobe, file):
    """ffprobe로 오디오 메타데이터 추출. 실패 시 빈 dict."""
    try:
        cmd = [
            ffprobe, "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=sample_rate,channels,duration,codec_name",
            "-of", "json",
            str(file),
        ]
        result = subprocess.run(
            cmd, capture_output=True, text=True,
            check=True, timeout=30
        )
        data = json.loads(result.stdout)
        streams = data.get("streams", [])
        return streams[0] if streams else {}
    except Exception as e:
        print(f"⚠️  프로빙 실패 ({file.name}): {e}", flush=True)
        return {}


# ─────────────────────────────────────────────────────────────
# 출력 경로 결정
# ─────────────────────────────────────────────────────────────
def resolve_output_path(first_file):
    """
    출력 파일 경로 결정.
    
    파일명 규칙:
    - 첫 번째: [MIX] 원본파일명.wav
    - 재실행: [MIX_2] 원본파일명.wav, [MIX_3] 원본파일명.wav, ...
    
    왜 이렇게 짰는지(Why):
    - 대괄호 접두어로 Finder 정렬 시 결과물이 상단에 모임
    - 원본 파일명을 그대로 보존해 추적성 유지
    - 재실행 시 자동 증분으로 절대 덮어쓰지 않음
    """
    original_name = first_file.name  # 확장자 포함한 원본 이름
    out_dir = first_file.parent
    
    # 출력은 항상 .wav
    out_stem = first_file.stem  # 확장자 제외
    
    # 첫 시도: [MIX] 원본.wav
    candidate = out_dir / f"{OUTPUT_PREFIX} {out_stem}.wav"
    if not candidate.exists():
        return candidate
    
    # 재실행: [MIX_2], [MIX_3], ...
    for i in range(2, 1000):
        candidate = out_dir / f"[MIX_{i}] {out_stem}.wav"
        if not candidate.exists():
            return candidate
    raise RuntimeError("출력 파일명 생성 실패 (1000회 초과)")


# ─────────────────────────────────────────────────────────────
# FFmpeg 명령어 구성
# ─────────────────────────────────────────────────────────────
def build_ffmpeg_command(ffmpeg, inputs, output):
    """
    amix 필터로 믹스다운 명령어 생성.
    
    핵심 결정:
    - amix normalize=0: 원본 음량 그대로 합산 (1/N 자동 감쇠 비활성화)
      → 사용자가 듣기에 자연스러운 레벨감 유지
    - alimiter: 클리핑 방지용 소프트 리미터 (-0.3dBFS 천장)
      → 합산 후 신호가 1.0을 넘어가도 자동으로 부드럽게 압축
    - duration=longest: 가장 긴 트랙 기준으로 길이 결정
    - SoX 리샘플러로 고품질 SR 변환
    """
    cmd = [ffmpeg, "-y", "-hide_banner", "-loglevel", "warning", "-stats"]
    
    for f in inputs:
        cmd += ["-i", str(f)]
    
    n = len(inputs)
    filter_parts = []
    labels = []
    for i in range(n):
        label = f"a{i}"
        filter_parts.append(
            f"[{i}:a]aresample={TARGET_SAMPLE_RATE}:resampler=soxr,"
            f"aformat=sample_fmts=fltp:channel_layouts=stereo[{label}]"
        )
        labels.append(f"[{label}]")
    
    amix_in = "".join(labels)
    # amix normalize=0: 원본 레벨 유지
    # → alimiter로 클리핑 방지 (limit=0.97 ≈ -0.3dBFS)
    # → attack/release는 음악적인 자연스러움을 위한 적당한 값
    filter_parts.append(
        f"{amix_in}amix=inputs={n}:duration=longest:"
        f"dropout_transition=2:normalize=0,"
        f"alimiter=limit=0.97:attack=5:release=50:level=disabled[mix]"
    )
    filter_complex = ";".join(filter_parts)
    
    cmd += [
        "-filter_complex", filter_complex,
        "-map", "[mix]",
        "-ac", str(TARGET_CHANNELS),
        "-ar", str(TARGET_SAMPLE_RATE),
        "-c:a", "pcm_s24le",
        "-rf64", "auto",
        str(output),
    ]
    return cmd


# ─────────────────────────────────────────────────────────────
# 사이드카 로그
# ─────────────────────────────────────────────────────────────
def write_sidecar_log(output, inputs, probes, elapsed, ffmpeg_path):
    """렌더링 정보 .txt 로그 작성."""
    try:
        log_path = output.with_suffix(".txt")
        lines = [
            "# Audio Mixdown Log",
            f"생성: {datetime.datetime.now().isoformat(timespec='seconds')}",
            f"출력: {output.name}",
            f"포맷: {TARGET_BIT_DEPTH}bit / {TARGET_SAMPLE_RATE}Hz / {TARGET_CHANNELS}ch PCM WAV",
            f"렌더 시간: {elapsed:.2f}초",
            f"FFmpeg: {ffmpeg_path}",
            f"입력 파일 수: {len(inputs)}",
            "",
            "## 입력 파일",
        ]
        for f, p in zip(inputs, probes):
            sr = p.get("sample_rate", "?")
            ch = p.get("channels", "?")
            dur = p.get("duration", "?")
            codec = p.get("codec_name", "?")
            lines.append(f"- {f.name}  ({codec}, {sr}Hz, {ch}ch, {dur}s)")
        log_path.write_text("\n".join(lines), encoding="utf-8")
    except Exception as e:
        print(f"⚠️  로그 작성 실패: {e}", flush=True)


# ─────────────────────────────────────────────────────────────
# 메인
# ─────────────────────────────────────────────────────────────
def main(argv):
    start = datetime.datetime.now()
    
    # FFmpeg 탐색
    try:
        ffmpeg, ffprobe = find_ffmpeg()
        print(f"🔧 FFmpeg: {ffmpeg}", flush=True)
    except FileNotFoundError as e:
        print(f"❌ {e}", flush=True)
        notify("Audio Mixer 오류", "FFmpeg를 찾을 수 없습니다", "Basso")
        return 2
    
    # 입력 검증
    try:
        inputs = validate_inputs(argv)
    except ValueError as e:
        print(f"❌ {e}", flush=True)
        notify("Audio Mixer 오류", str(e), "Basso")
        return 1
    
    print(f"🎧 입력 {len(inputs)}개:", flush=True)
    for f in inputs:
        print(f"   - {f.name}", flush=True)
    
    # 프로빙
    probes = [probe_audio(ffprobe, f) for f in inputs]
    
    # 출력 경로
    try:
        output = resolve_output_path(inputs[0])
    except RuntimeError as e:
        print(f"❌ {e}", flush=True)
        notify("Audio Mixer 오류", str(e), "Basso")
        return 3
    
    print(f"📦 출력: {output}", flush=True)
    
    # 렌더링
    cmd = build_ffmpeg_command(ffmpeg, inputs, output)
    print("⚙️  렌더링...", flush=True)
    
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as e:
        msg = f"FFmpeg 실패 (exit {e.returncode})"
        print(f"❌ {msg}", flush=True)
        notify("Audio Mixer 실패", msg, "Basso")
        if output.exists():
            try:
                output.unlink()
            except OSError:
                pass
        return 3
    except FileNotFoundError:
        msg = "FFmpeg 실행 실패"
        print(f"❌ {msg}", flush=True)
        notify("Audio Mixer 오류", msg, "Basso")
        return 2
    
    elapsed = (datetime.datetime.now() - start).total_seconds()
    write_sidecar_log(output, inputs, probes, elapsed, ffmpeg)
    
    size_mb = output.stat().st_size / (1024 * 1024)
    msg = f"{output.name} ({size_mb:.1f}MB, {elapsed:.1f}s)"
    print(f"✅ 완료: {msg}", flush=True)
    notify("믹스다운 완료 🎉", msg, "Glass")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print("\n중단됨", flush=True)
        sys.exit(130)
    except Exception as e:
        print(f"❌ 예상치 못한 오류: {e}", flush=True)
        notify("Audio Mixer 오류", f"예상치 못한 오류: {type(e).__name__}", "Basso")
        sys.exit(99)
