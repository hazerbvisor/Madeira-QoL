# Adapt the pinned fork's Windows-only diagnostics for the native iOS archive.
# Keep this outside the submodule and attach it only to the affected source.
if(NOT PROJECT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR)
  return()
endif()

function(madeira_fex_native_compat)
  set_property(SOURCE "${CMAKE_SOURCE_DIR}/FEXCore/Source/Interface/Core/Core.cpp"
    DIRECTORY "${CMAKE_SOURCE_DIR}/FEXCore/Source"
    APPEND PROPERTY COMPILE_OPTIONS
    -include "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/native-compat.h")
  set_property(SOURCE "${CMAKE_SOURCE_DIR}/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp"
    DIRECTORY "${CMAKE_SOURCE_DIR}/FEXCore/Source"
    APPEND PROPERTY COMPILE_OPTIONS
    -include "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/memory-diagnostic-compat.h")

endfunction()

cmake_language(DEFER CALL madeira_fex_native_compat)
