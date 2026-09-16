<div align="center">

# 🧱 FlameLauncher Natives

**마인크래프트 자바 런처를 iOS 에서 돌리기 위한 네이티브 빌드 스크립트와 패치.**

[![target](https://img.shields.io/badge/target-iOS%20arm64-000000?logo=apple&logoColor=white)](#)
[![patches](https://img.shields.io/badge/patches-974%20lines-orange)](patches)
[![AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

**[🇰🇷 한국어](#-한국어)** · **[🇺🇸 English](#-english)**

</div>

---
---

# 🇰🇷 한국어

iOS 에서 마인크래프트 자바 에디션을 돌리려면 렌더러·LWJGL·GLFW·SDL3·P2P 네트워킹을 전부
`aarch64-apple-ios` 로 빌드해야 하는데, **업스트림 어디에도 iOS 빌드가 없습니다.**
안드로이드 빌드가 있어도 그대로는 컴파일조차 되지 않습니다.

이 저장소는 그 간격을 메우는 패치입니다.
[FlameLauncher for iOS](https://github.com/FlameLaunchers/FlameLauncher-iOS) 에서
쓰려고 만들었지만 **앱 코드를 전혀 참조하지 않습니다** — PojavLauncher iOS · Amethyst 등
다른 런처에서도 그대로 쓸 수 있습니다.

```
Scripts/       빌드 스크립트. CI 가 정확히 이것을 돌립니다
patches/       각 스크립트가 만드는 diff 전체 (974줄)
JavaPatches/   build-javaapp.sh 가 launcher.jar 에 넣는 자바 스텁
licenses/      빌드하는 업스트림 9곳의 라이선스 전문
```

**패치한 업스트림 트리를 통째로 두지 않습니다.** 서브모듈까지 합치면 수백 MB 인데 그중
실제로 바뀐 건 974줄입니다. 대신 빌드 시점에 클론 → 패치 → 빌드하고, 그 결과 diff 를
`patches/` 에 읽을 수 있게 남깁니다.

모든 패치에 하드 `assert` 가 걸려 있어서, 업스트림이 앵커를 건드리면 **빌드가 그 자리에서
멈춥니다.** 조용히 빗나가서 엉뚱한 바이너리를 만드는 것보다 낫습니다.

---

## 1. 어떤 패치가 있나

| 스크립트 | 패치 | assert | diff | 산출물 |
|---|---|---|---|---|
| `build-mobileglues.sh` | 19 | 29 | 766줄 | `libmobileglues.dylib` |
| `build-terracotta.sh` | 7 | 7 | 137줄 | `libterracotta.a` |
| `build-javaapp.sh` | 3 | 3 | 71줄 | `lwjgl.jar` · `launcher.jar` |
| `build-sdl3.sh` | 50 | 52 | — | `libSDL3.dylib` |
| `build-lwjgl-natives.sh` | — | — | — | `liblwjgl*.dylib` (3.4.3) |
| `build-spirv-cross.sh` | — | — | — | `libspirv-cross.dylib` |
| `build-shaderc.sh` | — | — | — | `libshaderc.dylib` |

### 렌더러 — `build-mobileglues.sh` (19개)

MobileGlues 는 데스크톱 GL 을 GLES 로 번역합니다. 업스트림 CMake 에 iOS 분기가 있지만
**한 번도 컴파일된 적이 없습니다** — 릴리스가 APK 뿐입니다.

**① 애초에 빌드가 안 되는 것**

- `__attribute__((alias))` — Mach-O 에 없습니다
- `__NR_gettid` — 리눅스 syscall 번호. Darwin 은 `pthread_threadid_np` 를 씁니다
- `-Wl,-Bsymbolic-functions` — GNU ld 전용이라 Apple ld 가 거부합니다

**② iOS 호스트가 ES 3.0 이라 생기는 것**

안드로이드 호스트는 ES 3.2 지만 iOS 는 ANGLE Metal = **ES 3.0** 입니다. ANGLE 은 ES 3.2
심볼을 전부 내보내되 ES 3.0 컨텍스트에서는 호출을 거부합니다 — **오류 없이 조용히 아무
일도 일어나지 않습니다.** `glFramebufferTexture`(3.2)와 `glGetTexLevelParameteriv`(3.1)에
폴백을 넣습니다.

**③ 셰이더가 안 보이던 진짜 이유**

Iris 를 켜면 엔티티와 손에 든 아이템이 보이지 않았습니다.

> Metal 은 정점 포맷의 **부호(signedness)** 가 셰이더 선언과 일치해야 합니다.
> GL 과 GLES 는 요구하지 않습니다.

`ivec3` 로 선언된 속성에 `GL_UNSIGNED_SHORT` 를 물리면 GL 에서는 통과하지만 Metal 은
파이프라인 생성 자체를 거부합니다. 그리기 직전에 프로그램의 정수 속성을 훑어 부호를
맞춰 다시 걸어 줍니다.

> 찾는 데 오래 걸린 이유가 있습니다. MobileGlues 의 `CHECK_GL_ERROR` 는 `#if GLOBAL_DEBUG`
> 아래라 기본 빌드에서 **226군데가 전부 `{}` 로 컴파일됩니다.** "GL 오류가 하나도 없다"는
> 관찰에 아무 근거가 없었습니다. 오류 로그를 상시 켜는 패치를 같이 넣습니다.

**④ 심볼이 자기 자신을 건너뛰던 것**

`glx/lookup.cpp` 의 애플 분기가 이렇습니다.

```c
return dlsym((void*)(~(uintptr_t)0), name);
```

`~0` = `(void*)-1` 인데 이 값의 뜻이 플랫폼마다 다릅니다. **안드로이드(LP64)에서는
`RTLD_DEFAULT` 지만 애플에서는 `RTLD_NEXT`** — *자기 자신을 건너뛰고* 다음 객체에서
찾습니다. 그래서 MobileGlues 가 자기 `gl*` 을 절대 돌려주지 않고 ANGLE 것을 줍니다.

LWJGL 3.3.3 은 이 경로를 안 타서 드러나지 않았습니다. 3.4.1 이 `GetProcAddress` 후보에
`eglGetProcAddress` 를 추가하면서 밟습니다 — 그러면 **모든 GL 함수**가 ANGLE 로 빠지고,
`glGetIntegerv` 가 ES 3.0 을 보고해 LWJGL 이 GL 3.3+ 진입점을 하나도 매핑하지 않습니다.
마인크래프트 26.2 가 `glGenSamplers` 널 포인터로 죽습니다. `RTLD_SELF` 로 고칩니다.

**⑤ 메모리**

서버 리소스팩이 고해상도면 마인크래프트가 8192² 아틀라스를 만듭니다 — RGBA8 로 268MB,
업로드 버퍼까지 잠깐 두 벌이면 iOS 예산(아이폰 15 기준 약 3GB)을 넘겨 프로세스가 jetsam
으로 죽습니다. **남은 여유로 감당이 안 될 때만** 2의 거듭제곱으로 줄여 잡고, 부분 업로드의
좌표와 픽셀도 같은 비율로 줄입니다. UV 는 정규화 좌표라 그림은 제자리에 맞습니다.

### 온라인 LAN — `build-terracotta.sh` (7개)

[Terracotta](https://github.com/PCL-Community/Terracotta-lib)(EasyTier 기반)의
**첫 iOS 빌드**입니다.

원본 [burningtnt/Terracotta](https://github.com/burningtnt/Terracotta) 는 iOS 에서 불가능합니다
— EasyTier 실행 파일을 품고 있다가 자식 프로세스로 띄우는데, iOS 샌드박스가 프로세스
생성을 막습니다. 라이브러리로 링크되게 갈라져 나온 PCL 포크만 쓸 수 있습니다.

**iOS 고유의 컴파일 실패는 딱 한 군데**였습니다. `InterfaceFilter` 에 iOS 구현이 없는데,
macOS 판은 `networksetup` CLI 를 부르고 iOS 엔 그 명령이 없습니다. 모바일에서는 인터페이스를
걸러낼 수단이 없으므로 안드로이드 분기(전부 통과)에 얹습니다. 나머지는 전부 의존성 버전
불일치였습니다.

**FFI 를 새로 냅니다.** 업스트림은 JNI 뿐인데, 테라코타는 제어 표면을 이미 HTTP 로 전부
내놓고 있습니다(데스크톱 UI 가 그걸 씁니다). 그래서 네이티브 진입점 하나면 됩니다.

```c
uint16_t terracotta_ios_start(const char *dataDir);   // 제어 서버를 띄우고 포트 반환
```

나머지는 `http://127.0.0.1:<포트>/state/…` 로 부릅니다. 호출마다 FFI 를 손으로 짜는 것보다
표면이 작고, 업스트림이 API 를 바꿔도 깨질 자리가 적습니다.

> **TUN 은 쓰지 않습니다.** iOS 에서 TUN 은 Network Extension 뿐이고 그 권한은 무료 개발자
> 계정으로 서명되지 않습니다. EasyTier 의 no-TUN 모드로 동작하므로 문서화된 제약이 그대로
> 적용됩니다 — 방장 노릇은 되고, 참가는 주소를 직접 넣어야 합니다.

### LWJGL 3.4.x — `build-lwjgl-natives.sh`

마인크래프트 26.2 가 3.4.1, 26.3 이 3.4.3 을 요구하고, **3.3.3 과 섞을 수 없습니다** — 3.4 에서 콜백 인프라
(`Upcalls`, `ffi_get_closure_size`, `Callback$Descriptor`)가 새로 생겨 자바와 네이티브가
같은 버전이어야 합니다.

까다로운 부분은 **libffi 의 클로저 레이아웃**입니다. `FFI_EXEC_TRAMPOLINE_TABLE`(iOS 는 1)이
켜지면 `ffi_closure` 의 필드 오프셋이 달라지는데, LWJGL 의 `ffi.h` 는 이걸
`defined(LWJGL_MACOS) && defined(LWJGL_arm64)` 로 가릅니다 — **소문자 `arm64`** 입니다.
`LWJGL_ARM64` 로 넘기면 조용히 틀린 오프셋이 잡히고, 콜백의 `user_data` 가 0 으로 읽혀
게임이 죽습니다.

기본은 **3.4.3** 입니다. 자바 jar 과 네이티브는 패치 버전까지 같아야 합니다 — 3.4.3 jar 에
3.4.1 네이티브를 물리면 `MemoryUtil.ngetPageSize` 가 없어 클래스 초기화에서 죽고, LWJGL 을
쓰는 모든 것이 연쇄로 무너집니다.

### GLFW 심 — `build-javaapp.sh` (3개)

[Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS) 의 JavaApp 을 빌드하면서 LWJGL
3.4.1 에서 넓어진 표면을 메웁니다 — `glfwPlatformSupported`, `glfwGetMonitorName`,
IME/preedit 콜백 3종.

잠재 NPE 도 하나 막습니다. `glfwGetInputMode` 가 빈 `HashMap` 의 결과를 그대로 언박싱해서
**설정한 적 없는 모드를 물으면 무조건 죽습니다.** 마인크래프트 26.2 가 매 틱
`GLFW_IME`(3.4 신규)를 묻습니다. IME 만 특별히 봐 주는 대신 함수 한 곳에서 막고, 기본값은
실제 GLFW 와 맞춥니다(커서는 `NORMAL`, 그 밖엔 `FALSE`).

26.3 부터는 `JavaPatches/` 의 `ca.weblite.objc` 스텁도 넣습니다. 게임이 `os.name`("Mac OS X")만
보고 AppKit 손질을 부르는데, 그 안쪽 JNA 가 iOS 에서 `NoClassDefFoundError` 로 부팅을 끝냅니다.
`MacosUtil` 을 직접 가리면 클라이언트 jar 서명과 충돌해서 한 단계 아래를 가립니다.

### `build-spirv-cross.sh`

마인크래프트 26.2 의 blaze3d 가 `libspirv-cross` 를 요구합니다. `spvc_*` C API 만 필요하므로
그것만 내보내는 dylib 을 만듭니다.

### 창·입력 — `build-sdl3.sh` (50개)

마인크래프트 26.3 은 GLFW 를 버리고 **SDL3** 로 갔습니다. SDL3 는 iOS 백엔드(uikit)를 원래
갖고 있어서 GLFW 때처럼 통째로 재구현할 필요는 없습니다. 다만 그 백엔드는 **SDL 이 앱을
소유한다**는 전제로 쓰였고, 런처 안에서는 그 전제가 깨집니다.

**① UIKit 을 렌더 스레드에서 만진다 (46개)**

게임은 SDL 을 렌더 스레드에서 부르는데, uikit 백엔드는 창·화면·텍스트 입력·종료에서 UIKit 을
건드립니다. 메인 스레드가 아니면 로그 한 줄 없이 죽거나 FrontBoard 가 트랩을 겁니다. 그런
진입점을 `dispatch_sync_f` 로 메인에 넘기고, 이미 메인이면 그대로 부릅니다. 목록은
**선언을 파싱해 자동 생성**합니다.

> 찍어 맞히던 시기가 있었습니다. 감싸는 진입점을 3 → 11 → 27 → 37개로 늘렸는데도 같은
> 자리에서 같은 예외가 났고, `NSSetUncaughtExceptionHandler` 로 심볼 있는 스택을 찍자 한 번에
> 나왔습니다 — `SDL_Vulkan_CreateSurface`. 26.3 은 GL 이 아니라 **Vulkan** 으로 그립니다.

**② 창 크기를 이벤트 없이 바꾼다**

창을 만들 때 실제 크기를 `window->w/h` 에 바로 넣어서, 뒤따르는 RESIZED 는 같은 값이라
걸러집니다. 게임은 화면 크기를 `--width/--height`(기본 854×480)로 시작해 RESIZED 로만 고치므로
끝까지 854×480 이라 믿었고, 터치가 화면 아래로 갈수록 위로 밀렸습니다. 창을 다 만든 뒤 실제
크기를 한 번 직접 알립니다.

**③ 백그라운드에서 GPU 를 쓴다**

iOS 는 백그라운드 앱의 GPU 작업을 거부하고, MoltenVK 는 그걸 장치 손실로 봅니다 — 홈으로
나가면 게임이 `VK_ERROR_DEVICE_LOST` 로 죽었습니다. 게임은 SDL 알림을 보지 않지만 매 프레임
이벤트를 펌프하므로, 앱이 비활성인 동안 그 자리에서 스레드를 세웁니다.

### `build-shaderc.sh`

26.3 의 렌더 엔진은 GLSL 을 **실행 중에** SPIR-V 로 컴파일합니다. LWJGL 3.4.3 이 요구하는
진입점 45개 중 하나(`shaderc_compile_options_set_max_id_bound`)가 예전 바이너리에 없어서 태그를
고정해 새로 빌드하고, 끝에서 필수 심볼을 직접 확인합니다(없으면 거기서 멈춥니다).

---

## 2. 실행 방법

### 준비물

```bash
brew install cmake ninja
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # 테라코타용
rustup target add aarch64-apple-ios
```

Xcode 와 iOS SDK 가 필요합니다. **맥에서만 됩니다.**

### 직접 빌드

```bash
git clone https://github.com/FlameLaunchers/FlameLauncher-Natives.git
cd FlameLauncher-Natives

./Scripts/build-mobileglues.sh            # 렌더러
./Scripts/build-terracotta.sh --release   # 온라인 LAN
./Scripts/build-spirv-cross.sh            # 마인크래프트 26.2
./Scripts/build-shaderc.sh                # 마인크래프트 26.3 셰이더 컴파일러
./Scripts/build-sdl3.sh ios               # 마인크래프트 26.3 창·입력
./Scripts/build-lwjgl-natives.sh          # LWJGL 3.4.3 네이티브
LWJGL_VERSION=3.4.3 ./Scripts/build-javaapp.sh   # 26.2 · 26.3 용 자바 스택
```

산출물은 `Runtime/` 아래에 떨어집니다. 런처 프로젝트로 가져가 링크하면 됩니다.

테라코타는 크레이트 641개를 받아 컴파일하므로 **처음 한 번은 10~20분** 걸립니다.

### 패치를 다시 뽑기

```bash
EMIT_PATCH_DIR=patches ./Scripts/build-mobileglues.sh
```

`patches/` 에 통짜 diff 가 다시 쓰입니다. 업스트림이 움직였을 때 무엇이 달라졌는지
`git diff` 로 바로 볼 수 있습니다.

### GitHub Actions 로 빌드

[`.github/workflows/build.yml`](.github/workflows/build.yml) 이 macOS 러너에서 위 스크립트를
그대로 돌립니다.

| 트리거 | 언제 |
|---|---|
| **수동 실행** | 대상을 골라서 (`-f targets="mobileglues terracotta"`) |
| **`v*` 태그** | 산출물을 zip 으로 묶어 릴리스에 붙입니다 |
| **주 1회 예약** | 월요일 03:00 KST |

```bash
gh workflow run "iOS 네이티브 빌드" -R FlameLaunchers/FlameLauncher-Natives
```

**주 1회 예약이 이 워크플로의 진짜 목적입니다.** 패치가 전부 하드 assert 위에 서 있어서
업스트림이 앵커를 건드리면 빌드가 멈추는데, 그걸 몇 달 뒤가 아니라 **그 주에** 알기
위함입니다.

검증이 두 단계 붙어 있습니다.

1. **iOS arm64 인지 확인** — `cargo`·`cmake` 는 타깃을 틀려도 **조용히 성공합니다.**
   맥용 바이너리가 섞이면 앱에 넣는 순간에야 알게 되므로, 모든 산출물의 `lipo -info` 와
   `LC_BUILD_VERSION`(platform 2 = iOS)을 확인하고 아니면 실패시킵니다.
2. **저장된 패치와 대조** — 새로 뽑은 diff 가 `patches/` 와 다르면 경고하고 차이를 찍습니다.

---

## 3. 라이선스

**[AGPL-3.0](LICENSE)** 입니다.

이 저장소는 업스트림 소스를 담고 있지 않습니다. 하지만 **패치는 자기가 고치는 파일의
파생물**이라 그 파일의 라이선스를 함께 따릅니다. 이 저장소는 여러 라이선스의 저작물을
한꺼번에 건드리므로, 전체는 그중 가장 강한 **테라코타의 AGPL-3.0** 에 맞춥니다.

| 스크립트 | 업스트림 | 업스트림 라이선스 |
|---|---|---|
| `build-mobileglues.sh` | [MobileGlues](https://github.com/MobileGL-Dev/MobileGlues) | LGPL-2.1-only |
| `build-terracotta.sh` | [Terracotta-lib](https://github.com/PCL-Community/Terracotta-lib) | **AGPL-3.0** |
| | [EasyTier](https://github.com/EasyTier/EasyTier) | LGPL-3.0 |
| `build-javaapp.sh` | [Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS) | GPL-3.0 |
| | [LWJGL](https://github.com/LWJGL/lwjgl3) | BSD-3-Clause |
| `build-lwjgl-natives.sh` | [LWJGL](https://github.com/LWJGL/lwjgl3) · [libffi](https://github.com/libffi/libffi) | BSD-3-Clause · MIT |
| `build-spirv-cross.sh` | [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) | Apache-2.0 |
| `build-sdl3.sh` | [SDL](https://github.com/libsdl-org/SDL) | Zlib |
| `build-shaderc.sh` | [shaderc](https://github.com/google/shaderc) · [glslang](https://github.com/KhronosGroup/glslang) · [SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools) | Apache-2.0 · BSD-3-Clause 외 · Apache-2.0 |

개별 패치를 그 자체의 조건으로 쓰고 싶다면, **MobileGlues 파일에 대한 패치는 LGPL-2.1-only
로도 동등하게 이용 가능**하고, Amethyst-iOS 파일에 대한 패치는 GPL-3.0 으로 이용 가능합니다
— 각각 고치는 파일과 같은 라이선스입니다. AGPL-3.0 은 이 모음 전체에 적용됩니다.

업스트림 9곳의 라이선스 전문을 [`licenses/`](licenses) 에 그대로 넣어 뒀습니다.

각 패치는 삽입 지점을 찾으려고 업스트림 파일의 짧은 발췌를 인용합니다. 그 발췌는 위
저장소들에서 온 것이며, 파일 안의 **위치를 가리키는 용도로만** 들어 있습니다.

자세한 내용은 [NOTICE](NOTICE) 를 보세요.

> Minecraft 는 Mojang AB 의 상표입니다. 이 프로젝트는 Mojang AB · Microsoft 와
> 아무 관련이 없습니다.

<div align="right"><a href="#-flamelauncher-natives">⬆ 맨 위로</a></div>

---
---

# 🇺🇸 English

Running Minecraft Java on iOS means building the renderer, LWJGL, GLFW, SDL3 and the P2P
networking for `aarch64-apple-ios` — and **no upstream ships an iOS build.** Where an
Android build exists, it does not even compile as-is.

This repository is the set of patches that close that gap. It was written for
[FlameLauncher for iOS](https://github.com/FlameLaunchers/FlameLauncher-iOS) but
**references no app code at all** — PojavLauncher iOS, Amethyst and others can use it
unchanged.

```
Scripts/       the build scripts; CI runs exactly these
patches/       the complete diff each script produces (974 lines)
JavaPatches/   Java stubs that build-javaapp.sh puts into launcher.jar
licenses/      the full licence text of all nine upstreams that get built
```

**Patched upstream trees are not vendored.** With submodules that would be hundreds of
megabytes, of which 974 lines actually changed. Instead each script clones, patches and
builds at build time, writing the resulting diff into `patches/`.

Every patch sits behind a hard `assert`, so when upstream touches an anchor **the build
stops right there** rather than silently missing and producing a wrong binary.

---

## 1. What the patches are

| Script | Patches | Asserts | Diff | Output |
|---|---|---|---|---|
| `build-mobileglues.sh` | 19 | 29 | 766 lines | `libmobileglues.dylib` |
| `build-terracotta.sh` | 7 | 7 | 137 lines | `libterracotta.a` |
| `build-javaapp.sh` | 3 | 3 | 71 lines | `lwjgl.jar` · `launcher.jar` |
| `build-sdl3.sh` | 50 | 52 | — | `libSDL3.dylib` |
| `build-lwjgl-natives.sh` | — | — | — | `liblwjgl*.dylib` (3.4.3) |
| `build-spirv-cross.sh` | — | — | — | `libspirv-cross.dylib` |
| `build-shaderc.sh` | — | — | — | `libshaderc.dylib` |

### The renderer — `build-mobileglues.sh` (19)

MobileGlues translates desktop GL into GLES. Upstream's CMake has an iOS branch, but it
**has never been compiled** — the releases are APKs.

**① Things that simply don't build**

- `__attribute__((alias))` — absent on Mach-O
- `__NR_gettid` — a Linux syscall number; Darwin uses `pthread_threadid_np`
- `-Wl,-Bsymbolic-functions` — GNU ld only, rejected by Apple ld

**② Things that break because the iOS host is ES 3.0**

The Android host is ES 3.2; on iOS the host is ANGLE Metal, which is **ES 3.0**. ANGLE
exports the whole ES 3.2 symbol set but refuses the calls on an ES 3.0 context — **no
error, nothing happens.** Fallbacks are added for `glFramebufferTexture` (3.2) and
`glGetTexLevelParameteriv` (3.1).

**③ Why shaders rendered nothing**

With Iris on, entities and the held item were invisible.

> Metal requires the **signedness** of a vertex format to match the shader declaration.
> GL and GLES do not.

Feeding `GL_UNSIGNED_SHORT` to an attribute declared `ivec3` passes in GL and makes Metal
reject the pipeline outright. The fix walks the program's integer attributes just before
drawing and re-binds them with matching signedness.

> This took a long time to find for a reason. MobileGlues' `CHECK_GL_ERROR` sits behind
> `#if GLOBAL_DEBUG`, so in a default build **all 226 call sites compile to `{}`.** The
> observation "there are no GL errors" rested on nothing. A companion patch turns error
> logging on permanently.

**④ A lookup that skipped its own library**

The Apple branch of `glx/lookup.cpp` reads:

```c
return dlsym((void*)(~(uintptr_t)0), name);
```

`~0` is `(void*)-1`, and that value means different things per platform. **On Android
(LP64) it is `RTLD_DEFAULT`; on Apple it is `RTLD_NEXT`** — search the objects *after* me.
So MobileGlues never returned its own `gl*` and handed back ANGLE's instead.

LWJGL 3.3.3 never takes this path, so it stayed hidden. 3.4.1 added `eglGetProcAddress` to
its `GetProcAddress` candidates and walked straight into it: **every** GL function then
resolved to ANGLE, `glGetIntegerv` reported ES 3.0, LWJGL mapped no GL 3.3+ entry points,
and Minecraft 26.2 died on a null `glGenSamplers`. `RTLD_SELF` fixes it.

**⑤ Memory**

A high-resolution server resource pack makes Minecraft build an 8192² atlas — 268 MB as
RGBA8, and briefly twice that with the upload buffer, which exceeds the iOS budget (about
3 GB on an iPhone 15) and gets the process jetsammed. The patch shrinks by powers of two
**only when the remaining headroom cannot hold it**, scaling sub-upload coordinates and
pixels to match. UVs are normalised, so the image still lands correctly.

### Online LAN — `build-terracotta.sh` (7)

The **first iOS build** of [Terracotta](https://github.com/PCL-Community/Terracotta-lib)
(built on EasyTier).

Upstream [burningtnt/Terracotta](https://github.com/burningtnt/Terracotta) cannot work on
iOS at all: it embeds an EasyTier executable and spawns it as a child process, which the
iOS sandbox forbids. Only the PCL fork, which links EasyTier as a crate, is usable.

**Exactly one compile failure was iOS-specific.** `InterfaceFilter` has no iOS
implementation, and the macOS one shells out to `networksetup`, which iOS does not have.
Mobile has no way to filter interfaces, so iOS joins the Android branch (accept
everything). Everything else was dependency version drift.

**A new FFI.** Upstream exposes JNI only. But Terracotta already serves its entire control
surface over HTTP — that is what the desktop UI uses — so one native entry point suffices:

```c
uint16_t terracotta_ios_start(const char *dataDir);   // start the control server, return its port
```

Everything else is `http://127.0.0.1:<port>/state/…`. Smaller surface than hand-writing an
FFI per call, and less to break when upstream moves.

> **No TUN.** On iOS a TUN device means a Network Extension, and that entitlement cannot be
> signed with a free developer account. EasyTier's no-TUN mode applies, with its documented
> limitation: hosting works, joining needs the address entered by hand.

### LWJGL 3.4.x — `build-lwjgl-natives.sh`

Minecraft 26.2 requires 3.4.1 and 26.3 requires 3.4.3, and neither is **mixable with 3.3.3** — 3.4 introduced new callback
infrastructure (`Upcalls`, `ffi_get_closure_size`, `Callback$Descriptor`), so the Java side
and the natives must match.

The delicate part is **libffi's closure layout**. `FFI_EXEC_TRAMPOLINE_TABLE` (1 on iOS)
changes the field offsets of `ffi_closure`, and LWJGL's `ffi.h` gates that on
`defined(LWJGL_MACOS) && defined(LWJGL_arm64)` — **lowercase `arm64`**. Passing
`LWJGL_ARM64` silently selects the wrong offsets, a callback's `user_data` reads as 0, and
the game dies.

The default is **3.4.3**. The Java jars and the natives must match down to the patch
version — a 3.4.3 jar over 3.4.1 natives has no `MemoryUtil.ngetPageSize`, class
initialisation fails, and everything that touches LWJGL falls over with it.

### GLFW shims — `build-javaapp.sh` (3)

Builds the JavaApp from [Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS) while
filling in the surface LWJGL 3.4.1 widened: `glfwPlatformSupported`, `glfwGetMonitorName`,
and three IME/preedit callbacks.

It also closes a latent NPE. `glfwGetInputMode` unboxes the result of an empty `HashMap`
lookup directly, so **asking for any mode that was never set is an unconditional crash**.
Minecraft 26.2 asks for `GLFW_IME` (new in 3.4) every tick. Rather than special-casing IME,
the guard goes in the one function, with defaults matching real GLFW (`NORMAL` for the
cursor, `FALSE` otherwise).

From 26.3 it also adds the `ca.weblite.objc` stubs in `JavaPatches/`. The game looks only at
`os.name` ("Mac OS X") and calls into AppKit, whose JNA underside ends the boot on iOS with
`NoClassDefFoundError`. Shadowing `MacosUtil` itself collides with the client jar's
signature, so the stubs sit one level down.

### `build-spirv-cross.sh`

Minecraft 26.2's blaze3d wants `libspirv-cross`. Only the `spvc_*` C API is needed, so the
dylib exports just that.

### Windowing and input — `build-sdl3.sh` (50)

Minecraft 26.3 dropped GLFW for **SDL3**. SDL3 already has an iOS backend (uikit), so there is
no need to reimplement everything the way GLFW required. But that backend was written on the
premise that **SDL owns the app**, and inside a launcher the premise does not hold.

**① UIKit touched from the render thread (46)**

The game calls SDL from its render thread, and the uikit backend reaches into UIKit for
windows, screens, text input and shutdown. Off the main thread that either dies without a
log line or trips a FrontBoard trap. Those entry points are marshalled to the main thread
with `dispatch_sync_f`, or called directly when already there. The list is **generated by
parsing the declarations**, not written by hand.

> There was a guessing phase. The wrapped set grew 3 → 11 → 27 → 37 and the same exception
> fired at the same spot; printing a symbolicated stack with `NSSetUncaughtExceptionHandler`
> answered it in one go — `SDL_Vulkan_CreateSurface`. 26.3 renders with **Vulkan**, not GL.

**② A window size set without an event**

Window creation writes the real size straight into `window->w/h`, so the RESIZED that follows
carries the same values and gets filtered. The game starts its screen size from
`--width/--height` (854×480 by default) and only updates it on RESIZED, so it believed
854×480 forever, and touches drifted upward the lower you pressed. After the window is built,
the real size is announced once explicitly.

**③ GPU work in the background**

iOS refuses GPU work from a background app, and MoltenVK treats that as a lost device —
leaving to the home screen killed the game with `VK_ERROR_DEVICE_LOST`. The game ignores SDL's
notifications but pumps events every frame, so that thread is parked right there while the
app is inactive.

### `build-shaderc.sh`

26.3's render engine compiles GLSL to SPIR-V **at runtime**. One of the 45 entry points LWJGL
3.4.3 requires (`shaderc_compile_options_set_max_id_bound`) was missing from the older binary,
so this builds a pinned tag and checks the required symbols at the end, stopping if any is
absent.

---

## 2. Running it

### Prerequisites

```bash
brew install cmake ninja
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # for Terracotta
rustup target add aarch64-apple-ios
```

Xcode and the iOS SDK are required. **macOS only.**

### Building locally

```bash
git clone https://github.com/FlameLaunchers/FlameLauncher-Natives.git
cd FlameLauncher-Natives

./Scripts/build-mobileglues.sh            # renderer
./Scripts/build-terracotta.sh --release   # online LAN
./Scripts/build-spirv-cross.sh            # Minecraft 26.2
./Scripts/build-shaderc.sh                # Minecraft 26.3 shader compiler
./Scripts/build-sdl3.sh ios               # Minecraft 26.3 windowing and input
./Scripts/build-lwjgl-natives.sh          # LWJGL 3.4.3 natives
LWJGL_VERSION=3.4.3 ./Scripts/build-javaapp.sh   # Java stack for 26.2 and 26.3
```

Everything lands under `Runtime/`; take it into your launcher project and link it.

Terracotta pulls and compiles 641 crates, so **the first run takes 10–20 minutes.**

### Regenerating the patches

```bash
EMIT_PATCH_DIR=patches ./Scripts/build-mobileglues.sh
```

The unified diff in `patches/` is rewritten, so `git diff` shows exactly what changed when
upstream moves.

### Building in GitHub Actions

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs those same scripts on a
macOS runner.

| Trigger | When |
|---|---|
| **Manual dispatch** | Optionally pick targets (`-f targets="mobileglues terracotta"`) |
| **`v*` tags** | Zips the output and attaches it to the release |
| **Weekly schedule** | Mondays, 03:00 KST |

```bash
gh workflow run "iOS 네이티브 빌드" -R FlameLaunchers/FlameLauncher-Natives
```

**The weekly run is the real point of this workflow.** Because every patch stands on a hard
assert, an upstream change to an anchor stops the build — and the schedule means you learn
that **the same week** rather than months later.

Two verification steps run:

1. **Confirm the output is iOS arm64.** `cargo` and `cmake` will happily **succeed with the
   wrong target.** A macOS binary slipping through is only discovered when the app fails to
   load it, so every artefact's `lipo -info` and `LC_BUILD_VERSION` (platform 2 = iOS) is
   checked, and the job fails if it does not match.
2. **Compare against the stored patches.** If the freshly generated diff differs from
   `patches/`, the job warns and prints the difference.

---

## 3. Licence

**[AGPL-3.0](LICENSE).**

This repository holds no upstream source. But **a patch is a derivative of the file it
modifies** and carries that file's licence. Since this repository patches works under
several licences at once, the collection as a whole matches the strongest among them —
**Terracotta's AGPL-3.0**.

| Script | Upstream | Upstream licence |
|---|---|---|
| `build-mobileglues.sh` | [MobileGlues](https://github.com/MobileGL-Dev/MobileGlues) | LGPL-2.1-only |
| `build-terracotta.sh` | [Terracotta-lib](https://github.com/PCL-Community/Terracotta-lib) | **AGPL-3.0** |
| | [EasyTier](https://github.com/EasyTier/EasyTier) | LGPL-3.0 |
| `build-javaapp.sh` | [Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS) | GPL-3.0 |
| | [LWJGL](https://github.com/LWJGL/lwjgl3) | BSD-3-Clause |
| `build-lwjgl-natives.sh` | [LWJGL](https://github.com/LWJGL/lwjgl3) · [libffi](https://github.com/libffi/libffi) | BSD-3-Clause · MIT |
| `build-spirv-cross.sh` | [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) | Apache-2.0 |
| `build-sdl3.sh` | [SDL](https://github.com/libsdl-org/SDL) | Zlib |
| `build-shaderc.sh` | [shaderc](https://github.com/google/shaderc) · [glslang](https://github.com/KhronosGroup/glslang) · [SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools) | Apache-2.0 · BSD-3-Clause and others · Apache-2.0 |

If you want a single patch on its own terms: the patch to a MobileGlues file is **equally
available to you under LGPL-2.1-only**, and the patch to an Amethyst-iOS file under
GPL-3.0 — each matching the file it modifies. AGPL-3.0 applies to the collection.

Every upstream's full licence text is in [`licenses/`](licenses), verbatim.

Each patch locates its insertion point by quoting a short excerpt of the upstream file.
Those excerpts come from the repositories above and are reproduced **only to identify a
position in a file.**

See [NOTICE](NOTICE) for the details.

> Minecraft is a trademark of Mojang AB. This project is not affiliated with, endorsed by,
> or connected to Mojang AB or Microsoft.

<div align="right"><a href="#-flamelauncher-natives">⬆ Back to top</a></div>
