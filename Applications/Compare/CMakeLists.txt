add_executable(Compare MACOSX_BUNDLE src/main.mm src/CompareWindowController.mm)
target_link_libraries(Compare PRIVATE ${TEXTMATE_DEBUG_LIBS} "-framework Cocoa")
set_target_properties(Compare PROPERTIES
  OUTPUT_NAME "Compare"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist")
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

  add_test(NAME tm-compare-help COMMAND tm-compare --help)
  set_tests_properties(tm-compare-help PROPERTIES PASS_REGULAR_EXPRESSION "^Usage: tm-compare")
  add_test(NAME tm-compare-rejects-missing-folder COMMAND tm-compare / /nonexistent-tm-compare-folder)
  set_tests_properties(tm-compare-rejects-missing-folder PROPERTIES WILL_FAIL TRUE)
endif()
