cmake_minimum_required(VERSION 3.22.1)
project("node_runner" CXX)

# ---------------------------------------------------------------------------
# Prebuilt libnode.so (Node 18.20.4 / nodejs-mobile v18.20.4, arm64-v8a only).
# Source: JaneaSystems/nodejs-mobile release v18.20.4 – official Android binary.
# SHA-256: bd7321eaa1a7602fbe0bb87302df2d79d87835cf4363fbdd17c350dbb485c2af
# Node 18 LTS support extended to April 2025. See docs/NODE_RUNTIME.md.
# ---------------------------------------------------------------------------
add_library(node SHARED IMPORTED)
set_target_properties(node PROPERTIES
    IMPORTED_LOCATION
        "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libnode.so")

# ---------------------------------------------------------------------------
# Our thin JNI shim.  It forward-declares node::Start() without pulling in
# the full V8 / libuv headers – only the symbol linkage matters at runtime.
# ---------------------------------------------------------------------------
add_library(node_runner SHARED node_runner.cpp)

# Official Node 18 headers bundled from the same verified release as libnode.so.
target_include_directories(node_runner PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include/node")

find_library(log-lib log)
target_link_libraries(node_runner node ${log-lib})

# Ensure libnode.so is packaged inside the APK (required for dlopen).
# With gradle abiFilters=arm64-v8a and jniLibs/arm64-v8a/ already present,
# this is usually automatic; this line is a belt-and-suspenders guard.
set_target_properties(node PROPERTIES IMPORTED_NO_SONAME FALSE)
