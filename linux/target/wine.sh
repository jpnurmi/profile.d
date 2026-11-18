load_build
if [[ -d /opt/wine-stable/bin ]]; then
    export PATH="/opt/wine-stable/bin:$PATH"
fi
export TEST_WINE=1
tools+=(wine ld.lld x86_64-w64-mingw32-windres x86_64-w64-mingw32-g++)
