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
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])

PRELUDE = """
/* ── FlameLauncher: UIKit 진입점을 메인 스레드로 ──────────────────────────
   자세한 사정은 Scripts/build-sdl3.sh 의 patch_ios_mainthread 주석 참고. */
#ifdef SDL_PLATFORM_IOS
#include <dispatch/dispatch.h>
#include <pthread.h>
#endif
"""

def split_arg(a):
    """'const SDL_DisplayMode *mode' -> ('const SDL_DisplayMode *', 'mode')"""
    a = a.strip()
    m = re.match(r"^(.*?)([A-Za-z_][A-Za-z_0-9]*)$", a)
    return m.group(1).strip(), m.group(2)

def wrap(path, decl):
    """decl 예: 'bool SDL_SetWindowTitle(SDL_Window *window, const char *title)'"""
    p = root / path
    s = p.read_text()
    assert decl in s, f"{path}: 앵커를 못 찾았습니다 — {decl}"

    head, argstr = decl.split("(", 1)
    argstr = argstr.rstrip(")")
    name = re.match(r"^.*?([A-Za-z_][A-Za-z_0-9]*)$", head.strip()).group(1)
    ret = head.strip()[: -len(name)].strip()
    args = [] if argstr.strip() in ("", "void") else [split_arg(a) for a in argstr.split(",")]

    # ⚠️ 함수 이름만 바꾼다. decl 전체에 replace 를 걸면 반환 타입이 먼저 걸린다
    #    (SDL_Window *SDL_CreateWindow… → flame_real_SDL_Window *…).
    s = s.replace(decl, "static " + decl.replace(name + "(", "flame_real_" + name + "(", 1), 1)

    fields = "".join(f"    {t} {n};\n" for t, n in args)
    voidret = ret == "void"
    if not voidret:
        fields += f"    {ret} result;\n"
    call = f"flame_real_{name}(" + ", ".join(f"c->{n}" for _, n in args) + ")"
    direct = f"flame_real_{name}(" + ", ".join(n for _, n in args) + ")"
    assign = "" if voidret else "c->result = "
    setup = "".join(f"    c.{n} = {n};\n" for _, n in args)

    s += f"""
#ifdef SDL_PLATFORM_IOS
struct flame_ctx_{name} {{
{fields}}};
static void flame_thunk_{name}(void *p) {{
    struct flame_ctx_{name} *c = (struct flame_ctx_{name} *)p;
    {assign}{call};
}}
{decl} {{
    if (pthread_main_np()) {{ {'' if voidret else 'return '}{direct}; {'return;' if voidret else ''} }}
    struct flame_ctx_{name} c;
{setup}    dispatch_sync_f(dispatch_get_main_queue(), &c, flame_thunk_{name});
    {'' if voidret else 'return c.result;'}
}}
#endif
"""
    p.write_text(s)
    print(f"  {path}: {name}")

for path in ("src/SDL.c", "src/video/SDL_video.c", "src/events/SDL_mouse.c", "src/misc/SDL_url.c"):
    q = root / path
    q.write_text(q.read_text() + PRELUDE)

# ⚠️ Vulkan 진입점은 선언이 **여러 줄**이라 아래 파서가 못 잡는다. 한 줄로 편다.
#    (26.3 은 Vulkan 으로 그린다 — GL 이 아니다. 실측 스택:
#       UIKit_Vulkan_CreateSurface → UIKit_Metal_CreateView → -[SDL_uikitview setSDLWindow:]
#     이게 UIKit 을 백그라운드에서 만져 앱이 통째로 죽던 원인이다.)
vid = root / "src/video/SDL_video.c"
t = vid.read_text()
for multi, single in [
    ("""bool SDL_Vulkan_CreateSurface(SDL_Window *window,
                                  VkInstance instance,
                                  const struct VkAllocationCallbacks *allocator,
                                  VkSurfaceKHR *surface)""",
     "bool SDL_Vulkan_CreateSurface(SDL_Window *window, VkInstance instance, const struct VkAllocationCallbacks *allocator, VkSurfaceKHR *surface)"),
    ("""void SDL_Vulkan_DestroySurface(VkInstance instance,
                               VkSurfaceKHR surface,
                               const struct VkAllocationCallbacks *allocator)""",
     "void SDL_Vulkan_DestroySurface(VkInstance instance, VkSurfaceKHR surface, const struct VkAllocationCallbacks *allocator)"),
]:
    assert multi in t, "Vulkan 선언을 못 찾았습니다 (업스트림이 바뀜)"
    t = t.replace(multi, single, 1)
vid.write_text(t)

# ⚠️ GL 함수는 감싸지 않는다. SDL_GL_SwapWindow 는 매 프레임 불리고, GL 컨텍스트는
#    스레드에 묶이므로 메인으로 넘기면 정작 그리는 스레드에서 current 가 아니게 된다.
#    (GL 은 우리 ANGLE 로 대체할 예정이라 어차피 이 경로를 안 탄다)
wrap("src/SDL.c", "bool SDL_InitSubSystem(SDL_InitFlags flags)")
# ⚠️ **종료도 UIKit 이다.** 26.3 은 "게임 종료" 때 렌더 스레드에서 SDL_Quit 을 부르고,
#    SDL 은 정리하면서 화면 자동 잠금을 되돌린다. 메인이 아니면 FrontBoard 가 트랩을 건다:
#      SDL_Quit → SDL_VideoQuit → UIKit_SuspendScreenSaver
#      → -[UIApplication _setIdleTimerDisabled:forReason:] → assertBarrierOnQueue (EXC_BREAKPOINT)
wrap("src/SDL.c", "void SDL_Quit(void)")
# 채팅 링크 등 — -[UIApplication openURL:…] 을 그대로 부른다(misc/ios/SDL_sysurl.m).
wrap("src/misc/SDL_url.c", "bool SDL_OpenURL(const char *url)")

for decl in [
    "SDL_Window *SDL_CreateWindowWithProperties(SDL_PropertiesID props)",
    "void SDL_DestroyWindow(SDL_Window *window)",
    "bool SDL_SetWindowIcon(SDL_Window *window, SDL_Surface *icon)",
    "bool SDL_SetWindowBordered(SDL_Window *window, bool bordered)",
    "bool SDL_SetWindowSize(SDL_Window *window, int w, int h)",
    "bool SDL_SetWindowPosition(SDL_Window *window, int x, int y)",
    "bool SDL_SetWindowMinimumSize(SDL_Window *window, int min_w, int min_h)",
    "bool SDL_SetWindowMaximumSize(SDL_Window *window, int max_w, int max_h)",
    "bool SDL_SetWindowFullscreenMode(SDL_Window *window, const SDL_DisplayMode *mode)",
    "bool SDL_RaiseWindow(SDL_Window *window)",
    "bool SDL_ShowWindow(SDL_Window *window)",
    "bool SDL_HideWindow(SDL_Window *window)",
    "bool SDL_SetWindowFullscreen(SDL_Window *window, bool fullscreen)",
    "bool SDL_SyncWindow(SDL_Window *window)",
    "bool SDL_SetWindowTitle(SDL_Window *window, const char *title)",
    "bool SDL_SetWindowMouseGrab(SDL_Window *window, bool grabbed)",
    "bool SDL_SetWindowResizable(SDL_Window *window, bool resizable)",
    "bool SDL_SetWindowAlwaysOnTop(SDL_Window *window, bool on_top)",
    "bool SDL_MaximizeWindow(SDL_Window *window)",
    "bool SDL_MinimizeWindow(SDL_Window *window)",
    "bool SDL_RestoreWindow(SDL_Window *window)",
    # ⚠️ GL **컨텍스트 생성**만 감싼다. CAEAGLLayer 를 만들며 UIKit 을 건드리기
    #    때문이다. EAGL 컨텍스트는 나중에 다른 스레드에서 current 로 만들 수 있으므로
    #    메인에서 만들어도 문제가 없다.
    #    SwapWindow/MakeCurrent 는 감싸지 않는다 — 매 프레임 불리고 컨텍스트가
    #    스레드에 묶이므로 메인으로 넘기면 그리는 스레드에서 current 가 아니게 된다.
    "SDL_GLContext SDL_GL_CreateContext(SDL_Window *window)",
    "bool SDL_GL_DestroyContext(SDL_GLContext context)",
    # ⚠️ **getter 도 감싸야 한다.** setter 만 감쌌더니 그대로 터졌다 —
    #    이것들은 UIWindow·UIScreen 을 조회하므로 UIKit 호출이다.
    "bool SDL_GetWindowPosition(SDL_Window *window, int *x, int *y)",
    "bool SDL_GetWindowSize(SDL_Window *window, int *w, int *h)",
    "bool SDL_GetWindowSizeInPixels(SDL_Window *window, int *w, int *h)",
    "SDL_WindowFlags SDL_GetWindowFlags(SDL_Window *window)",
    "SDL_DisplayID SDL_GetDisplayForWindow(SDL_Window *window)",
    "SDL_DisplayID SDL_GetPrimaryDisplay(void)",
    "bool SDL_GetDisplayBounds(SDL_DisplayID displayID, SDL_Rect *rect)",
    "bool SDL_GetDisplayUsableBounds(SDL_DisplayID displayID, SDL_Rect *rect)",
    "const SDL_DisplayMode *SDL_GetCurrentDisplayMode(SDL_DisplayID displayID)",
    "const SDL_DisplayMode *SDL_GetDesktopDisplayMode(SDL_DisplayID displayID)",
    # ⚠️ **이게 실제 크래시 지점이었다.** 26.3 은 Vulkan 으로 그리고, 이 함수가
    #    Metal 뷰를 만들며 UIKit 을 탄다.
    "bool SDL_Vulkan_CreateSurface(SDL_Window *window, VkInstance instance, const struct VkAllocationCallbacks *allocator, VkSurfaceKHR *surface)",
    "void SDL_Vulkan_DestroySurface(VkInstance instance, VkSurfaceKHR surface, const struct VkAllocationCallbacks *allocator)",
    "bool SDL_Vulkan_LoadLibrary(const char *path)",
    "void SDL_Vulkan_UnloadLibrary(void)",
    # ⚠️ **텍스트 입력도 UIKit 이다.** 26.3 은 입력칸(EditBox)에 포커스가 가면 렌더 스레드에서
    #    TextInputManager.startTextInput → SDL_StartTextInput → -[UITextField becomeFirstResponder]
    #    로 내려간다. 월드 이름·채팅·서버 주소 칸이 전부 이 경로다.
    #    SDL_StartTextInput 은 WithProperties 를 부르기만 하므로 그쪽을 감싼다.
    "bool SDL_StartTextInputWithProperties(SDL_Window *window, SDL_PropertiesID props)",
    "bool SDL_StopTextInput(SDL_Window *window)",
    "bool SDL_SetTextInputArea(SDL_Window *window, const SDL_Rect *rect, int cursor)",
]:
    wrap("src/video/SDL_video.c", decl)

# 마우스 커서 조작도 UIKit 을 탄다(SDL_mouse.c).
for decl in [
    "void SDL_WarpMouseInWindow(SDL_Window *window, float x, float y)",
    "bool SDL_ShowCursor(void)",
    "bool SDL_HideCursor(void)",
]:
    wrap("src/events/SDL_mouse.c", decl)

def patch(path, anchor, replacement):
    p = root / path
    s = p.read_text()
    assert anchor in s, f"{path}: 앵커를 못 찾았습니다 — {anchor.strip()[:60]}"
    p.write_text(s.replace(anchor, replacement, 1))
    print(f"  {path}: {anchor.strip().splitlines()[0][:50]}")

# ⚠️ **창 크기를 이벤트 없이 바꾼다.** SetupWindowData 가 실제 뷰 크기(852x393 pt)를
#    window->w/h 에 바로 넣고, 뒤따르는 RESIZED 는 같은 값이라 SDL_SendWindowEvent 가 걸러 버린다.
#    26.3 의 Window 는 화면 크기를 --width/--height(기본 854x480)로 시작해 **RESIZED 로만**
#    고친다(Window.<init> · onResize). 그래서 게임은 끝까지 854x480 이라 믿고
#    마우스 y 를 `y × GUI높이 / 480` 으로 계산했다 — 화면 아래로 갈수록 터치가 위로 밀렸다.
#    창을 다 만든 뒤 실제 크기를 한 번 직접 알린다.
patch("src/video/uikit/SDL_uikitwindow.m",
      "    SDL_SetNumberProperty(props, SDL_PROP_WINDOW_UIKIT_METAL_VIEW_TAG_NUMBER, SDL_METALVIEW_TAG);\n",
      """    SDL_SetNumberProperty(props, SDL_PROP_WINDOW_UIKIT_METAL_VIEW_TAG_NUMBER, SDL_METALVIEW_TAG);

    /* FlameLauncher: 위에서 이벤트 없이 바꾼 크기를 앱에 알린다(Scripts/build-sdl3.sh). */
    SDL_Event resized;
    SDL_zero(resized);
    resized.type = SDL_EVENT_WINDOW_RESIZED;
    resized.window.windowID = window->id;
    resized.window.data1 = width;
    resized.window.data2 = height;
    SDL_PushEvent(&resized);
""")

# ⚠️ **백그라운드에서는 이벤트를 펌프하는 스레드를 세운다.**
#    iOS 는 백그라운드 앱의 GPU 작업을 거부하고, MoltenVK 는 그걸 장치 손실로 본다.
#    홈으로 나가거나 화면을 잠그면 게임이 그대로 죽었다:
#      Lost VkDevice … Insufficient Permission (to submit GPU work from background)
#      GpuDeviceLossException: VK_ERROR_DEVICE_LOST: Failed to wait for semaphore
#    (GL 경로는 ANGLE 이 실패를 삼켜서 안 드러났다.)
#    26.3 은 SDL_EVENT_WILL_ENTER_BACKGROUND 를 보지 않는다. 대신 렌더 스레드가 매 프레임
#    SDL_PollEvent 로 이벤트를 펌프하므로, 거기서 세우면 그리기도 함께 멈춘다.
#    SDL 은 WillResignActive → WillEnterBackground, DidBecomeActive → DidEnterForeground 로
#    짝지어 부른다(SDL_uikitevents.m) — 알림 센터를 내리는 것만으로도 멈췄다 풀린다.
#    UIKit 메인 스레드는 세우지 않는다. 풀어 줄 알림을 받는 스레드다.
patch("src/events/SDL_events.c",
      "static void SDL_PumpEventsInternal(bool push_sentinel)\n{\n",
      """#ifdef SDL_PLATFORM_IOS
/* FlameLauncher: 백그라운드에서 렌더 스레드를 세운다(Scripts/build-sdl3.sh). */
#include <pthread.h>
static pthread_mutex_t flame_bg_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t flame_bg_cond = PTHREAD_COND_INITIALIZER;
static bool flame_bg;

void FLAME_SetBackground(bool background)
{
    pthread_mutex_lock(&flame_bg_lock);
    flame_bg = background;
    pthread_cond_broadcast(&flame_bg_cond);
    pthread_mutex_unlock(&flame_bg_lock);
}

static void FLAME_WaitWhileBackground(void)
{
    if (pthread_main_np()) {
        return;
    }
    pthread_mutex_lock(&flame_bg_lock);
    while (flame_bg) {
        pthread_cond_wait(&flame_bg_cond, &flame_bg_lock);
    }
    pthread_mutex_unlock(&flame_bg_lock);
}
#endif

static void SDL_PumpEventsInternal(bool push_sentinel)
{
#ifdef SDL_PLATFORM_IOS
    FLAME_WaitWhileBackground();
#endif
""")
patch("src/video/SDL_video.c",
      "void SDL_OnApplicationWillEnterBackground(void)\n{\n",
      """#ifdef SDL_PLATFORM_IOS
extern void FLAME_SetBackground(bool background);
#endif
void SDL_OnApplicationWillEnterBackground(void)
{
#ifdef SDL_PLATFORM_IOS
    FLAME_SetBackground(true);
#endif
""")
patch("src/video/SDL_video.c",
      "void SDL_OnApplicationDidEnterForeground(void)\n{\n",
      """void SDL_OnApplicationDidEnterForeground(void)
{
#ifdef SDL_PLATFORM_IOS
    FLAME_SetBackground(false);
#endif
""")
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
