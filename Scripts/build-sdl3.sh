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

# ⚠️ iOS: UIKit 을 건드리는 진입점을 **메인 스레드로 넘긴다**.
#
#    SDL 의 uikit 백엔드는 UIWindow·UIScreen·CAEAGLLayer 를 만지므로 메인 스레드에서만
#    안전하다. 그런데 SDL 은 "SDL_Init 을 부른 스레드"를 메인으로 간주할 뿐이고
#    (src/SDL.c 의 SDL_MainThreadID), 진짜 UIKit 메인 스레드인지는 보지 않는다.
#
#    우리 구조에서는 그게 어긋난다. `-XstartOnFirstThread` 의 "첫 스레드"는 JLI 를 부른
#    스레드인데 런처는 JVM 을 백그라운드에서 띄운다 — 그래서 마인크래프트가
#    "Render thread" 라 부르는 JVM 메인이 UIKit 관점에서는 백그라운드다. 실측:
#      [FlameSDL] SDL_Init 호출 — 현재 스레드: 백그라운드   → 로그 한 줄 없이 사망
#      (메인 큐로 넘기면)     ✅ SDL_Init(VIDEO) 성공 — 드라이버 'uikit'
#
#    래퍼 dylib 도 검토했지만 나머지 심볼을 전부 다시 내보내야 해서(트램폴린 생성)
#    원본을 고치는 쪽이 훨씬 작다. MobileGlues 에 쓰는 방식과 같다.
#
# ⚠️ 두 파일 다 `.c` 라 ObjC 블록을 못 쓴다. GCD 의 C API(dispatch_sync_f)를 쓴다.
# ⚠️ 이미 메인이면 dispatch_sync 는 교착이다. pthread_main_np() 로 먼저 가른다.
patch_ios_mainthread() {
  local src="$1"
  python3 - "$src" <<'SDLPATCH'
import pathlib, sys
root = pathlib.Path(sys.argv[1])

HELPER = """
/* ── FlameLauncher 패치: UIKit 진입점을 메인 스레드로 ───────────────────────
   자세한 사정은 Scripts/build-sdl3.sh 의 patch_ios_mainthread 주석 참고. */
#ifdef SDL_PLATFORM_IOS
#include <dispatch/dispatch.h>
#include <pthread.h>
#define FLAME_ON_MAIN(ctx_type, ctx_init, body)                    \\
    do {                                                            \\
        if (pthread_main_np()) { body }                             \\
    } while (0)
#endif
"""

def wrap(path, anchor, ctx, thunk, wrapper):
    p = root / path
    s = p.read_text()
    assert anchor in s, f"{path}: 앵커를 못 찾았습니다 — {anchor}"
    # ⚠️ **함수 이름만** 바꾼다. 앵커 전체에 replace 를 걸면 반환 타입이 먼저 걸려서
    #    `SDL_Window *SDL_CreateWindowWithProperties` 가
    #    `flame_real_SDL_Window *SDL_Create…` 가 된다(unknown type name).
    name = anchor.split("(")[0].split()[-1].lstrip("*")
    renamed = anchor.replace(name + "(", "flame_real_" + name + "(", 1)
    s = s.replace(anchor, "static " + renamed, 1)
    # 파일 끝에 래퍼를 붙인다(원본 정의가 먼저 와야 한다).
    s += "\n" + ctx + thunk + wrapper + "\n"
    p.write_text(s)
    print(f"  {path}: {anchor.split('(')[0].split()[-1]} 을 메인 스레드로")

wrap("src/SDL.c",
     "bool SDL_InitSubSystem(SDL_InitFlags flags)",
     "\n#ifdef SDL_PLATFORM_IOS\n#include <dispatch/dispatch.h>\n#include <pthread.h>\n"
     "struct flame_init_ctx { SDL_InitFlags flags; bool result; };\n",
     "static void flame_init_thunk(void *p) {\n"
     "    struct flame_init_ctx *c = (struct flame_init_ctx *)p;\n"
     "    c->result = flame_real_SDL_InitSubSystem(c->flags);\n}\n",
     "bool SDL_InitSubSystem(SDL_InitFlags flags) {\n"
     "    if (pthread_main_np()) return flame_real_SDL_InitSubSystem(flags);\n"
     "    struct flame_init_ctx c; c.flags = flags; c.result = false;\n"
     "    dispatch_sync_f(dispatch_get_main_queue(), &c, flame_init_thunk);\n"
     "    return c.result;\n}\n#endif\n")

wrap("src/video/SDL_video.c",
     "SDL_Window *SDL_CreateWindowWithProperties(SDL_PropertiesID props)",
     "\n#ifdef SDL_PLATFORM_IOS\n#include <dispatch/dispatch.h>\n#include <pthread.h>\n"
     "struct flame_win_ctx { SDL_PropertiesID props; SDL_Window *result; };\n",
     "static void flame_win_thunk(void *p) {\n"
     "    struct flame_win_ctx *c = (struct flame_win_ctx *)p;\n"
     "    c->result = flame_real_SDL_CreateWindowWithProperties(c->props);\n}\n",
     "SDL_Window *SDL_CreateWindowWithProperties(SDL_PropertiesID props) {\n"
     "    if (pthread_main_np()) return flame_real_SDL_CreateWindowWithProperties(props);\n"
     "    struct flame_win_ctx c; c.props = props; c.result = NULL;\n"
     "    dispatch_sync_f(dispatch_get_main_queue(), &c, flame_win_thunk);\n"
     "    return c.result;\n}\n#endif\n")

wrap("src/video/SDL_video.c",
     "SDL_GLContext SDL_GL_CreateContext(SDL_Window *window)",
     "\n#ifdef SDL_PLATFORM_IOS\n"
     "struct flame_gl_ctx { SDL_Window *window; SDL_GLContext result; };\n",
     "static void flame_gl_thunk(void *p) {\n"
     "    struct flame_gl_ctx *c = (struct flame_gl_ctx *)p;\n"
     "    c->result = flame_real_SDL_GL_CreateContext(c->window);\n}\n",
     "SDL_GLContext SDL_GL_CreateContext(SDL_Window *window) {\n"
     "    if (pthread_main_np()) return flame_real_SDL_GL_CreateContext(window);\n"
     "    struct flame_gl_ctx c; c.window = window; c.result = NULL;\n"
     "    dispatch_sync_f(dispatch_get_main_queue(), &c, flame_gl_thunk);\n"
     "    return c.result;\n}\n#endif\n")
SDLPATCH
}

build_ios() {
  echo "▸ iOS arm64"
  # ⚠️ **dylib** 으로 만든다. LWJGL 의 org.lwjgl.sdl.SDL 은 정적 심볼을 찾지 않고
  #    `Library.loadNative` 로 연다 — 즉 `Configuration.SDL_LIBRARY_NAME`
  #    (`-Dorg.lwjgl.sdl.libname`) 으로 가리킬 수 있는 **파일**이어야 한다.
  #    앱 번들 안의 dylib 은 iOS 에서도 dlopen 되며, 이미 libmobileglues.dylib 을
  #    같은 방식으로 쓰고 있다. 정적으로 링크하면 이 경로가 막힌다.
  patch_ios_mainthread "$WORK/src"

  cmake -S "$WORK/src" -B "$WORK/ios" "${COMMON[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF > "$WORK/ios-cfg.log" 2>&1 || {
      echo "  ✗ cmake 구성 실패:"; tail -20 "$WORK/ios-cfg.log" | sed 's/^/    /'; return 1; }
  # ⚠️ 출력을 버리지 않는다. 컴파일 오류가 여기로 나오는데 /dev/null 이면
  #    rc=1 만 남아서 무엇이 깨졌는지 알 수 없다(실제로 두 번 헤맸다).
  cmake --build "$WORK/ios" -j"$(sysctl -n hw.ncpu)" > "$WORK/ios-build.log" 2>&1 || {
      echo "  ✗ 빌드 실패:"; grep -E "error:" "$WORK/ios-build.log" | head -12 | sed 's/^/    /'; return 1; }

  local lib
  lib=$(find "$WORK/ios" -name "libSDL3*.dylib" -type f | head -1)
  [ -n "$lib" ] || { echo "  ✗ libSDL3 dylib 이 없습니다"; return 1; }

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
  # ⚠️ 번들 안에서 열리려면 install_name 이 @rpath 여야 한다. cmake 는 빌드 경로를
  #    박아 두므로 그대로 두면 기기에서 dlopen 이 실패한다.
  install_name_tool -id "@rpath/libSDL3.dylib" "$lib" 2>/dev/null || true
  for sym in _SDL_Init _SDL_CreateWindow _SDL_GL_CreateContext _SDL_GL_SwapWindow _SDL_PollEvent; do
    case "$syms" in *" T $sym"*) ;; *) echo "  ✗ $sym 없음"; return 1 ;; esac
  done

  mkdir -p "$ROOT/Runtime/SDL3"
  cp "$lib" "$ROOT/Runtime/SDL3/libSDL3.dylib"
  mkdir -p "$ROOT/Runtime/SDL3/include"
  cp -R "$WORK/src/include/SDL3" "$ROOT/Runtime/SDL3/include/"
  echo "  완료: Runtime/SDL3/libSDL3.dylib ($(du -h "$lib" | cut -f1))"
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
