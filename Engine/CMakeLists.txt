cmake_minimum_required(VERSION 3.24)
project(RillEngine LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
get_filename_component(TOREO_SOURCE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}" DIRECTORY)
add_compile_options(
    "-ffile-prefix-map=${TOREO_SOURCE_ROOT}=/toreo"
    "-ffile-prefix-map=${TRANSMISSION_SOURCE}=/transmission")
set(CMAKE_FIND_PACKAGE_TARGETS_GLOBAL ON)
foreach(flag ENABLE_DAEMON ENABLE_MAC ENABLE_QT ENABLE_GTK ENABLE_UTILS ENABLE_CLI ENABLE_TESTS ENABLE_NLS INSTALL_WEB INSTALL_DOC RUN_CLANG_TIDY)
    set(${flag} OFF CACHE STRING "" FORCE)
endforeach()
set(WITH_CRYPTO ccrypto CACHE STRING "" FORCE)
add_subdirectory("${TRANSMISSION_SOURCE}" transmission)
target_sources(transmission PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Bridge.cc")
add_library(RillEngine SHARED Link.cc)
target_link_options(RillEngine PRIVATE "LINKER:-u,_rill_open" "LINKER:-exported_symbol,_rill_*")
target_link_libraries(RillEngine PRIVATE transmission)

set_target_properties(RillEngine PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR YES)
