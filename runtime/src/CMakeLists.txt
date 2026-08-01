cmake_minimum_required(VERSION 3.16)
project(RaijinLabRuntime LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 4)
  message(WARNING "RaijinLabRuntime must be Win32/x86 for Ascension.exe")
endif()

add_library(RaijinLabRuntime SHARED
  main.cpp
  core/Log.cpp
  core/Config.cpp
  core/Patterns.cpp
  core/PebUnlink.cpp
  game/Offsets.cpp
  game/AddressDB.cpp
  game/GameTime.cpp
  game/ObjectManager.cpp
  game/Actions.cpp
  game/MainThread.cpp
  game/TaintPatch.cpp
  lua/Lua.cpp
  bridge/Dispatch.cpp
  bridge/Ipc.cpp
)

target_include_directories(RaijinLabRuntime PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(RaijinLabRuntime PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
target_compile_options(RaijinLabRuntime PRIVATE /W3 /EHsc /GS /permissive-)

add_executable(RaijinLabLoader loader/loader.cpp)
target_compile_definitions(RaijinLabLoader PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
target_compile_options(RaijinLabLoader PRIVATE /W3 /EHsc)

# Offline offset validator (console, no inject)
add_executable(RaijinLabValidate tools/validate_offsets.cpp)
target_include_directories(RaijinLabValidate PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(RaijinLabValidate PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
target_sources(RaijinLabValidate PRIVATE core/Patterns.cpp core/Log.cpp)
target_compile_options(RaijinLabValidate PRIVATE /W3 /EHsc)
