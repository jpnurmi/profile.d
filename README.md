# profile.d

Composable shell profiles for selecting compilers, analyzers, and targets,
mainly intended for building and testing
[sentry-native](https://github.com/getsentry/sentry-native).

## Setup

Clone this repository to `~/.profile.d` and add to `.bashrc` or `.zshrc`:

```sh
source ~/.profile.d/profile.sh
```

Profiles export `PSPREFIX` for the prompt, for example
`PS1='${PSPREFIX:+($PSPREFIX) }\u@\h:\w\$ '`.

## Usage

```sh
profile --list                      # profiles for this platform and missing dependencies
profile gcc-14                      # open a child shell, exit to return
profile clang-20 asan llvm-cov      # compose components
profile clang-20-asan-cov           # or use a preset
profile gcc-14 -- .venv/bin/pytest -v tests
```

Choose one compiler and one target, then add analyzers. Each invocation starts
from a clean build environment. ASan and TSan cannot be combined, and Valgrind
cannot be combined with either. The variables are interpreted by sentry-native's
pytest harness; plain CMake uses only `CC`/`CXX` and the `CMAKE_GENERATOR*`
variables.

| Directory | Platform |
| --- | --- |
| `linux` | Linux, including WSL |
| `macos` | macOS |
| `unix` | Linux and macOS |
| `windows` | Git Bash |
| `env` | All |

Presets mirror the jobs in sentry-native's CI workflow, using the local OS
and tools.

## Android

```sh
profile ndk-27 android-31
profile android-36-asan
```

Requires `ANDROID_HOME` and a running device or emulator matching the profile's
API and ABI. `ANDROID_ARCH` defaults to the host architecture unless a preset
pins it.

## E2E

```sh
profile clang-20 e2e
```

Sets `SENTRY_E2E_DSN` from `SENTRY_DSN_NATIVE`. The token comes from
`SENTRY_E2E_AUTH_TOKEN`, or from `[e2e]` or `[auth]` `token` in
`~/.sentryclirc`, with `event:read` and `project:read` scopes.

## Windows

```sh
profile vs2026 x86 clang-cl
profile llvm-mingw
profile gdk-desktop
```

Visual Studio installation (`vs2022`, `vs2026`), architecture (`x64`, `x86`),
and compiler (`msvc`, `clang-cl`) are independent components. The `zlib`
component requires `ZLIB_ROOT`, with Zlib 1.3.1 static debug libraries installed
in `$ZLIB_ROOT/install[-vs2026][-x86]` or
`$ZLIB_ROOT/install-mingw/<llvm-mingw-package>`.

## Adding profiles

Add `<name>.sh` to a platform directory for a preset, or to a component group
below it. Files starting with a dot are shared helpers. Profiles are sourced and
can set any environment variables. See `profile.sh` for the `tools`, `files`,
`errors`, and `requires` arrays used for dependency checks, and `.common.sh`
for the build helpers.
