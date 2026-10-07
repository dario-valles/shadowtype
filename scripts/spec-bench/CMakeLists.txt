# Builds llama-spec-bench against a llama.cpp checkout WITH common/ (the app links only libllama +
# ggml, so the speculative-decoding driver in common/speculative.cpp is not available there).
# Driven by run.sh; not part of the SwiftPM build.
cmake_minimum_required(VERSION 3.14)
project(shadowtype-spec-bench C CXX)

set(LLAMA_SRC "" CACHE PATH "llama.cpp source checkout")
if (NOT LLAMA_SRC)
    message(FATAL_ERROR "set -DLLAMA_SRC=<llama.cpp checkout>")
endif()

set(LLAMA_BUILD_COMMON   ON  CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP      OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL        OFF CACHE BOOL "" FORCE)
set(GGML_METAL           ON  CACHE BOOL "" FORCE)
add_subdirectory(${LLAMA_SRC} llama)

add_executable(llama-spec-bench spec-bench.cpp)
target_link_libraries(llama-spec-bench PRIVATE llama-common llama)
target_compile_features(llama-spec-bench PRIVATE cxx_std_17)
