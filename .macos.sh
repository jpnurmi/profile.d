macos=
macos_arch=
ios=

load_macos() {
    load_build
    macos=1
    export ERROR_ON_WARNINGS=1 SYSTEM_VERSION_COMPAT=0
}

load_macos_compiler() {
    load_macos
    local bin
    case "$1" in
        xcode)
            tools+=(xcrun)
            command -v xcrun >/dev/null 2>&1 || return 0
            bin=$(xcrun --find clang 2>/dev/null) || {
                errors+=("Xcode Clang toolchain")
                return 0
            }
            bin=${bin%/*}
            ;;
        clang-*)
            tools+=(brew)
            command -v brew >/dev/null 2>&1 || return 0
            bin=$(brew --prefix "llvm@${1#clang-}" 2>/dev/null) || {
                errors+=("Homebrew llvm@${1#clang-}")
                return 0
            }
            bin+=/bin
            ;;
    esac
    load_compiler "$bin/clang" "$bin/clang++"
}

load_macos_arch() {
    load_macos
    if [[ -n $macos_arch ]]; then
        [[ $macos_arch == "$1" ]] || errors+=("choose one macOS architecture: $macos_arch or $1")
        return 0
    fi
    macos_arch=$1
    export CMAKE_DEFINES="${CMAKE_DEFINES:+$CMAKE_DEFINES }-DCMAKE_OSX_ARCHITECTURES=$macos_arch"
}

finalize_macos() {
    [[ -n $macos$ios ]] || return 0
    [[ -z ${ANDROID_API:-}${ANDROID_NDK:-} ]] || errors+=("macOS cannot be combined with Android")
    local sdk name=macosx requirement='macOS SDK (Xcode or Command Line Tools)'
    if [[ -n $ios ]]; then
        [[ -z $macos_arch ]] || errors+=("iOS cannot be combined with a macOS architecture")
        name=iphonesimulator
        requirement='iOS simulator SDK (full Xcode)'
    fi
    if [[ $macos_arch == arm64e && $(uname -m) != arm64 ]]; then
        errors+=("arm64e tests require an Arm64 Mac")
    fi
    tools+=(xcrun)
    command -v xcrun >/dev/null 2>&1 || return 0
    sdk=$(xcrun --sdk "$name" --show-sdk-path 2>/dev/null) || {
        errors+=("$requirement")
        return 0
    }
    [[ -n $ios ]] || export SDKROOT="$sdk"
    [[ -d $sdk ]] || errors+=("$sdk")
    return 0
}
