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
  # PUBLIC so dependents (including the test runner) compile the same conditional code.
  target_compile_definitions(DocumentWindow PUBLIC HAVE_OAK_SWIFTUI=1)
  target_include_directories(DocumentWindow PRIVATE "${OakSwiftUI_INCLUDE_DIR}")
  target_link_libraries(DocumentWindow PUBLIC ${OakSwiftUI_LIB})
endif()
