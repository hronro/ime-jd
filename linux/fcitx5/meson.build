# The Fcitx 5 addon. Fcitx 5.0.14 (Ubuntu 22.04) is the oldest it builds
# against, and what the release is built against, so it loads in every
# Fcitx 5 since.
fcitx5_min_version = '5.0.14'
# System headers: 5.0.x's own warn under -Wnon-virtual-dtor.
fcitx5_core = dependency('Fcitx5Core', version: '>=' + fcitx5_min_version, required: get_option('fcitx5'),
  include_type: 'system')
fcitx5_module = dependency('Fcitx5Module', required: get_option('fcitx5'), include_type: 'system')
build_fcitx5 = fcitx5_core.found() and fcitx5_module.found()

if build_fcitx5
  # Where the library goes. In Fcitx 5's own addon directory its config names
  # it; anywhere else — the generic tarball's fixed layout — the config gives
  # its absolute path, which Fcitx 5 loads as is.
  fcitx5_addon_dir = fcitx5_core.get_variable(pkgconfig: 'libdir') / 'fcitx5'
  addon_dir = get_option('fcitx5_addon_dir') == '' ? fcitx5_addon_dir : get_option('prefix') / get_option('fcitx5_addon_dir')
  library = addon_dir == fcitx5_addon_dir ? 'libime-jd' : addon_dir / 'libime-jd'
  # Fcitx 5 reads its configs from its own data directory.
  fcitx5_data_dir = fcitx5_core.get_variable(pkgconfig: 'prefix') / get_option('datadir') / 'fcitx5'

  shared_module('ime-jd', 'addon.cpp',
    name_prefix: 'lib',
    dependencies: [fcitx5_core, fcitx5_module, common],
    gnu_symbol_visibility: 'inlineshidden',
    # Keep libjd's and the shared layer's symbols to ourselves, and fail the
    # link — not fcitx5's dlopen — on anything unresolved.
    link_args: ['-Wl,--exclude-libs,ALL', '-Wl,--no-undefined'],
    install: true,
    install_dir: addon_dir)

  addon_conf = configuration_data()
  addon_conf.set('VERSION', version)
  addon_conf.set('LIBRARY', library)
  addon_conf.set('FCITX5_MIN_VERSION', fcitx5_min_version)
  configure_file(input: 'addon.conf.in', output: 'ime-jd.conf',
    configuration: addon_conf,
    install_dir: fcitx5_data_dir / 'addon')
  install_data('inputmethod.conf', rename: 'ime-jd.conf', install_dir: fcitx5_data_dir / 'inputmethod')

  # Fcitx 5 finds the icon by name in the icon theme; the small sizes use the
  # borderless cut drawn for them (assets/icon/README.md).
  icon_theme_dir = get_option('datadir') / 'icons' / 'hicolor'
  install_data(icon_dir / 'jd.svg', rename: 'fcitx-ime-jd.svg', install_dir: icon_theme_dir / 'scalable' / 'apps')
  foreach size : ['16x16', '22x22', '24x24', '32x32']
    install_data(icon_dir / 'jd-small.svg', rename: 'fcitx-ime-jd.svg', install_dir: icon_theme_dir / size / 'apps')
  endforeach
endif
