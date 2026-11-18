load_build
ios=1
tools+=(xcodebuild)
export CMAKE_GENERATOR=Xcode
export CMAKE_DEFINES="${CMAKE_DEFINES:+$CMAKE_DEFINES }-DCMAKE_SYSTEM_NAME=iOS"
