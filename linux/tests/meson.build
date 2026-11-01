tests = executable('imejd_tests',
  'main.cpp',
  'engine_test.cpp',
  'key_gate_test.cpp',
  'session_test.cpp',
  'update_test.cpp',
  'user_dict_test.cpp',
  dependencies: common)
test('imejd_tests', tests)

if build_editor
  editor_tests = executable('imejd_editor_tests',
    'editor_test.vala',
    editor_core,
    dependencies: editor_core_deps,
    include_directories: core_include,
    c_args: editor_c_args)
  test('imejd_editor_tests', editor_tests)
endif
