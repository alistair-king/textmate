add_executable(Compare MACOSX_BUNDLE src/main.mm src/CompareWindowController.mm src/compare_tree.mm)
# FileBrowser supplies the tree views; the rest mirrors ThemeEditor's setup of
# TextMate's support folder, settings and preferences.
target_link_libraries(Compare PRIVATE
  FileBrowser OakSystem Preferences io ns scm settings
  ${TEXTMATE_DEBUG_LIBS} "-framework Cocoa")
set_target_properties(Compare PROPERTIES
  OUTPUT_NAME "Compare"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
  BUILD_RPATH "@executable_path/../../../../Frameworks;${CMAKE_BINARY_DIR}/lib"
  INSTALL_RPATH "@executable_path/../../../../Frameworks")
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(CS_GET_TASK_ALLOW true)
else()
  set(CS_GET_TASK_ALLOW false)
endif()
configure_file(Entitlements.plist ${CMAKE_CURRENT_BINARY_DIR}/Entitlements.plist)
textmate_codesign(Compare "${CS_IDENTITY}"
  ENTITLEMENTS "${CMAKE_CURRENT_BINARY_DIR}/Entitlements.plist")

add_executable(tm-compare src/launcher.mm)
target_link_libraries(tm-compare PRIVATE "-framework AppKit")

if(BUILD_TESTING)
  set(_runner "${CMAKE_CURRENT_BINARY_DIR}/test_runner.mm")
  add_custom_command(OUTPUT "${_runner}"
    COMMAND "${CMAKE_SOURCE_DIR}/bin/gen_test"
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/t_compare_url.mm" > "${_runner}"
    DEPENDS tests/t_compare_url.mm src/compare_url.h "${CMAKE_SOURCE_DIR}/bin/gen_test")
  add_executable(compare_tests "${_runner}")
  target_link_libraries(compare_tests PRIVATE ${TEXTMATE_DEBUG_LIBS} "-framework Foundation")
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

    # Drives the real window over the fixture; needs a GUI session.
    add_executable(compare_window_tests MACOSX_BUNDLE
      tests/window_tests.mm src/CompareWindowController.mm src/compare_tree.mm)
    set_target_properties(compare_window_tests PROPERTIES
      MACOSX_BUNDLE_GUI_IDENTIFIER "com.macromates.TextMate.Compare.Tests"
      BUILD_RPATH "${CMAKE_BINARY_DIR}/lib")
    target_compile_definitions(compare_window_tests PRIVATE COMPARE_TEST_GIT="${COMPARE_TEST_GIT_EXECUTABLE}")
    target_link_libraries(compare_window_tests PRIVATE
      FileBrowser OakSystem Preferences io ns scm settings
      ${TEXTMATE_DEBUG_LIBS} "-framework Cocoa")
    add_test(NAME compare-window COMMAND $<TARGET_FILE:compare_window_tests>)
    set_tests_properties(compare-window PROPERTIES RUN_SERIAL TRUE TIMEOUT 60)
  endif()

  add_test(NAME tm-compare-help COMMAND tm-compare --help)
  set_tests_properties(tm-compare-help PROPERTIES PASS_REGULAR_EXPRESSION "^Usage: tm-compare")
  add_test(NAME tm-compare-rejects-missing-folder COMMAND tm-compare / /nonexistent-tm-compare-folder)
  set_tests_properties(tm-compare-rejects-missing-folder PROPERTIES WILL_FAIL TRUE)
endif()
