# The Linux client: a Fcitx 5 addon (fcitx5/) and an IBus engine (ibus/)
# over one shared layer (common/), and the user-dictionary editor (editor/),
# each linking libjd statically.
#
# 0.61 is Ubuntu 22.04's Meson, the oldest release builds target.
project('ime-jd', 'cpp',
  meson_version: '>=0.61',
  # C++20: Fcitx 5.1's headers need it.
  default_options: ['cpp_std=c++20', 'warning_level=2', 'buildtype=debugoptimized'])

fs = import('fs')

core_dir = meson.current_source_dir() / '..' / 'core'
icon_dir = meson.current_source_dir() / '..' / 'assets' / 'icon'

# The release version is libjd's, the one place a release bumps.
version = ''
foreach line : fs.read(core_dir / 'build.zig.zon').split('\n')
  if line.strip().startswith('.version')
    version = line.split('"')[1]
  endif
endforeach
if version == ''
  error('No version in core/build.zig.zon')
endif

# ---- libjd ----

if get_option('libjd') != ''
  libjd = declare_dependency(link_args: get_option('libjd'))
else
  zig = find_program('zig')
  # For the target's baseline CPU, not the build machine's: Zig tunes for the
  # host unless told a target. Zig keeps its own cache, so running it on
  # every build costs little, and an unchanged library is not rewritten.
  libjd_build = custom_target('libjd',
    output: 'libjd.a',
    command: [zig, 'build', '--build-file', core_dir / 'build.zig',
      '-Doptimize=fast', '-Dtarget=' + host_machine.cpu_family() + '-linux', '-Dcpu=baseline',
      '--prefix', meson.current_build_dir() / 'zig-out', '--prefix-lib-dir', meson.current_build_dir()],
    build_always_stale: true,
    console: true)
  libjd = declare_dependency(link_with: libjd_build)
endif

# ---- The shared layer ----

version_arg = '-DIMEJD_VERSION="@0@"'.format(version)
# Where the editor installs, for the menus to start it: whether it is
# built here or not, its package may be installed beside these.
editor_arg = '-DIMEJD_EDITOR="@0@"'.format(get_option('prefix') / get_option('bindir') / 'ime-jd-userdict')
core_include = include_directories('../core/include')

common_lib = static_library('imejd_common',
  'common/engine.cpp',
  'common/key_gate.cpp',
  'common/session.cpp',
  'common/user_dict.cpp',
  include_directories: core_include,
  cpp_args: [version_arg, editor_arg],
  gnu_symbol_visibility: 'inlineshidden',
  # It goes into the Fcitx 5 addon, a shared object.
  pic: true)

common = declare_dependency(
  link_with: common_lib,
  include_directories: [include_directories('common'), core_include],
  compile_args: [version_arg, editor_arg],
  dependencies: libjd)

# ---- Frontends ----

subdir('editor')
subdir('fcitx5')
subdir('ibus')

if get_option('tests')
  subdir('tests')
endif

summary({
  'Version': version,
  'Fcitx 5 addon': build_fcitx5,
  'IBus engine': build_ibus,
  'User-dictionary editor': build_editor,
  'Tests': get_option('tests'),
}, bool_yn: true)
