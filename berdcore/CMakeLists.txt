cmake_minimum_required(VERSION 3.20)
project(berdcore VERSION 1.0.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# iOS cross-compilation support
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(CMAKE_OSX_SYSROOT "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.0.sdk")
    set(CMAKE_OSX_ARCHITECTURES "arm64")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -stdlib=libc++")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -stdlib=libc++")
    
    # Use iOS-compatible paths for dependencies
    set(CURL_INCLUDE_DIRS "/opt/homebrew/opt/curl/include")
    set(CURL_LIBRARIES "/opt/homebrew/opt/curl/lib/libcurl.dylib")
    set(JSONCPP_INCLUDE_DIRS "/opt/homebrew/include")
    set(JSONCPP_LIBRARIES "/opt/homebrew/lib/libjsoncpp.dylib")
    
    # For iOS, we need to link statically and avoid dynamic libraries
    set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
else()
    # macOS paths
    set(CURL_INCLUDE_DIRS "/opt/homebrew/opt/curl/include")
    set(CURL_LIBRARIES "/opt/homebrew/opt/curl/lib/libcurl.dylib")
    set(JSONCPP_INCLUDE_DIRS "/opt/homebrew/include")
    set(JSONCPP_LIBRARIES "/opt/homebrew/lib/libjsoncpp.dylib")
endif()

# Enable NEON and FP16 for ARM64
if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
    add_compile_options(-march=armv8.2-a+fp16)
endif()

# ============================================================================
# Options
# ============================================================================

option(BERDCORE_BUILD_SHARED "Build shared library" OFF)
option(BERDCORE_BUILD_STATIC "Build static library" ON)
option(BERDCORE_BUILD_TESTS "Build tests" OFF)

# ============================================================================
# Dependencies
# ============================================================================

# Cactus Compute - We'll compile it as part of berdcore
# User should clone it to: ${CMAKE_SOURCE_DIR}/../cactus
set(CACTUS_DIR "${CMAKE_SOURCE_DIR}/../cactus" CACHE PATH "Path to Cactus repository")

if(EXISTS "${CACTUS_DIR}/cactus/cactus.h")
    message(STATUS "Found Cactus at: ${CACTUS_DIR}")
    set(CACTUS_INCLUDE_DIR "${CACTUS_DIR}/cactus")
    set(CACTUS_FOUND TRUE)
    
    # Add Cactus source files (these will be compiled into berdcore)
    file(GLOB_RECURSE CACTUS_SOURCES "${CACTUS_DIR}/cactus/*.cpp")
    message(STATUS "Cactus sources: ${CACTUS_SOURCES}")
else()
    message(WARNING "Cactus not found at ${CACTUS_DIR}")
    message(STATUS "Please clone: git clone https://github.com/cactus-compute/cactus.git ${CACTUS_DIR}")
    message(STATUS "berdcore will build without Cactus support (placeholder only)")
    set(CACTUS_FOUND FALSE)
    set(CACTUS_INCLUDE_DIR ${CMAKE_SOURCE_DIR}/include)
    set(CACTUS_SOURCES "")
endif()

# libcurl for HTTP requests
# find_package(CURL REQUIRED)
set(CURL_INCLUDE_DIRS "/opt/homebrew/opt/curl/include")
set(CURL_LIBRARIES "/opt/homebrew/opt/curl/lib/libcurl.dylib")

# jsoncpp for JSON parsing
# find_package(PkgConfig REQUIRED)
# pkg_check_modules(JSONCPP REQUIRED jsoncpp)

# Add Homebrew paths if pkg-config doesn't find them
set(JSONCPP_INCLUDE_DIRS "/opt/homebrew/include")
set(JSONCPP_LIBRARIES "/opt/homebrew/lib/libjsoncpp.dylib")

# Ensure we can find the library
link_directories(/opt/homebrew/lib /opt/homebrew/opt/curl/lib)

# ============================================================================
# Source Files
# ============================================================================

set(BERDCORE_HEADERS
    include/berdcore.h
)

set(BERDCORE_SOURCES
    src/berdcore.cpp
    ${CACTUS_SOURCES}
)

# ============================================================================
# Library Targets
# ============================================================================

if(BERDCORE_BUILD_SHARED)
    add_library(berdcore_shared SHARED ${BERDCORE_SOURCES} ${BERDCORE_HEADERS})
    target_include_directories(berdcore_shared
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
            $<INSTALL_INTERFACE:include>
        PRIVATE
            ${CACTUS_INCLUDE_DIR}
            /opt/homebrew/opt/curl/include
            /opt/homebrew/include
    )
    target_link_libraries(berdcore_shared
        PRIVATE
            ${CURL_LIBRARIES}
            /opt/homebrew/lib/libjsoncpp.dylib
    )
    set_target_properties(berdcore_shared PROPERTIES
        OUTPUT_NAME berdcore
        VERSION ${PROJECT_VERSION}
        SOVERSION ${PROJECT_VERSION_MAJOR}
    )
endif()

if(BERDCORE_BUILD_STATIC)
    add_library(berdcore_static STATIC ${BERDCORE_SOURCES} ${BERDCORE_HEADERS})
    target_include_directories(berdcore_static
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
            $<INSTALL_INTERFACE:include>
        PRIVATE
            ${CACTUS_INCLUDE_DIR}
            /opt/homebrew/opt/curl/include
            /opt/homebrew/include
    )
    target_link_libraries(berdcore_static
        PRIVATE
            ${CURL_LIBRARIES}
            /opt/homebrew/lib/libjsoncpp.dylib
    )
    set_target_properties(berdcore_static PROPERTIES
        OUTPUT_NAME berdcore
        POSITION_INDEPENDENT_CODE ON
    )
endif()

# ============================================================================
# Installation
# ============================================================================

install(FILES ${BERDCORE_HEADERS} DESTINATION include)

if(BERDCORE_BUILD_SHARED)
    install(TARGETS berdcore_shared
        LIBRARY DESTINATION lib
        ARCHIVE DESTINATION lib
        RUNTIME DESTINATION bin
    )
endif()

if(BERDCORE_BUILD_STATIC)
    install(TARGETS berdcore_static
        ARCHIVE DESTINATION lib
    )
endif()

# ============================================================================
# Tests
# ============================================================================

if(BERDCORE_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
