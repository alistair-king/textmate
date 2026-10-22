add_library(OakTextView STATIC)
file(GLOB _src src/*.cc src/*.mm)
target_sources(OakTextView PRIVATE ${_src})
textmate_framework(OakTextView)
target_link_libraries(OakTextView PUBLIC
  BundleMenu BundlesManager Find HTMLOutput MenuBuilder OakAppKit OakCommand
  OakFilterList OakFoundation OakSystem Preferences buffer bundles cf command
  crash document editor file io layout lsp ns scm settings text theme
  "-framework Cocoa")

# OakSwiftUI — include path for the generated Swift header
if(OakSwiftUI_LIB)
  execute_process(COMMAND swift -print-target-info OUTPUT_VARIABLE _swift_target_info)
  string(JSON _swift_triple GET "${_swift_target_info}" "target" "unversionedTriple")
  string(TOLOWER "${CMAKE_BUILD_TYPE}" _swift_config)
  if(NOT _swift_config OR _swift_config STREQUAL "")
    set(_swift_config "debug")
  endif()
  target_include_directories(OakTextView PRIVATE
    "${CMAKE_SOURCE_DIR}/Frameworks/OakSwiftUI/.build/${_swift_triple}/${_swift_config}/OakSwiftUI.build/include")
  target_link_libraries(OakTextView PUBLIC ${OakSwiftUI_LIB})
endif()
