# Injected with -DCMAKE_PROJECT_INCLUDE when building the iOS fork of libgit2. The fork's
# src/CMakeLists.txt still calls SanitizeBool, which upstream renamed; provide it when missing.
if(NOT COMMAND SanitizeBool)
  function(SanitizeBool VAR)
    string(TOLOWER "${${VAR}}" value)
    if(value STREQUAL "on" OR value STREQUAL "yes" OR value STREQUAL "true" OR value STREQUAL "1")
      set(${VAR} "ON" PARENT_SCOPE)
    elseif(value STREQUAL "off" OR value STREQUAL "no" OR value STREQUAL "false" OR value STREQUAL "0" OR value STREQUAL "")
      set(${VAR} "OFF" PARENT_SCOPE)
    endif()
  endfunction()
endif()
