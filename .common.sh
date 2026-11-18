build=
windows=
windows_arch=
windows_compiler=
zlib=
sccache=
source "$dir/.windows.sh"
source "$dir/.macos.sh"

load_build() {
    [[ -n $build ]] && return 0
    build=1
    unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS \
        CMAKE_DEFINES CMAKE_GENERATOR CMAKE_GENERATOR_PLATFORM \
        CMAKE_GENERATOR_TOOLSET CMAKE_TOOLCHAIN_FILE CMAKE_PREFIX_PATH \
        RUN_ANALYZER ERROR_ON_WARNINGS LLVM_COV LLVM_PROFDATA LLVM_PROFILE_FILE \
        TEST_X86 TEST_ARM32 TEST_QEMU TEST_WINE TEST_MINGW \
        MINGW_PKG_PREFIX MINGW_ASM_MASM_COMPILER MINGW_ASM_MASM_FLAGS \
        USE_SCCACHE SCCACHE_GHA_ENABLED VS_GENERATOR_TOOLSET \
        ANDROID_API ANDROID_NDK ANDROID_ARCH SYSTEM_PYTHON \
        SYSTEM_VERSION_COMPAT SDKROOT UTF8_TEST_CWD \
        PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR \
        ASAN_OPTIONS LSAN_OPTIONS TSAN_OPTIONS

    if is_msys; then
        reset_windows
    fi
    export SENTRY_TEST_OOM_LIMIT=4095
}

load_compiler() {
    load_build
    if [[ -n ${CC:-} && $CC != "$1" ]]; then
        errors+=("choose one compiler: $CC or $1")
        return 0
    fi
    export CC="$1" CXX="$2"
}

load_android() {
    load_build
    if [[ -n ${ANDROID_API:-} ]]; then
        errors+=("choose one Android target")
        return 0
    fi
    export ANDROID_API="$1"
    if [[ -n ${2:-} ]]; then
        load_ndk "$2"
    fi
    if [[ -n ${3:-} ]]; then
        export ANDROID_ARCH="$3"
    fi
}

load_ndk() {
    load_build
    if [[ -n ${ANDROID_NDK:-} && $ANDROID_NDK != "$1" ]]; then
        errors+=("choose one NDK: $ANDROID_NDK or $1")
        return 0
    fi
    export ANDROID_NDK="$1"
}

finalize_android() {
    if [[ -d ${ANDROID_HOME:-} ]]; then
        [[ -z ${ANDROID_API:-} ]] || tools+=("$ANDROID_HOME/platform-tools/adb")
    else
        errors+=("ANDROID_HOME (Android SDK)")
    fi

    if [[ -z ${ANDROID_NDK:-} ]]; then
        if [[ -d ${ANDROID_NDK_HOME:-} ]]; then
            export ANDROID_NDK="${ANDROID_NDK_HOME##*/}"
        else
            errors+=("ANDROID_NDK_HOME (Android NDK)")
        fi
    fi

    if [[ -z ${ANDROID_API:-} ]]; then
        requires+=("android-<api>")
    elif [[ -z ${ANDROID_ARCH:-} ]]; then
        case "$(uname -m)" in
            x86_64) export ANDROID_ARCH=x86_64 ;;
            arm64|aarch64) export ANDROID_ARCH=arm64-v8a ;;
            *) errors+=("unsupported host architecture: $(uname -m)") ;;
        esac
    fi

    if [[ -n ${ANDROID_HOME:-} && -n ${ANDROID_NDK:-} ]]; then
        export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$ANDROID_NDK"
        export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
        files+=("$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake")
    fi
}

add_analyzer() {
    load_build
    if ! has_analyzer "$1"; then
        export RUN_ANALYZER="${RUN_ANALYZER:+$RUN_ANALYZER,}$1"
    fi
}

has_analyzer() {
    [[ ,${RUN_ANALYZER:-}, == *",$1,"* ]]
}

finalize_build() {
    [[ -n $build ]] || return 0
    finalize_macos || return $?

    if [[ -n $windows$windows_arch$windows_compiler ]]; then
        platform=msys
        [[ -z ${ANDROID_API:-}${ANDROID_NDK:-}${TEST_WINE:-} ]] || errors+=("Windows cannot be combined with Android or Wine")
        [[ -z ${RUN_ANALYZER:-} ]] || errors+=("Windows analyzer combinations are not supported by these profiles")
        if is_msys; then
            platform=$OSTYPE
            finalize_windows || return $?
        fi
        tools+=(cmake python)
        [[ -z ${CC:-} ]] || tools+=("$CC" "$CXX")
    elif [[ -n $ios ]]; then
        tools+=(cmake)
    elif [[ -n ${ANDROID_API:-}${ANDROID_NDK:-} ]]; then
        tools+=(cmake make python3)
        finalize_android
        [[ -z ${CC:-} ]] || errors+=("Android uses its NDK compiler; omit the host compiler profile")
        [[ -z ${TEST_X86:-}${TEST_WINE:-} ]] || errors+=("Android cannot be combined with x86 or Wine")
        if has_analyzer valgrind || has_analyzer kcov || has_analyzer llvm-cov || has_analyzer gcc; then
            errors+=("the Android test harness supports sanitizer profiles, not host analyzer or coverage profiles")
        fi
    else
        tools+=(cmake make python3)
        if [[ -n ${CC:-} ]]; then
            tools+=("$CC" "$CXX")
        else
            tools+=(cc c++)
        fi
    fi

    if has_analyzer asan && has_analyzer tsan; then
        errors+=("ASan and TSan cannot be combined")
    fi
    if has_analyzer valgrind && { has_analyzer asan || has_analyzer tsan; }; then
        errors+=("Valgrind cannot be combined with ASan or TSan")
    fi
    if has_analyzer gcc && [[ ${CC:-} != gcc* ]]; then
        requires+=("gcc-<version>")
    fi
    if has_analyzer llvm-cov; then
        local compiler=${CC##*/} bin=
        if [[ $compiler == clang || $compiler == clang-[0-9]* ]]; then
            [[ $CC != */* ]] || bin="${CC%/*}/"
            export LLVM_COV="${bin}llvm-cov${compiler#clang}" LLVM_PROFDATA="${bin}llvm-profdata${compiler#clang}"
            tools+=("$LLVM_COV" "$LLVM_PROFDATA")
        else
            requires+=("clang-<version>")
        fi
    fi
}

finalize_profile() {
    finalize_build || return $?
    if [[ -n $zlib ]]; then
        if is_msys; then
            finalize_zlib
        else
            platform=msys
        fi
    fi
    if [[ -n $sccache && $windows_arch != x86 ]]; then
        export USE_SCCACHE=1
        tools+=(sccache)
    fi
}
