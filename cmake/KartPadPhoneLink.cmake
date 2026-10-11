# Phone controllers' WebRTC link on the Mac (apple/macos/KartPadPhoneControllers.inc.mm): libdatachannel,
# data channels only, over Mbed TLS for DTLS. Everything is fetched at pinned versions and built
# statically. libdatachannel's own dependencies (libjuice, usrsctp, plog) are git submodules missing
# from its release tarball, so each is fetched at the commit v0.24.6 pins and put where it expects.
# Defines kartpad_phone_link, which the Mac products link. It also carries the controller page
# (web/phone/index.html), so the Mac can serve it itself for the touch-only link, and says where the
# same page is published over HTTPS for tilt (KARTPAD_PHONE_PAGE_URL).
# The archives are also recorded in dependencies.lock.json.
include_guard(GLOBAL)
include(FetchContent)

# Where web/phone/index.html is published over HTTPS, for steering by tilting (browsers only give
# motion to such pages), e.g. https://example.github.io/kartpad/pad/. Empty (the default): the QR
# code opens the touch-only page the Mac serves, and tilt isn't offered. docs/MULTIPLAYER.md says how
# to publish it. The Mac products' shell source gets it as KARTPAD_PHONE_PAGE_URL
# (runtime/cmake/PublicProducts.cmake), so changing it rebuilds only that.
set(KARTPAD_PHONE_PAGE_URL "" CACHE STRING
    "HTTPS address of the published phone controller page (web/phone/index.html), for tilt; empty for touch only")
if(KARTPAD_PHONE_PAGE_URL AND NOT KARTPAD_PHONE_PAGE_URL MATCHES "^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/-]*)?$")
    message(FATAL_ERROR "KARTPAD_PHONE_PAGE_URL must be an https:// address with no query or fragment: "
        "${KARTPAD_PHONE_PAGE_URL}")
endif()

# Fetched only (SOURCE_SUBDIR names a folder that doesn't exist, so nothing is added yet).
FetchContent_Declare(kartpad_mbedtls
    URL https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.7/mbedtls-3.6.7.tar.bz2
    URL_HASH SHA256=a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_SUBDIR kartpad-not-a-cmake-dir)
FetchContent_Declare(kartpad_libdatachannel
    URL https://github.com/paullouisageneau/libdatachannel/archive/refs/tags/v0.24.6.tar.gz
    URL_HASH SHA256=22a66aebebd8dae561d8e5181da96f2fcc203e067c5b2186c07b39af913464c0
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_SUBDIR kartpad-not-a-cmake-dir)
FetchContent_MakeAvailable(kartpad_mbedtls kartpad_libdatachannel)

FetchContent_Declare(kartpad_libjuice
    URL https://github.com/paullouisageneau/libjuice/archive/b89c792e3612faf2f12cf35bcc56857313a06be3.tar.gz
    URL_HASH SHA256=713b22174e8cb2e06538fa9bac2650bda21b83c86f5128813ab4dcf8f5bea9ed
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_DIR "${kartpad_libdatachannel_SOURCE_DIR}/deps/libjuice"
    SOURCE_SUBDIR kartpad-not-a-cmake-dir)
FetchContent_Declare(kartpad_usrsctp
    URL https://github.com/paullouisageneau/usrsctp/archive/fec583d54493f879d2ae44a743423bf8a04371ab.tar.gz
    URL_HASH SHA256=e5c114afe73c9a0ec419fab5f5b3f63f3ce57b09b90d06ea85e63dca8aed3e7c
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_DIR "${kartpad_libdatachannel_SOURCE_DIR}/deps/usrsctp"
    SOURCE_SUBDIR kartpad-not-a-cmake-dir)
FetchContent_Declare(kartpad_plog
    URL https://github.com/SergiusTheBest/plog/archive/94899e0b926ac1b0f4750bfbd495167b4a6ae9ef.tar.gz
    URL_HASH SHA256=92a08bce559b5f28aa88d3fd9071567414b9f43a83fe2a05a6dd14f1da536072
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_DIR "${kartpad_libdatachannel_SOURCE_DIR}/deps/plog"
    SOURCE_SUBDIR kartpad-not-a-cmake-dir)
FetchContent_MakeAvailable(kartpad_libjuice kartpad_usrsctp kartpad_plog)

# Static, quiet, and without the parts KartPad doesn't use (programs, tests, media, WebSockets). In a
# function, so these options stay out of KartPad's own build; the subprojects' option() calls take
# them as normal variables (CMP0077).
function(kartpad_add_phone_link_dependencies)
    set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)
    # Like KartPad's own sources, keep the build's path out of the binary (__FILE__ strings, and
    # lambda names in __PRETTY_FUNCTION__). These sources live under the build folder.
    foreach(language IN ITEMS C CXX)
        string(APPEND CMAKE_${language}_FLAGS
            " -ffile-prefix-map=${FETCHCONTENT_BASE_DIR}=_deps -fmacro-prefix-map=${FETCHCONTENT_BASE_DIR}=_deps")
    endforeach()
    set(BUILD_SHARED_LIBS OFF)
    set(ENABLE_PROGRAMS OFF)
    set(ENABLE_TESTING OFF)
    set(MBEDTLS_FATAL_WARNINGS OFF)
    add_subdirectory("${kartpad_mbedtls_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/_deps/kartpad_mbedtls-build" EXCLUDE_FROM_ALL)
    # One Mbed TLS configuration for Mbed TLS and everything that includes its headers.
    foreach(target IN ITEMS mbedcrypto mbedx509 mbedtls)
        target_compile_definitions(${target} PUBLIC
            MBEDTLS_USER_CONFIG_FILE="${CMAKE_CURRENT_FUNCTION_LIST_DIR}/kartpad_mbedtls_config.h")
    endforeach()
    # Imported, so libdatachannel's (unused) install rules don't need Mbed TLS in their export set.
    if(NOT TARGET MbedTLS::MbedTLS)
        add_library(MbedTLS::MbedTLS INTERFACE IMPORTED GLOBAL)
        set_target_properties(MbedTLS::MbedTLS PROPERTIES INTERFACE_LINK_LIBRARIES "mbedtls;mbedx509;mbedcrypto")
    endif()

    set(USE_MBEDTLS ON)
    set(NO_MEDIA ON)
    set(NO_WEBSOCKET ON)
    set(NO_EXAMPLES ON)
    set(NO_TESTS ON)
    set(NO_SERVER ON)  # libjuice's TURN/STUN server
    add_subdirectory("${kartpad_libdatachannel_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/_deps/kartpad_libdatachannel-build"
        EXCLUDE_FROM_ALL)
endfunction()
kartpad_add_phone_link_dependencies()

add_library(kartpad_phone_link INTERFACE)
target_link_libraries(kartpad_phone_link INTERFACE LibDataChannel::LibDataChannelStatic)
target_compile_definitions(kartpad_phone_link INTERFACE RTC_STATIC)

# The controller page as a C++ string (KartPadPhonePage.inc.mm includes it). Written again when the page
# changes; file(CONFIGURE) leaves the header alone when nothing did, so nothing rebuilds needlessly.
set(KARTPAD_PHONE_PAGE "${CMAKE_CURRENT_LIST_DIR}/../web/phone/index.html")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${KARTPAD_PHONE_PAGE}")
file(READ "${KARTPAD_PHONE_PAGE}" KARTPAD_PHONE_PAGE_HTML)
string(FIND "${KARTPAD_PHONE_PAGE_HTML}" ")KPPAGE\"" KARTPAD_PHONE_PAGE_DELIMITER)
if(NOT KARTPAD_PHONE_PAGE_DELIMITER EQUAL -1)
    message(FATAL_ERROR "web/phone/index.html contains the C++ string's closing delimiter")
endif()
file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/kartpad_generated/KartPadPhonePageHTML.inc"
    CONTENT "// Generated from web/phone/index.html by cmake/KartPadPhoneLink.cmake.\nstatic const char KPPhonePage[] = R\"KPPAGE(@KARTPAD_PHONE_PAGE_HTML@)KPPAGE\";\n"
    @ONLY)
target_include_directories(kartpad_phone_link INTERFACE "${CMAKE_BINARY_DIR}/kartpad_generated")
