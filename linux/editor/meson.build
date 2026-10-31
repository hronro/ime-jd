# The user-dictionary editor, ime-jd-userdict: Vala over GTK 4, no
# libadwaita. GTK 4.6 (Ubuntu 22.04) is the oldest it builds against.
gtk4 = dependency('gtk4', version: '>=4.6', required: get_option('editor'))
build_editor = false
if gtk4.found()
  build_editor = add_languages('c', 'vala', native: false, required: get_option('editor'))
endif

if build_editor
  # The part with no GTK in it, which the tests build too.
  editor_core = files('jd.vapi', 'file.vala', 'ini.vala', 'problem.vala', 'store.vala')
  editor_core_deps = [
    dependency('gio-2.0'),
    meson.get_compiler('vala').find_library('posix'),
    libjd,
  ]
  # Vala's C is generated: its warnings are Vala's, not this project's.
  editor_c_args = [version_arg, '-w']

  executable('ime-jd-userdict',
    editor_core,
    'prompt.vala',
    'row.vala',
    'window.vala',
    'main.vala',
    dependencies: [gtk4, editor_core_deps],
    include_directories: core_include,
    # GTK 4.6's API, on purpose, whatever later GTKs and Valas deprecate of
    # it: DropTarget's drop signal is on_drop to Vala 0.56.0, and only an
    # alias of drop to its later releases.
    vala_args: '--enable-deprecated',
    c_args: editor_c_args,
    install: true)

  # Named after the application ID, which is how desktops tie the window to
  # its entry and icon.
  install_data('io.github.hronro.ImeJd.UserDict.desktop', install_dir: get_option('datadir') / 'applications')
  editor_icon_dir = get_option('datadir') / 'icons' / 'hicolor'
  install_data(icon_dir / 'jd.svg', rename: 'io.github.hronro.ImeJd.UserDict.svg',
    install_dir: editor_icon_dir / 'scalable' / 'apps')
  foreach size : ['16x16', '22x22', '24x24', '32x32']
    install_data(icon_dir / 'jd-small.svg', rename: 'io.github.hronro.ImeJd.UserDict.svg',
      install_dir: editor_icon_dir / size / 'apps')
  endforeach
endif
