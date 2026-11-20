cmake_minimum_required(VERSION 3.24)

# nvcc is not on PATH after a stock CUDA install
if(NOT DEFINED CMAKE_CUDA_COMPILER AND NOT DEFINED ENV{CUDACXX} AND EXISTS /usr/local/cuda/bin/nvcc)
  set(CMAKE_CUDA_COMPILER /usr/local/cuda/bin/nvcc)
endif()
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  set(CMAKE_CUDA_ARCHITECTURES native)
endif()

project(rfsoc_waterfall LANGUAGES CXX CUDA)
set(CMAKE_CXX_STANDARD 17)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(CUDAToolkit REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(UHD REQUIRED IMPORTED_TARGET uhd)

add_library(rfsoc_waterfall SHARED rfsoc_waterfall.cpp rfsoc_waterfall_gpu.cu)
target_link_libraries(rfsoc_waterfall PRIVATE PkgConfig::UHD CUDA::cufft CUDA::cudart)
set_target_properties(rfsoc_waterfall PROPERTIES CUDA_SEPARABLE_COMPILATION OFF)
