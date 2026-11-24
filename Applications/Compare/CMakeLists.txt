add_executable(Compare MACOSX_BUNDLE src/main.mm src/CompareSettings.mm src/CompareChooser.mm src/CompareWindowController.mm src/CompareDiffView.mm src/compare_tree.mm src/compare_diff.mm src/compare_transfer.mm src/compare_syntax.mm)
# Static frameworks cannot carry resources: bundle the tab bar's images and the
# file-type icons TMFileReference uses, as TextMate's app bundle does.
file(GLOB _compare_resources CONFIGURE_DEPENDS
  "${CMAKE_SOURCE_DIR}/Frameworks/OakTabBarView/gfx/*.png"
  "${CMAKE_SOURCE_DIR}/Frameworks/OakAppKit/gfx/CloseButton/*.png")
file(GLOB _compare_doctypes CONFIGURE_DEPENDS
  "${CMAKE_SOURCE_DIR}/Frameworks/TMFileReference/resources/*.icns"
  "${CMAKE_SOURCE_DIR}/Frameworks/TMFileReference/resources/bindings.plist")
# The app icon: two TextMate flowers with arrows (resources/make_icon.swift draws it).
set(_compare_icon "${CMAKE_CURRENT_SOURCE_DIR}/resources/Compare.icns")
target_sources(Compare PRIVATE ${_compare_resources} ${_compare_doctypes} "${_compare_icon}")
set_source_files_properties("${_compare_icon}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
# Icon changes must refresh signing and the helper embedded in TextMate.
set_property(TARGET Compare APPEND PROPERTY LINK_DEPENDS "${_compare_icon}")
set_source_files_properties(${_compare_resources} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
set_source_files_properties(${_compare_doctypes} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/DocumentTypes")
# FileBrowser supplies the tree views; the rest mirrors ThemeEditor's setup of
# TextMate's support folder, settings and preferences.
target_link_libraries(Compare PRIVATE
  FileBrowser OakTabBarView OakSystem Preferences bundles file io ns parse plist scm settings text theme xdiff
  ${TEXTMATE_DEBUG_LIBS} "-framework Cocoa")
set_target_properties(Compare PROPERTIES
  OUTPUT_NAME "Compare"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
  BUILD_RPATH "@executable_path/../../../../Frameworks;${CMAKE_BINARY_DIR}/lib"
  INSTALL_RPATH "@executable_path/../../../../Frameworks")
# Ad-hoc signatures have no Team ID, so the hardened runtime would refuse the
# build's dylibs (libOakSwiftUI via FileBrowser). Same rule as ThemeEditor.
if(CS_IDENTITY STREQUAL "-")
  set(COMPARE_DISABLE_LIBRARY_VALIDATION true)
else()
  set(COMPARE_DISABLE_LIBRARY_VALIDATION false)
endif()
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(CS_GET_TASK_ALLOW true)
else()
  set(CS_GET_TASK_ALLOW false)
endif()
configure_file(Entitlements.plist ${CMAKE_CURRENT_BINARY_DIR}/Entitlements.plist)
# Signing runs after linking, so relink (and re-sign) when entitlements change.
set_property(TARGET Compare APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/Entitlements.plist")
textmate_codesign(Compare "${CS_IDENTITY}"
  ENTITLEMENTS "${CMAKE_CURRENT_BINARY_DIR}/Entitlements.plist")

add_executable(tm-compare src/launcher.mm)
target_link_libraries(tm-compare PRIVATE "-framework AppKit")

if(BUILD_TESTING)
  set(_runner "${CMAKE_CURRENT_BINARY_DIR}/test_runner.mm")
  add_custom_command(OUTPUT "${_runner}"
    COMMAND "${CMAKE_SOURCE_DIR}/bin/gen_test"
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/t_compare_url.mm"
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/t_compare_diff.mm" > "${_runner}"
    DEPENDS tests/t_compare_url.mm tests/t_compare_diff.mm src/compare_url.h src/compare_diff.h "${CMAKE_SOURCE_DIR}/bin/gen_test")
  add_executable(compare_tests "${_runner}" src/compare_diff.mm)
  target_link_libraries(compare_tests PRIVATE xdiff ${TEXTMATE_DEBUG_LIBS} "-framework Foundation")
  add_test(NAME compare COMMAND compare_tests)

  find_program(COMPARE_TEST_GIT_EXECUTABLE git)
  if(COMPARE_TEST_GIT_EXECUTABLE)
    set(_tree_runner "${CMAKE_CURRENT_BINARY_DIR}/tree_test_runner.mm")
    add_custom_command(OUTPUT "${_tree_runner}"
      COMMAND "${CMAKE_SOURCE_DIR}/bin/gen_test"
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/t_compare_tree.mm" > "${_tree_runner}"
      DEPENDS tests/t_compare_tree.mm src/compare_tree.h "${CMAKE_SOURCE_DIR}/bin/gen_test")
    add_executable(compare_tree_tests "${_tree_runner}" src/compare_tree.mm)
    target_compile_definitions(compare_tree_tests PRIVATE COMPARE_TEST_GIT="${COMPARE_TEST_GIT_EXECUTABLE}")
    target_link_libraries(compare_tree_tests PRIVATE ${TEXTMATE_DEBUG_LIBS} "-framework Foundation")
    add_test(NAME compare-tree COMMAND compare_tree_tests)

    set(_transfer_runner "${CMAKE_CURRENT_BINARY_DIR}/transfer_test_runner.mm")
    add_custom_command(OUTPUT "${_transfer_runner}"
      COMMAND "${CMAKE_SOURCE_DIR}/bin/gen_test"
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/t_compare_transfer.mm" > "${_transfer_runner}"
      DEPENDS tests/t_compare_transfer.mm src/compare_transfer.h src/compare_tree.h src/compare_diff.h "${CMAKE_SOURCE_DIR}/bin/gen_test")
    add_executable(compare_transfer_tests "${_transfer_runner}" src/compare_transfer.mm src/compare_tree.mm src/compare_diff.mm)
    target_link_libraries(compare_transfer_tests PRIVATE xdiff ${TEXTMATE_DEBUG_LIBS} "-framework Foundation")
    add_test(NAME compare-transfer COMMAND compare_transfer_tests)

    set(_syntax_runner "${CMAKE_CURRENT_BINARY_DIR}/syntax_test_runner.mm")
    add_custom_command(OUTPUT "${_syntax_runner}"
      COMMAND "${CMAKE_SOURCE_DIR}/bin/gen_test"
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/t_compare_syntax.mm" > "${_syntax_runner}"
      DEPENDS tests/t_compare_syntax.mm src/compare_syntax.h "${CMAKE_SOURCE_DIR}/bin/gen_test")
    add_executable(compare_syntax_tests "${_syntax_runner}" src/compare_syntax.mm)
    target_link_libraries(compare_syntax_tests PRIVATE
      bundles file io ns parse plist settings text theme ${TEXTMATE_DEBUG_LIBS} "-framework Cocoa")
    add_test(NAME compare-syntax COMMAND compare_syntax_tests)

    # Drives the real window over the fixture; needs a GUI session.
    add_executable(compare_window_tests MACOSX_BUNDLE
      tests/window_tests.mm src/CompareSettings.mm src/CompareChooser.mm src/CompareWindowController.mm src/CompareDiffView.mm src/compare_tree.mm src/compare_diff.mm src/compare_transfer.mm src/compare_syntax.mm
      ${_compare_resources} ${_compare_doctypes})
    set_target_properties(compare_window_tests PROPERTIES
      MACOSX_BUNDLE_GUI_IDENTIFIER "com.macromates.TextMate.Compare.Tests"
      BUILD_RPATH "${CMAKE_BINARY_DIR}/lib")
    target_compile_definitions(compare_window_tests PRIVATE COMPARE_TEST_GIT="${COMPARE_TEST_GIT_EXECUTABLE}")
    target_link_libraries(compare_window_tests PRIVATE
      FileBrowser OakTabBarView OakSystem Preferences bundles file io ns parse plist scm settings text theme xdiff
      ${TEXTMATE_DEBUG_LIBS} "-framework Cocoa")
    add_test(NAME compare-window COMMAND $<TARGET_FILE:compare_window_tests>)
    set_tests_properties(compare-window PROPERTIES RUN_SERIAL TRUE TIMEOUT 180)
  endif()

  # Runs the signed app binary (hardened runtime, real entitlements) so a
  # library that fails to load under its signature fails here, not at launch.
  add_test(NAME compare-launch COMMAND $<TARGET_FILE:Compare> --check-launch)
  set_tests_properties(compare-launch PROPERTIES PASS_REGULAR_EXPRESSION "^Compare launched")

  add_test(NAME tm-compare-help COMMAND tm-compare --help)
  set_tests_properties(tm-compare-help PROPERTIES PASS_REGULAR_EXPRESSION "^Usage: tm-compare")
  add_test(NAME tm-compare-rejects-missing-folder COMMAND tm-compare / /nonexistent-tm-compare-folder)
  set_tests_properties(tm-compare-rejects-missing-folder PROPERTIES WILL_FAIL TRUE)
  add_test(NAME tm-compare-rejects-file-and-folder COMMAND tm-compare / ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist)
  set_tests_properties(tm-compare-rejects-file-and-folder PROPERTIES PASS_REGULAR_EXPRESSION "is a folder and .* is a file")
endif()
