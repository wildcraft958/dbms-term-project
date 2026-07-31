cmake_minimum_required(VERSION 3.14)
project(solr_benchmark VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Default to an optimized build so a plain `cmake ..` doesn't produce an
# unoptimized binary that skews QPS measurements.
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# Find required packages
find_package(CURL REQUIRED)

# Header-only includes
include_directories(${CMAKE_SOURCE_DIR}/include)

# Source files
set(SOURCES
    src/main.cpp
    src/connection_pool.cpp
    src/metrics.cpp
    src/benchmark_runner.cpp
)

# Executable
add_executable(solr_benchmark ${SOURCES})
target_link_libraries(solr_benchmark PRIVATE CURL::libcurl pthread)
target_compile_options(solr_benchmark PRIVATE -Wall -Wextra)

# Install
install(TARGETS solr_benchmark DESTINATION bin)

message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "CURL found: ${CURL_VERSION_STRING}")
