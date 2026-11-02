cmake_minimum_required(VERSION 3.22)
project(rawdecoder)

file(GLOB_RECURSE LIBRAW_SRC ${CMAKE_CURRENT_SOURCE_DIR}/libraw/src/*.cpp)
add_library(libraw STATIC ${LIBRAW_SRC})
target_include_directories(libraw PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/libraw)
target_compile_definitions(libraw PRIVATE LIBRAW_NODLL LIBRAW_NO_OPENMP LIBRAW_NOTHREADS)
target_compile_options(libraw PRIVATE -O2 -fPIC)

add_library(rawdecoder SHARED rawdecoder_napi.cpp)
target_include_directories(rawdecoder PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/libraw)
target_compile_features(rawdecoder PRIVATE cxx_std_17)
target_link_libraries(rawdecoder PUBLIC libraw libace_napi.z.so libhilog_ndk.z.so)
