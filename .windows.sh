reset_windows() {
    local name path clean=
    for name in $(compgen -e); do
        case "${name^^}" in
            INCLUDE|EXTERNAL_INCLUDE|LIB|LIBPATH|WINDOWS_PATH|COMMANDPROMPTTYPE|DEVENVDIR|EXTENSIONSDKDIR|FRAMEWORK*|\
            PLATFORM|PREFERREDTOOLARCHITECTURE|UCRT*|UNIVERSALCRTSDK*|VCIDE*|VCINSTALL*|VCTOOLS*|VSCMD*|__VSCMD*|\
            VSINSTALL*|VS[0-9]*|VISUALSTUDIO*|WINDOWSLIB*|WINDOWSSDK*|GAMEDK*|GAMING*|GRDK*|GXDK*|XDK*|ISSCARLETT|LLVM_MINGW_ROOT)
                unset "$name"
                ;;
        esac
    done
    local paths
    IFS=: read -r -a paths <<<"$PATH"
    for path in "${paths[@]}"; do
        case "${path,,}" in
            */microsoft\ visual\ studio/*|*/windows\ kits/*|*/microsoft\ gdk/*|*/llvm-mingw/*) continue ;;
        esac
        clean+="${clean:+:}$path"
    done
    export PATH="$clean"
}

load_windows() {
    load_build
    if [[ -n $windows && $windows != "$1" ]]; then
        errors+=("choose one Windows toolchain: $windows or $1")
        return 0
    fi
    windows=$1
    case "$windows" in
        llvm-mingw) load_compiler x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++ ;;
    esac
}

load_windows_arch() {
    load_build
    if [[ -n $windows_arch && $windows_arch != "$1" ]]; then
        errors+=("choose one Windows architecture: $windows_arch or $1")
        return 0
    fi
    windows_arch=$1
}

load_windows_compiler() {
    load_build
    if [[ -n $windows_compiler && $windows_compiler != "$1" ]]; then
        errors+=("choose one Windows compiler: $windows_compiler or $1")
        return 0
    fi
    windows_compiler=$1
}

load_gdk() {
    local script=$1 argument=$2 output name value
    files+=("$script")
    [[ -f $script ]] || return 0
    [[ ${listing:-} != 1 ]] || return 0
    script=$(cygpath -w "$script")
    script=$(printf '%s' "$script" | sed 's/[^0-9A-Za-z]/^\0/g')
    output=$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /s /c " ; $script $argument >nul && set ") || {
        errors+=("GDK environment initialization failed")
        return 0
    }
    while IFS='=' read -r name value; do
        value=${value%$'\r'}
        name=${name^^}
        case "$name" in
            PATH) export PATH="$(cygpath -u -p "$value")" ;;
            INCLUDE|EXTERNAL_INCLUDE|LIB|LIBPATH|COMMANDPROMPTTYPE|DEVENVDIR|EXTENSIONSDKDIR|FRAMEWORK*|\
            PLATFORM|PREFERREDTOOLARCHITECTURE|UCRT*|UNIVERSALCRTSDK*|VCIDE*|VCINSTALL*|VCTOOLS*|VSCMD*|\
            VSINSTALL*|VS[0-9]*|VISUALSTUDIO*|WINDOWSLIB*|WINDOWSSDK*|GAMEDK*|GAMING*|GRDK*|GXDK*|XDK*|ISSCARLETT)
                [[ $name != *[!A-Z0-9_]* ]] && export "$name=$value"
                ;;
        esac
    done <<<"$output"
    [[ -n ${GAMEDK:-} && -n ${INCLUDE:-} && -n ${LIB:-} ]] || errors+=("GDK SDK environment is incomplete")
}

finalize_windows() {
    local arch=x64 output root file version
    local vs='C:\Program Files\Microsoft Visual Studio\2022\Community\'
    local generator='Visual Studio 17 2022'
    windows_arch=${windows_arch:-x64}
    if [[ -z $windows ]]; then
        requires+=("vs2022 or vs2026")
        return 0
    fi
    [[ ${#errors[@]} -eq 0 ]] || return 0
    if [[ $windows == vs2026 ]]; then
        vs='C:\Program Files\Microsoft Visual Studio\18\Community\'
        generator='Visual Studio 18 2026'
    fi
    case "$windows" in
        llvm-mingw)
            [[ -z $windows_compiler ]] || errors+=("llvm-mingw selects its compiler; omit $windows_compiler")
            [[ $windows_arch == x64 ]] || errors+=("llvm-mingw selects x64; omit x86")
            export LLVM_MINGW_ROOT='C:/LLVM-MinGW/llvm-mingw-20251202-ucrt-x86_64'
            export PATH="$(cygpath -u "$LLVM_MINGW_ROOT")/bin:$PATH"
            export TEST_MINGW=1
            export CMAKE_DEFINES="${CMAKE_DEFINES:+$CMAKE_DEFINES }-GNinja -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres -DCMAKE_ASM_MASM_COMPILER=$LLVM_MINGW_ROOT/bin/llvm-ml.exe -DCMAKE_ASM_MASM_FLAGS=-m64"
            tools+=(ninja x86_64-w64-mingw32-windres llvm-ml)
            return 0
            ;;
    esac
    windows_compiler=${windows_compiler:-msvc}
    case "$windows_compiler" in
        msvc) load_compiler cl cl ;;
        clang-cl) load_compiler clang-cl clang-cl ;;
    esac
    if [[ $windows_arch == x86 ]]; then
        export TEST_X86=1
        unset USE_SCCACHE
        [[ $windows != gdk-* ]] || errors+=("GDK profiles select x64; omit x86")
    elif [[ -n ${TEST_X86:-} ]]; then
        errors+=("use x86 for a Windows x86 target")
    fi
    [[ ${#errors[@]} -eq 0 ]] || return 0
    case "$windows" in
        gdk-desktop) load_gdk '/c/Program Files (x86)/Microsoft GDK/Command Prompts/GamingDesktopVars.cmd' GamingDesktopVS2022 ;;
        gdk-xbox-one) load_gdk '/c/Program Files (x86)/Microsoft GDK/Command Prompts/GamingXboxVars.cmd' GamingXboxVS2022 ;;
        gdk-scarlett) load_gdk '/c/Program Files (x86)/Microsoft GDK/Command Prompts/GamingXboxVars.cmd' GamingXboxScarlettVS2022 ;;
        *)
            tools+=(vcvarsall.sh)
            export VSINSTALLDIR="$vs"
            files+=("$(cygpath -u "$VSINSTALLDIR")/VC/Auxiliary/Build/vcvarsall.bat")
            [[ $windows_arch != x86 ]] || arch=x64_x86
            if [[ ${listing:-} != 1 ]] && command -v vcvarsall.sh >/dev/null 2>&1; then
                output=$(vcvarsall.sh "$arch") || {
                    errors+=("Visual Studio environment initialization failed")
                    return 0
                }
                eval "$output"
            fi
            ;;
    esac
    if [[ ${listing:-} == 1 ]]; then
        export VSINSTALLDIR="$vs"
        root=$(cygpath -u "$VSINSTALLDIR")
        file="$root/VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt"
        files+=("$file")
        if [[ -f $file ]] && { IFS= read -r version <"$file" || [[ -n $version ]]; }; then
            export VCTOOLSINSTALLDIR="$root/VC/Tools/MSVC/${version%$'\r'}"
        fi
    fi
    if [[ -n ${VCTOOLSINSTALLDIR:-} ]]; then
        arch=$windows_arch
        export PATH="$(cygpath -u "$VCTOOLSINSTALLDIR")/bin/Hostx64/$arch:$PATH"
    fi
    export CMAKE_GENERATOR="$generator"
    export CMAKE_GENERATOR_PLATFORM=x64
    case "$windows_compiler" in
        clang-cl)
            export PATH="$(cygpath -u "$VSINSTALLDIR")/VC/Tools/Llvm/x64/bin:$PATH"
            export CMAKE_GENERATOR_TOOLSET=ClangCL VS_GENERATOR_TOOLSET=ClangCL
            ;;
    esac
    if [[ $windows_arch == x86 ]]; then
        export CMAKE_GENERATOR_PLATFORM=Win32
        export CMAKE_GENERATOR_TOOLSET="${CMAKE_GENERATOR_TOOLSET:+$CMAKE_GENERATOR_TOOLSET,}host=x64"
    fi
}

finalize_zlib() {
    if [[ -z ${ZLIB_ROOT:-} ]]; then
        errors+=("ZLIB_ROOT (Zlib build)")
        return 0
    fi
    local root="$ZLIB_ROOT/install" library=zlibstaticd.lib
    if [[ $windows == llvm-mingw || -n ${TEST_MINGW:-} ]]; then
        if [[ -z ${LLVM_MINGW_ROOT:-} ]]; then
            errors+=("LLVM_MINGW_ROOT (LLVM-MinGW toolchain)")
            return 0
        fi
        root+="-mingw/${LLVM_MINGW_ROOT##*/}"
        library=libzlibstatic.a
    else
        if [[ $windows == vs2026 || ${CMAKE_GENERATOR:-} == 'Visual Studio 18 2026' ]]; then
            root+=-vs2026
        fi
        [[ -z ${TEST_X86:-} ]] || root+=-x86
    fi
    files+=("$root/lib/$library" "$root/include/zlib.h")
    root=$(cygpath -m "$root")
    export CMAKE_DEFINES="${CMAKE_DEFINES:+$CMAKE_DEFINES }-DZLIB_LIBRARY=$root/lib/$library -DZLIB_INCLUDE_DIR=$root/include"
}

is_msys() {
    [[ $OSTYPE == msys* || $OSTYPE == cygwin* && -n ${MSYSTEM:-} ]]
}
