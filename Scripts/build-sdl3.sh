#!/bin/bash
#
# 마인크래프트 26.3+ 용 SDL3 빌드 (iOS arm64 · Android arm64-v8a).
#
# ⚠️ 왜 필요한가
#    26.3 부터 마인크래프트는 GLFW 를 **완전히 버리고** SDL3 로 갔다. 26.3 의
#    version.json 에 glfw 라이브러리가 하나도 없고 org.lwjgl:lwjgl-sdl:3.4.3 이 들어온다.
#    클라이언트 jar 을 뜯어 세어 보면 SDL 진입점 84개를 27개 클래스가 쓴다.
#
# ⚠️ 좋은 소식: **JNI 글루를 만들 필요가 없다.**
#    lwjgl-sdl 의 natives jar 을 열어 보면 들어 있는 건 libSDL3.so 하나뿐이고,
#    바인딩은 전부 `JNI.invokeP*` + 함수 포인터다. GLFW 때처럼 자바 쪽을 재구현하거나
#    liblwjgl_glfw 를 따로 만들 이유가 없다 — SDL3 본체만 있으면 된다.
#
# ⚠️ 그리고 GLFW 와 달리 SDL3 는 **모바일 백엔드를 원래 갖고 있다**
#    (src/video/uikit · src/video/android). 우리가 창·입력을 통째로 재구현했던
#    이유가 GLFW 에 그게 없어서였는데, 여기서는 상류가 이미 지원한다.
#
# ⚠️ 다만 붙이는 일은 플랫폼마다 다르다 — 이 스크립트는 **본체를 만들 뿐**이다:
#      iOS     SDL_PROP_WINDOW_CREATE_* 에 UIKit 뷰 포인터가 없어서(Cocoa 만 있다)
#              우리 뷰를 넘길 공식 경로가 없다. GL 도 EAGL 경로뿐이라
#              ANGLE/EGL 위에 얹은 MobileGlues 와 바로 맞물리지 않는다.
#              → SDL 이 창을 소유하게 하고 GL 만 우리가 대는
#                (SDL_PROP_WINDOW_CREATE_EXTERNAL_GRAPHICS_CONTEXT_BOOLEAN) 방향이 유력하다.
#      Android EGL 이 네이티브라 GL 경로가 우리 렌더러들과 같은 토대를 쓴다.
#              SDL 의 Activity/Surface 와 우리 것을 맞추는 일만 남는다.
#
# 사용법:  ./Scripts/build-sdl3.sh [ios|android|all]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-all}"

REPO="https://github.com/libsdl-org/SDL.git"
# ⚠️ main 을 쓰지 않는다. lwjgl-sdl 3.4.3 이 기대하는 ABI 에 맞춰 안정 태그로 고정한다.
#    (SDL3 는 ABI 안정성을 약속하지만, 빌드가 조용히 달라지는 것을 막으려면 고정해야 한다)
REF="${SDL_REF:-release-3.4.16}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ SDL3 ($REF) 받는 중…"
git clone --depth 1 --branch "$REF" "$REPO" "$WORK/src" >/dev/null 2>&1
ver=$(grep -E "SDL_(MAJOR|MINOR|MICRO)_VERSION +[0-9]" "$WORK/src/include/SDL3/SDL_version.h" \
        | grep -oE "[0-9]+$" | paste -sd. -)
echo "  버전 $ver"

# 공통 옵션. 테스트·예제는 필요 없고, 우리는 정적/동적을 플랫폼마다 다르게 쓴다.
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF)

build_ios() {
  echo "▸ iOS arm64"
  # ⚠️ 정적 라이브러리다. iOS 는 앱 번들 밖의 dylib 을 dlopen 할 수 없어서
  #    다른 네이티브들과 마찬가지로 **앱 바이너리에 함께 링크**한다.
  #    (그래서 LWJGL 이 SDL 심볼을 메인 실행 파일에서 찾게 된다 — GLFW JNI 와 같은 구조)
  cmake -S "$WORK/src" -B "$WORK/ios" "${COMMON[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON >/dev/null
  cmake --build "$WORK/ios" -j"$(sysctl -n hw.ncpu)" >/dev/null

  local lib="$WORK/ios/libSDL3.a"
  [ -f "$lib" ] || { echo "  ✗ libSDL3.a 가 없습니다"; return 1; }

  # cmake 는 타깃을 틀려도 조용히 성공한다. 앱에 넣는 순간에야 알게 되므로 여기서 자른다.
  case "$(lipo -info "$lib")" in *arm64*) ;; *) echo "  ✗ arm64 가 아닙니다"; return 1 ;; esac
  local plats; plats=$(otool -l "$lib" | sed -n 's/^ *platform //p' | sort -u | tr '\n' ' ')
  case "$plats" in "2 ") ;; *) echo "  ✗ iOS 전용이 아닙니다 (platform=$plats)"; return 1 ;; esac

  # 26.3 이 실제로 부르는 것 중 대표 몇 개가 실려 있는지 확인한다.
  #
  # ⚠️ `nm ... | grep -q` 로 쓰면 안 된다. grep -q 는 찾자마자 끝나면서 nm 을 SIGPIPE 로
  #    죽이고, `set -o pipefail` 이 그걸 파이프라인 실패로 본다 — 심볼이 **있는데도**
  #    없다고 보고한다. (build-terracotta.sh 에 같은 함정을 적어 뒀는데 또 걸렸다)
  #    한 번만 읽어서 변수에 담고 거기서 찾는다.
  local syms; syms=$(nm -gU "$lib")
  for sym in _SDL_Init _SDL_CreateWindow _SDL_GL_CreateContext _SDL_GL_SwapWindow _SDL_PollEvent; do
    case "$syms" in *" T $sym"*) ;; *) echo "  ✗ $sym 없음"; return 1 ;; esac
  done

  mkdir -p "$ROOT/Runtime/SDL3"
  cp "$lib" "$ROOT/Runtime/SDL3/libSDL3.a"
  mkdir -p "$ROOT/Runtime/SDL3/include"
  cp -R "$WORK/src/include/SDL3" "$ROOT/Runtime/SDL3/include/"
  echo "  완료: Runtime/SDL3/libSDL3.a ($(du -h "$lib" | cut -f1))"
}

build_android() {
  echo "▸ Android arm64-v8a"
  local ndk="${ANDROID_NDK_HOME:-}"
  if [ -z "$ndk" ]; then
    ndk=$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | sort -V | tail -1 || true)
  fi
  [ -n "$ndk" ] && [ -d "$ndk" ] || { echo "  ✗ NDK 를 찾지 못했습니다 (ANDROID_NDK_HOME)"; return 1; }
  echo "  NDK: ${ndk##*/}"

  # ⚠️ 안드로이드는 공유 라이브러리다. LWJGL 이 jniLibs 에서 dlopen 한다
  #    (lwjgl-sdl 의 natives jar 도 libSDL3.so 하나만 들고 있다).
  cmake -S "$WORK/src" -B "$WORK/android" "${COMMON[@]}" \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF >/dev/null
  cmake --build "$WORK/android" -j"$(sysctl -n hw.ncpu)" >/dev/null

  local so="$WORK/android/libSDL3.so"
  [ -f "$so" ] || { echo "  ✗ libSDL3.so 가 없습니다"; return 1; }
  case "$(file "$so")" in *aarch64*) ;; *) echo "  ✗ aarch64 가 아닙니다"; return 1 ;; esac

  mkdir -p "$ROOT/Runtime/SDL3/android/arm64-v8a"
  cp "$so" "$ROOT/Runtime/SDL3/android/arm64-v8a/libSDL3.so"
  echo "  완료: Runtime/SDL3/android/arm64-v8a/libSDL3.so ($(du -h "$so" | cut -f1))"
}

case "$TARGET" in
  ios)     build_ios ;;
  android) build_android ;;
  all)     build_ios; build_android ;;
  *)       echo "사용법: $0 [ios|android|all]"; exit 2 ;;
esac
