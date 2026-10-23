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

if(BUILD_TESTING)
  set(_context_test_source "${CMAKE_CURRENT_SOURCE_DIR}/context-tests/t_editor_context.mm")
  set(_context_test_runner "${CMAKE_CURRENT_BINARY_DIR}/editor_context_test_runner.mm")
  add_custom_command(OUTPUT "${_context_test_runner}"
    COMMAND "${CMAKE_SOURCE_DIR}/bin/gen_test" "${_context_test_source}" > "${_context_test_runner}"
    DEPENDS "${_context_test_source}" "${CMAKE_SOURCE_DIR}/bin/gen_test")
  add_executable(EditorContext_tests "${_context_test_runner}")
  target_link_libraries(EditorContext_tests PRIVATE DocumentWindow ${TEXTMATE_DEBUG_LIBS})
  # Fixtures share AppKit and the singleton service. Running all fixtures in
  # parallel can starve nested blocking socket calls in the global thread pool;
  # concurrency is exercised explicitly inside the routing/transfer tests.
  add_test(NAME EditorContext COMMAND EditorContext_tests --no-parallel)
endif()

# Bridge the native terminal panel to the Swift component.
if(OakSwiftUI_LIB)
  execute_process(COMMAND swift -print-target-info OUTPUT_VARIABLE _swift_target_info)
  string(JSON _swift_triple GET "${_swift_target_info}" "target" "unversionedTriple")
  string(TOLOWER "${CMAKE_BUILD_TYPE}" _swift_config)
  if(NOT _swift_config OR _swift_config STREQUAL "")
    set(_swift_config "debug")
  endif()
  target_compile_definitions(DocumentWindow PRIVATE HAVE_OAK_SWIFTUI=1)
  target_include_directories(DocumentWindow PRIVATE
    "${CMAKE_SOURCE_DIR}/Frameworks/OakSwiftUI/.build/${_swift_triple}/${_swift_config}/OakSwiftUI.build/include")
  target_link_libraries(DocumentWindow PUBLIC ${OakSwiftUI_LIB})
endif()
