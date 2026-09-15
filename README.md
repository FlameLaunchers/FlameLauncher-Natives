<div align="center">

# 🧱 FlameLauncher Natives

**마인크래프트 자바 런처를 iOS 에서 돌리기 위한 네이티브 빌드 스크립트 모음.**

[![Platform](https://img.shields.io/badge/target-iOS%20arm64-000000?logo=apple&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

</div>

---

iOS 에서 마인크래프트 자바 에디션을 돌리려면 렌더러·LWJGL·GLFW·P2P 네트워킹을
전부 `aarch64-apple-ios` 로 빌드해야 하는데, **업스트림 어디에도 iOS 빌드가 없습니다.**
안드로이드 빌드는 있어도 그대로는 컴파일조차 되지 않습니다.

이 저장소는 그 간격을 메우는 패치를 모아 둔 곳입니다.
[FlameLauncher for iOS](https://github.com/FlameLaunchers/FlameLauncher-iOS) 에서
쓰려고 만들었지만 **앱 코드를 전혀 참조하지 않습니다** — PojavLauncher iOS · Amethyst 등
다른 런처에서도 그대로 쓸 수 있습니다.

## 구성

```
Scripts/     빌드 스크립트. CI 가 정확히 이것을 돌린다.
patches/     각 스크립트가 만들어 내는 diff 전체 (읽을 수 있는 형태)
licenses/    패치 대상 업스트림의 라이선스 전문
```

**패치한 업스트림 트리를 통째로 두지 않습니다.** 서브모듈까지 합치면 수백 MB 인데
그중 바뀐 건 974줄입니다. 대신 빌드 시점에 클론 → 패치 → 빌드하고, 그 결과 diff 를
`patches/` 에 읽을 수 있게 남깁니다.

```bash
EMIT_PATCH_DIR=patches ./Scripts/build-mobileglues.sh   # 다시 뽑기
```

| 스크립트 | 패치 | assert | diff | 산출물 |
|---|---|---|---|---|
| `build-mobileglues.sh` | 19 | 29 | 766줄 | `libmobileglues.dylib` |
| `build-terracotta.sh` | 7 | 7 | 137줄 | `libterracotta.a` |
| `build-javaapp.sh` | 3 | 3 | 71줄 | `lwjgl.jar` · `launcher.jar` |
| `build-lwjgl-natives.sh` | — | — | — | `liblwjgl*.dylib` (3.4.1) |
| `build-spirv-cross.sh` | — | — | — | `libspirv-cross.dylib` |

업스트림이 움직이면 **그 자리에서 멈춥니다** — 모든 패치에 하드 `assert` 가 걸려 있습니다.
조용히 빗나가서 엉뚱한 바이너리를 만드는 것보다 낫습니다.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) 이 macOS 러너에서
위 스크립트를 그대로 돌립니다.

- **수동 실행** — 대상을 골라 돌릴 수 있습니다 (`mobileglues terracotta` 처럼)
- **`v*` 태그** — 산출물을 zip 으로 묶어 릴리스에 붙입니다
- **주 1회 예약** — 이게 진짜 목적에 가깝습니다. 우리 패치는 전부 하드 assert 위에
  서 있어서 업스트림이 앵커를 건드리면 빌드가 멈춥니다. 몇 달 뒤가 아니라 **그 주에**
  알기 위해 돌립니다.

검증 단계가 둘 있습니다.

1. **iOS arm64 인지 확인** — `cargo`·`cmake` 는 타깃을 틀려도 조용히 성공합니다.
   맥용 바이너리가 섞여 나오면 앱에 넣는 순간에야 알게 되므로, 모든 산출물의
   `lipo -info` 와 `LC_BUILD_VERSION`(platform 2 = iOS)을 확인하고 아니면 실패시킵니다.
2. **저장된 패치와 대조** — 새로 뽑은 diff 가 `patches/` 와 다르면 경고하고 차이를 찍습니다.

---

## 사용

```bash
brew install cmake ninja xcodegen        # 공통
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # 테라코타용

./Scripts/build-mobileglues.sh           # 렌더러
./Scripts/build-terracotta.sh --release  # 온라인 LAN
./Scripts/build-spirv-cross.sh           # 마인크래프트 26.2
./Scripts/build-lwjgl-natives.sh         # LWJGL 3.4.1 네이티브
LWJGL_VERSION=3.4.1 ./Scripts/build-javaapp.sh   # 26.2 용 자바 스택
```

산출물은 `Runtime/` 아래에 떨어집니다. 런처 프로젝트로 가져가 링크하면 됩니다.

---

## 무엇을 고치는가

### `build-mobileglues.sh` — 렌더러 (19개 패치)

MobileGlues 는 데스크톱 GL 을 GLES 로 번역합니다. 업스트림 CMake 에 iOS 분기가 있지만
**한 번도 컴파일된 적이 없습니다.** 릴리스는 APK 뿐입니다.

**컴파일이 안 되는 것** — Mach-O 에 없는 `__attribute__((alias))`, 리눅스 syscall 번호
`__NR_gettid`, GNU ld 전용 `-Wl,-Bsymbolic-functions`.

**iOS 호스트가 ES 3.0 이라 생기는 것.** 안드로이드 호스트는 ES 3.2 지만 iOS 는
ANGLE Metal = **ES 3.0** 입니다. ANGLE 은 ES 3.2 심볼을 전부 내보내되 ES 3.0
컨텍스트에서는 호출을 거부합니다 — **오류 없이 조용히 아무 일도 일어나지 않습니다.**
`glFramebufferTexture`(3.2)와 `glGetTexLevelParameteriv`(3.1)에 폴백을 넣습니다.

**셰이더가 안 되던 진짜 이유.** Iris 를 켜면 엔티티와 손에 든 아이템이 보이지 않았습니다.

> Metal 은 정점 포맷의 **부호(signedness)** 가 셰이더 선언과 일치해야 합니다.
> GL 과 GLES 는 요구하지 않습니다.

`ivec3` 로 선언된 속성에 `GL_UNSIGNED_SHORT` 를 물리면 GL 에서는 통과하지만 Metal 은
파이프라인 생성 자체를 거부합니다. 그리기 직전에 프로그램의 정수 속성을 훑어 부호를
맞춰 다시 걸어 줍니다.

> 이걸 찾는 데 오래 걸린 이유가 있습니다. MobileGlues 의 `CHECK_GL_ERROR` 는
> `#if GLOBAL_DEBUG` 아래라 기본 빌드에서 **226군데가 전부 `{}` 로 컴파일됩니다.**
> "GL 오류가 하나도 없다"는 관찰에 아무 근거가 없었습니다. 그래서 오류 로그를
> 상시 켜는 패치를 같이 넣습니다.

**심볼이 자기 자신을 건너뛰던 것.** `glx/lookup.cpp` 의 애플 분기가 이렇습니다.

```c
return dlsym((void*)(~(uintptr_t)0), name);
```

`~0` = `(void*)-1` 인데 이 값의 뜻이 플랫폼마다 다릅니다. **안드로이드(LP64)에서는
`RTLD_DEFAULT` 지만 애플에서는 `RTLD_NEXT`** — *자기 자신을 건너뛰고* 다음 객체에서
찾습니다. 그래서 MobileGlues 가 자기 `gl*` 을 절대 돌려주지 않고 ANGLE 것을 줍니다.

LWJGL 3.3.3 은 이 경로를 안 타서 드러나지 않습니다. 3.4.1 이 `GetProcAddress` 후보에
`eglGetProcAddress` 를 추가하면서 밟습니다 — 그러면 **모든 GL 함수**가 ANGLE 로 빠지고,
`glGetIntegerv` 가 ES 3.0 을 보고해 LWJGL 이 GL 3.3+ 진입점을 하나도 매핑하지 않습니다.
마인크래프트 26.2 가 `glGenSamplers` 널 포인터로 죽습니다. `RTLD_SELF` 로 고칩니다.

**메모리.** 서버 리소스팩이 크면 마인크래프트가 8192² 아틀라스를 만듭니다 — RGBA8 로
268MB, 업로드 버퍼까지 두 벌이면 iOS 예산(아이폰 15 = 약 3GB)을 넘겨 프로세스가
jetsam 으로 죽습니다. 남은 여유로 감당이 안 될 때만 2의 거듭제곱으로 줄여서 잡고,
부분 업로드의 좌표와 픽셀도 같은 비율로 줄입니다. UV 는 정규화 좌표라 그림은 맞습니다.

### `build-terracotta.sh` — 온라인 LAN (7개 패치)

[Terracotta](https://github.com/PCL-Community/Terracotta-lib)(EasyTier 기반)의
**첫 iOS 빌드**입니다.

원본 [burningtnt/Terracotta](https://github.com/burningtnt/Terracotta) 는 iOS 에서
불가능합니다 — EasyTier 실행 파일을 품고 있다가 자식 프로세스로 띄우는데, iOS 샌드박스가
프로세스 생성을 막습니다. 라이브러리로 링크되게 갈라져 나온 PCL 포크만 쓸 수 있습니다.

놀랍게도 **iOS 고유의 컴파일 실패는 한 군데뿐**입니다. `InterfaceFilter` 에 iOS 구현이
없는데, macOS 판은 `networksetup` CLI 를 부르고 iOS 엔 그 명령이 없습니다. 모바일에서는
인터페이스를 걸러낼 수단이 없으므로 안드로이드 분기(전부 통과)에 얹습니다.
나머지는 전부 의존성 버전이 어긋난 것입니다.

**FFI 를 새로 냅니다.** 업스트림은 JNI 뿐입니다. 그런데 테라코타는 제어 표면을 이미
HTTP 로 전부 내놓고 있어서(데스크톱 UI 가 그걸 씁니다), 네이티브 진입점 하나면 됩니다.

```c
uint16_t terracotta_ios_start(const char *dataDir);   // 제어 서버를 띄우고 포트 반환
```

나머지는 `http://127.0.0.1:<포트>/state/…` 로 부릅니다. 호출마다 FFI 를 손으로 짜는
것보다 표면이 작고, 업스트림이 API 를 바꿔도 깨질 자리가 적습니다.

> **TUN 은 쓰지 않습니다.** iOS 에서 TUN 은 Network Extension 뿐이고 그 권한은 무료
> 개발자 계정으로 서명되지 않습니다. EasyTier 의 no-TUN 모드로 동작하므로 문서화된
> 제약이 그대로 적용됩니다 — 방장 노릇은 되고, 참가는 주소를 직접 넣어야 합니다.

### `build-lwjgl-natives.sh` — LWJGL 3.4.1

마인크래프트 26.2 가 요구합니다. 3.3.3 과 **섞을 수 없습니다** — 3.4 에서 콜백
인프라(`Upcalls`, `ffi_get_closure_size`, `Callback$Descriptor`)가 새로 생겨서 자바와
네이티브가 같은 버전이어야 합니다.

가장 까다로운 부분은 **libffi 의 클로저 레이아웃**입니다. `FFI_EXEC_TRAMPOLINE_TABLE`
(iOS 는 1)이 켜지면 `ffi_closure` 의 필드 오프셋이 달라지는데, LWJGL 의 `ffi.h` 는
이걸 `defined(LWJGL_MACOS) && defined(LWJGL_arm64)` 로 가릅니다 — **소문자 `arm64`**
입니다. `LWJGL_ARM64` 로 넘기면 조용히 틀린 오프셋이 잡히고, 콜백의 `user_data` 가
0 으로 읽혀 게임이 죽습니다.

### `build-javaapp.sh` — GLFW 심 (3개 패치)

[Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS) 의 JavaApp 을 빌드하면서
LWJGL 3.4.1 에서 넓어진 표면을 메웁니다 — `glfwPlatformSupported`,
`glfwGetMonitorName`, IME/preedit 콜백 3종.

그리고 잠재 NPE 하나를 막습니다. `glfwGetInputMode` 가 빈 `HashMap` 의 결과를 그대로
언박싱해서, **설정한 적 없는 모드를 물으면 무조건 죽습니다.** 마인크래프트 26.2 가 매 틱
`GLFW_IME`(3.4 신규)를 묻습니다. IME 만 특별히 봐 주는 대신 함수 한 곳에서 막고,
기본값은 실제 GLFW 와 맞춥니다(커서는 `NORMAL`, 그 밖엔 `FALSE`).

### `build-spirv-cross.sh`

마인크래프트 26.2 의 blaze3d 가 `libspirv-cross` 를 요구합니다. `spvc_*` C API 만
필요하므로 그것만 내보내는 dylib 을 만듭니다.

---

## 업스트림

| | 라이선스 |
|---|---|
| [MobileGlues](https://github.com/MobileGL-Dev/MobileGlues) | LGPL-2.1-only |
| [Terracotta-lib](https://github.com/PCL-Community/Terracotta-lib) | AGPL-3.0 |
| [EasyTier](https://github.com/EasyTier/EasyTier) | LGPL-3.0 |
| [Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS) | GPL-3.0 |
| [LWJGL](https://github.com/LWJGL/lwjgl3) | BSD-3-Clause |
| [libffi](https://github.com/libffi/libffi) | MIT |
| [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) | Apache-2.0 |

---

## 라이선스

**AGPL-3.0.** 이 저장소는 업스트림 소스를 담고 있지 않지만, 각 패치는 자기가 고치는
파일의 **파생물**이라 그 파일의 라이선스를 함께 따릅니다. 가장 강한 것이 테라코타의
AGPL-3.0 이라 저장소 전체를 그에 맞춥니다.

업스트림 7곳의 라이선스 전문을 [`licenses/`](licenses) 에 그대로 넣어 뒀습니다.
어느 패치가 어느 라이선스를 따르는지는 [NOTICE](NOTICE) 의 표에 있습니다.

> Minecraft 는 Mojang AB 의 상표입니다. 이 프로젝트는 Mojang AB · Microsoft 와
> 아무 관련이 없습니다.
