# uhd_zcu216 -- UHD 4.6 out-of-tree device module for the ZCU216 RFSoC.
# Samples travel over DPDK only (lib/zcu216_dpdk.cpp): libdpdk is required.
#
#   cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
#   sudo cmake --install build   # module -> <UHD libdir>/uhd/modules,
#                                # wrapper zcu216-uhd -> /usr/local/bin
#   zcu216-uhd <uhd app> [args]  # root (sudo), UHD_MODULE_PATH, CPU affinity
cmake_minimum_required(VERSION 3.16)
project(uhd_zcu216 CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# The UHD this module targets is pinned as the git submodule ../uhd (tag
# v4.6.0.0, the EttusResearch/uhd source; build and install it to a prefix and
# pass -DUHD_ROOT=<prefix> if the distribution has no UHD 4.6). The module must
# be built against the same 4.6 headers and library the UHD apps load.
#
# Pin the UHD the installed tools actually run with. UHDConfig.cmake searches
# CMAKE_INSTALL_PREFIX (/usr/local) and pkg-config first, so a stray source
# build there (wei-duke-wsp5 has libuhd 4.7 + headers in /usr/local) would win
# and the module would drag a second libuhd into a 4.6 process: its device
# registration would land in the wrong library and type=zcu216 would never be
# found. Pre-seeding the cache variables makes the config keep these.
set(UHD_ROOT "/usr" CACHE PATH "Prefix of the UHD 4.6 install used by the apps")
find_library(UHD_LIBRARIES NAMES uhd
    PATHS ${UHD_ROOT}/lib/${CMAKE_LIBRARY_ARCHITECTURE} ${UHD_ROOT}/lib ${UHD_ROOT}/lib64
    NO_DEFAULT_PATH)
find_path(UHD_INCLUDE_DIRS NAMES uhd/version.hpp PATHS ${UHD_ROOT}/include NO_DEFAULT_PATH)
find_package(UHD 4.6 REQUIRED)
file(STRINGS "${UHD_INCLUDE_DIRS}/uhd/version.hpp" _uhd_ver REGEX "#define UHD_VERSION ")
string(REGEX REPLACE ".*UHD_VERSION ([0-9]+).*" "\\1" _uhd_ver "${_uhd_ver}")
get_filename_component(_uhd_real "${UHD_LIBRARIES}" REALPATH)
message(STATUS "uhd_zcu216: UHD headers ${UHD_INCLUDE_DIRS} (UHD_VERSION ${_uhd_ver}), library ${_uhd_real}; "
               "pinned source: rfsoc_lib/uhd/uhd (v4.6.0.0)")
if(_uhd_ver LESS 4060000 OR _uhd_ver GREATER_EQUAL 4070000 OR NOT _uhd_real MATCHES "libuhd\\.so\\.4\\.6")
    message(FATAL_ERROR "uhd_zcu216 must be built against UHD 4.6 (got ${_uhd_ver}, ${_uhd_real}); set -DUHD_ROOT=")
endif()
find_package(Threads REQUIRED)
# UHD's public headers pull in Boost (ref_vector, equality_comparable, ...)
find_package(Boost REQUIRED)

# The sample kernels are one 128-bit SSE implementation (lib/zcu216_kernels.cpp):
# native on x86, NEON on aarch64 through sse2neon (submodule host/sse2neon,
# DLTcollab/sse2neon, a single header).
set(_sse2neon_inc "")
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
    set(_sse2neon_inc "${CMAKE_CURRENT_SOURCE_DIR}/sse2neon")
    if(NOT EXISTS "${_sse2neon_inc}/sse2neon.h")
        message(FATAL_ERROR "aarch64 build needs sse2neon: git submodule update --init --depth 1 host/sse2neon")
    endif()
    include_directories(BEFORE "${_sse2neon_inc}")
    message(STATUS "uhd_zcu216: aarch64, SIMD kernels through sse2neon (${_sse2neon_inc})")
endif()

add_library(uhd_zcu216 MODULE
    lib/zcu216_util.cpp
    lib/zcu216_device.cpp
    lib/zcu216_rx_streamer.cpp
    lib/zcu216_tx_streamer.cpp
    lib/zcu216_otw.cpp
    lib/zcu216_kernels.cpp
    lib/zcu216_pool.cpp
)
# GCC ignores -I/usr/include (a system dir) and searches /usr/local/include
# first, so <uhd/...> would still resolve to a stray /usr/local UHD. Expose the
# pinned headers through a private directory that is searched before both.
set(_uhd_inc_shim "${CMAKE_CURRENT_BINARY_DIR}/uhd_include")
file(MAKE_DIRECTORY "${_uhd_inc_shim}")
file(CREATE_LINK "${UHD_INCLUDE_DIRS}/uhd" "${_uhd_inc_shim}/uhd" SYMBOLIC)
target_include_directories(uhd_zcu216 BEFORE PRIVATE "${_uhd_inc_shim}")
target_include_directories(uhd_zcu216 PRIVATE ${Boost_INCLUDE_DIRS})
target_link_libraries(uhd_zcu216 PRIVATE ${UHD_LIBRARIES} Threads::Threads)
target_compile_options(uhd_zcu216 PRIVATE -Wall -Wextra -Wno-unused-parameter)
# the kernels must round exactly like UHD's converters: no FMA contraction
set_source_files_properties(lib/zcu216_kernels.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")

# The DPDK data plane (lib/zcu216_dpdk.cpp) is the only sample transport.
# Only that file sees DPDK's flags (-include rte_config.h, -march=...): it is
# an object library of its own.
find_package(PkgConfig)
if(PKG_CONFIG_FOUND)
    pkg_check_modules(DPDK QUIET IMPORTED_TARGET libdpdk)
endif()
if(NOT DPDK_FOUND)
    message(FATAL_ERROR
        "uhd_zcu216 needs DPDK (pkg-config libdpdk not found). DPDK is the only sample "
        "transport of this module. Install it with: sudo ./setup_dpdk.sh --install "
        "(packages dpdk libdpdk-dev rdma-core ibverbs-providers pkg-config), or point "
        "PKG_CONFIG_PATH at a DPDK build's lib/<arch>/pkgconfig.")
endif()
add_library(zcu216_dpdk OBJECT lib/zcu216_dpdk.cpp)
set_target_properties(zcu216_dpdk PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(zcu216_dpdk BEFORE PRIVATE "${_uhd_inc_shim}")
target_include_directories(zcu216_dpdk PRIVATE ${Boost_INCLUDE_DIRS})
target_compile_options(zcu216_dpdk PRIVATE -Wall -Wextra -Wno-unused-parameter)
target_link_libraries(zcu216_dpdk PRIVATE PkgConfig::DPDK)
# dlopen() of libibverbs for the fork fix (zcu216_dpdk.cpp keep_fork_usable)
target_link_libraries(uhd_zcu216 PRIVATE zcu216_dpdk ${CMAKE_DL_LIBS})
message(STATUS "uhd_zcu216: DPDK ${DPDK_VERSION}")
# UHD dlopen()s every file in its module path; keep the name libuhd_zcu216.so
set_target_properties(uhd_zcu216 PROPERTIES PREFIX "lib" OUTPUT_NAME "uhd_zcu216")
# Unresolved symbols would only show up at dlopen time inside UHD -- fail here.
target_link_options(uhd_zcu216 PRIVATE -Wl,--no-undefined)

# The host-side benchmarks (no device, no root):
# zcu216_kernel_bench: the sample kernels alone, AVX2 vs scalar vs UHD's
# converter, and the worker pool, on a cache-resident payload;
# zcu216_dram_bench: the same kernels and pool against DRAM at 100GbE rates,
# with a thread standing in for the NIC's DMA.
option(ZCU216_BUILD_BENCH "Build zcu216_kernel_bench and zcu216_dram_bench" ON)
if(ZCU216_BUILD_BENCH)
    add_executable(zcu216_kernel_bench tools/zcu216_kernel_bench.cpp
        lib/zcu216_kernels.cpp lib/zcu216_pool.cpp lib/zcu216_otw.cpp)
    target_include_directories(zcu216_kernel_bench BEFORE PRIVATE "${_uhd_inc_shim}" lib)
    target_include_directories(zcu216_kernel_bench PRIVATE ${Boost_INCLUDE_DIRS})
    target_link_libraries(zcu216_kernel_bench PRIVATE ${UHD_LIBRARIES} Threads::Threads)
    target_compile_options(zcu216_kernel_bench PRIVATE -Wall -Wextra -Wno-unused-parameter)
    # zcu216_kernel_check: the SIMD kernels against the scalar ones, bit for bit
    add_executable(zcu216_kernel_check tools/zcu216_kernel_check.cpp
        lib/zcu216_kernels.cpp lib/zcu216_otw.cpp)
    target_include_directories(zcu216_kernel_check BEFORE PRIVATE "${_uhd_inc_shim}" lib)
    target_include_directories(zcu216_kernel_check PRIVATE ${Boost_INCLUDE_DIRS})
    target_link_libraries(zcu216_kernel_check PRIVATE ${UHD_LIBRARIES})
    target_compile_options(zcu216_kernel_check PRIVATE -Wall -Wextra -Wno-unused-parameter)
    # its NIC thread streams with AVX2 intrinsics directly (the module picks
    # AVX2 at run time): x86 only
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|i.86")
        add_executable(zcu216_dram_bench tools/zcu216_dram_bench.cpp
            lib/zcu216_kernels.cpp lib/zcu216_pool.cpp lib/zcu216_otw.cpp)
        target_include_directories(zcu216_dram_bench BEFORE PRIVATE "${_uhd_inc_shim}" lib)
        target_include_directories(zcu216_dram_bench PRIVATE ${Boost_INCLUDE_DIRS})
        target_link_libraries(zcu216_dram_bench PRIVATE ${UHD_LIBRARIES} Threads::Threads)
        target_compile_options(zcu216_dram_bench PRIVATE -Wall -Wextra -Wno-unused-parameter -mavx2)
    endif()
endif()

# UHD_LIB_PATH comes from UHDConfig.cmake (dir of libuhd.so), e.g.
# /usr/lib/x86_64-linux-gnu -> /usr/lib/x86_64-linux-gnu/uhd/modules
set(UHD_ZCU216_MODULE_DIR "${UHD_LIB_PATH}/uhd/modules" CACHE PATH
    "Where UHD looks for modules (UHD_MODULES_DIR)")
install(TARGETS uhd_zcu216 LIBRARY DESTINATION "${UHD_ZCU216_MODULE_DIR}")
message(STATUS "uhd_zcu216 module will install into ${UHD_ZCU216_MODULE_DIR}")

# zcu216-uhd: runs a UHD app as root with UHD_MODULE_PATH = the installed
# module and its threads off the DPDK lcores. configure_file bakes in the
# module's install path; the copy in tools/ works from the source tree.
set(UHD_ZCU216_BIN_DIR "/usr/local/bin" CACHE PATH "Where cmake --install puts zcu216-uhd")
set(ZCU216_MODULE_FILE "${UHD_ZCU216_MODULE_DIR}/libuhd_zcu216.so")
configure_file(tools/zcu216-uhd "${CMAKE_CURRENT_BINARY_DIR}/zcu216-uhd" @ONLY)
install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/zcu216-uhd" DESTINATION "${UHD_ZCU216_BIN_DIR}")
message(STATUS "uhd_zcu216 wrapper zcu216-uhd will install into ${UHD_ZCU216_BIN_DIR}")
