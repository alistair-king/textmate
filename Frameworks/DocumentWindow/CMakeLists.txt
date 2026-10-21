add_library(DocumentWindow STATIC)
file(GLOB _src src/*.mm)
target_sources(DocumentWindow PRIVATE ${_src})
textmate_framework(DocumentWindow)
target_link_libraries(DocumentWindow PUBLIC
  BundleEditor BundlesManager FileBrowser Find HTMLOutputWindow MenuBuilder OakAppKit
  OakTabBarView OakCommand OakFilterList OakFoundation OakSystem OakTextView Preferences
  bundles crash document file io kvdb ns regexp scm settings text
  "-framework Cocoa" "-framework SystemConfiguration")

textmate_add_tests(DocumentWindow)

# Bridge the native terminal panel to the Swift component.
if(OakSwiftUI_LIB)
  execute_process(COMMAND swift -print-target-info OUTPUT_VARIABLE _swift_target_info)
  string(JSON _swift_triple GET "${_swift_target_info}" "target" "unversionedTriple")
  string(TOLOWER "${CMAKE_BUILD_TYPE}" _swift_config)
  target_include_directories(DocumentWindow PRIVATE
    "${CMAKE_SOURCE_DIR}/Frameworks/OakSwiftUI/.build/${_swift_triple}/${_swift_config}/OakSwiftUI.build/include")
  target_link_libraries(DocumentWindow PUBLIC ${OakSwiftUI_LIB})
endif()
