_profile_sh="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/profile.sh"

profile() {
    if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* && -n ${HISTFILE:-} && ${1:-} != -* ]]; then
        history -a
        HISTFILE="$HISTFILE" bash "$_profile_sh" "$@"
        local status=$?
        history -n
        return "$status"
    else
        bash "$_profile_sh" "$@"
    fi
}

if [ -n "${BASH_VERSION:-}" ]; then
    _profile_complete() {
        local word options=
        COMPREPLY=()
        for word in "${COMP_WORDS[@]:1:COMP_CWORD-1}"; do
            [ "$word" = -- ] && return
        done
        case "${COMP_WORDS[1]}" in
            --list|--help|-h) [ "$COMP_CWORD" -eq 1 ] || return ;;
        esac
        if [ "$COMP_CWORD" -eq 1 ]; then
            options="--list --help"
        fi
        COMPREPLY=($(compgen -W "$options $(profile --names)" -- "${COMP_WORDS[COMP_CWORD]}"))
    }
    complete -o bashdefault -o default -F _profile_complete profile
fi

[ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ] || return 0

platform_supported() {
    case "$1" in
        ''|all) return 0 ;;
        windows) [[ $OSTYPE == msys* || $OSTYPE == cygwin* && -n ${MSYSTEM:-} ]] ;;
        linux) [[ $OSTYPE == linux* ]] ;;
        macos) [[ $OSTYPE == darwin* ]] ;;
        unix) [[ $OSTYPE == linux* || $OSTYPE == darwin* ]] ;;
        *) [[ $OSTYPE == "$1"* ]] ;;
    esac
}

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dirs=()
for path in "$dir"/*/; do
    [[ -d $path ]] || continue
    name=${path%/}
    name=${name##*/}
    case "$name" in
        windows|linux|macos|unix)
            platform_supported "$name" || continue
            dirs+=("${path%/}")
            for group in "$path"*/; do
                [[ -d $group ]] && dirs+=("${group%/}")
            done
            ;;
        *) dirs+=("${path%/}") ;;
    esac
done

profile_names() {
    local path file name
    for path in "$@"; do
        for file in "$path"/*.sh; do
            [[ -f $file ]] || continue
            name=${file##*/}
            printf '%s\n' "${name%.sh}"
        done
    done
}

load_profiles() {
    local name file path prefix=
    tools=()
    files=()
    errors=()
    requires=()
    platform=
    if [[ -f $dir/.common.sh ]]; then
        source "$dir/.common.sh" || return $?
    fi
    for name in "$@"; do
        file=
        for path in "${dirs[@]}"; do
            if [[ -f $path/$name.sh ]]; then
                file="$path/$name.sh"
                break
            fi
        done
        if [[ -z $name || $name == *[!a-zA-Z0-9_-]* || ! -f $file ]]; then
            printf 'Unknown profile: %s\n' "$name" >&2
            return 2
        fi
        source "$file" || return $?
        prefix+="${prefix:++}$name"
    done

    if [[ ${listing:-} == 1 ]]; then
        case "$prefix" in
            ndk-*)
                export ANDROID_API="$active_api" ANDROID_ARCH="$active_arch"
                ;;
            gcc-analyzer|llvm-cov)
                export CC="$active_cc" CXX="$active_cxx"
                ;;
            msvc|clang-cl|x86|x64)
                if platform_supported windows; then
                    windows=$active_windows
                    windows_arch=${windows_arch:-$active_windows_arch}
                    windows_compiler=${windows_compiler:-$active_windows_compiler}
                fi
                ;;
        esac
    fi

    if declare -F finalize_profile >/dev/null; then
        finalize_profile || return $?
    fi

    if ! platform_supported "$platform"; then
        printf 'Profile %s requires %s\n' "$prefix" "$platform" >&2
        return 1
    fi
    export PSPREFIX="$prefix"
}

missing_requirements() {
    local tool file error
    for error in "${errors[@]}"; do
        printf '%s\n' "$error"
    done
    for tool in "${tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || printf '%s\n' "${tool/#"$HOME"\//\~\/}"
    done
    for file in "${files[@]}"; do
        [[ -f $file ]] || printf '%s\n' "${file/#"$HOME"\//\~\/}"
    done
}

list_profiles() {
    local profile names title rule width=$2 ok='✓' fail='✗'
    local listing=1 active_api="${ANDROID_API:-}" active_arch="${ANDROID_ARCH:-}"
    local active_cc="${CC:-}" active_cxx="${CXX:-}"
    local active_windows= active_windows_arch= active_windows_compiler=
    case "${CMAKE_GENERATOR:-}" in
        'Visual Studio 17 2022') active_windows=vs2022 ;;
        'Visual Studio 18 2026') active_windows=vs2026 ;;
    esac
    case "${CMAKE_GENERATOR_PLATFORM:-}" in
        Win32) active_windows_arch=x86 ;;
        x64) active_windows_arch=x64 ;;
    esac
    case "$active_cc" in
        cl) active_windows_compiler=msvc ;;
        clang-cl) active_windows_compiler=clang-cl ;;
    esac
    names=$(profile_names "$1")
    [[ -n $names ]] || return 0
    [[ -z ${listed:-} ]] || printf '\n'
    listed=1
    title=${1#"$dir"/}
    printf -v rule '%*s' "$((width + 1 - ${#title}))" ''
    rule=${rule// /─}
    if [[ -t 1 ]]; then
        title=$'\033[1;36m'"$title"$'\033[0m'
        rule=$'\033[2;90m'"$rule"$'\033[0m'
        ok=$'\033[32m✓\033[0m'
        fail=$'\033[31m✗\033[0m'
    fi
    printf '%s %s\n' "$title" "$rule"
    while IFS= read -r profile; do
        (
            load_profiles "$profile" || exit $?
            missing=$(missing_requirements)
            if [[ -n $missing ]]; then
                printf '%-*s %s missing dependency: %s' "$width" "$profile" "$fail" "${missing//$'\n'/, }"
                if [[ ${#requires[@]} -gt 0 ]]; then
                    printf '; requires profile: %s' "${requires[*]}"
                fi
                printf '\n'
            elif [[ ${#requires[@]} -gt 0 ]]; then
                printf '%-*s %s requires profile: %s\n' "$width" "$profile" "$fail" "${requires[*]}"
            else
                printf '%-*s %s\n' "$width" "$profile" "$ok"
            fi
        )
    done <<<"$names"
}

case "${1:---list}" in
    --names) profile_names "${dirs[@]}" | sort -u; exit 0 ;;
    --help|-h)
        cat <<EOF
Usage: profile <name> [<name> ...] [-- command ...]
       profile --list

Opens a Bash shell with any combination of presets and components and a prompt prefix.
Use -- before a command to run it in that environment instead.
Exit restores the parent shell. --list shows presets and each component group separately.
Listing, completion, and loading are limited to the current platform.
Presets and component groups are discovered from the subdirectories of $dir.
EOF
        if [[ -f $dir/README.md ]]; then
            printf '\nProfiles and prerequisites: %s/README.md\n' "$dir"
        fi
        exit 0 ;;
    --list)
        width=23
        for path in "${dirs[@]}"; do
            [[ -n $(profile_names "$path") ]] || continue
            name=${path#"$dir"/}
            (( ${#name} < width )) || width=$((${#name} + 1))
        done
        for path in "${dirs[@]}"; do
            list_profiles "$path" "$width"
        done
        exit 0 ;;
esac

profiles=()
while [[ $# -gt 0 && $1 != -- ]]; do
    profiles+=("$1")
    shift
done
if [[ ${#profiles[@]} -eq 0 ]]; then
    printf 'Select at least one profile; see profile --help\n' >&2
    exit 2
fi
if [[ ${1:-} == -- ]]; then
    shift
    if [[ $# -eq 0 ]]; then
        printf 'Expected a command after --\n' >&2
        exit 2
    fi
fi

load_profiles "${profiles[@]}" || exit $?
if [[ ${#requires[@]} -gt 0 ]]; then
    printf 'Profile %s requires profile: %s\n' "$PSPREFIX" "${requires[*]}" >&2
    exit 1
fi
missing=$(missing_requirements)
if [[ -n $missing ]]; then
    printf 'Missing requirements for %s: %s\n' "$PSPREFIX" "${missing//$'\n'/, }" >&2
    exit 1
fi

if [[ $# -gt 0 ]]; then
    exec "$@"
else
    exec bash --noprofile -i
fi
