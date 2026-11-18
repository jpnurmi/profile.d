source "$dir/macos/target/ios.sh"
export CMAKE_DEFINES="${CMAKE_DEFINES:+$CMAKE_DEFINES }-DSENTRY_BACKEND=breakpad"
