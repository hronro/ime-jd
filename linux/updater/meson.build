# The update check's own process, built for the generic tarball alone
# (-Dupdate_check=true). GIO tells the user and runs install.sh; libcurl is
# loaded when needed (http.h). Without libjd: only the files and the feed's
# rules are shared with the frontends.
executable('ime-jd-update',
  'main.cpp',
  'http.cpp',
  '../common/files.cpp',
  '../common/sha256.cpp',
  '../common/update.cpp',
  include_directories: include_directories('../common'),
  cpp_args: [version_arg, editor_arg],
  # GSubprocess: 2.40.
  dependencies: [dependency('gio-2.0', version: '>=2.40'),
    meson.get_compiler('cpp').find_library('dl', required: false)],
  install: true,
  install_dir: get_option('libexecdir'))
