# The IBus engine. IBus 1.5.26 (Ubuntu 22.04) is the oldest it builds
# against.
ibus = dependency('ibus-1.0', version: '>=1.5.26', required: get_option('ibus'))
build_ibus = ibus.found()

if build_ibus
  engine_dir = get_option('prefix') / (get_option('ibus_engine_dir') == '' ? get_option('libexecdir') : get_option('ibus_engine_dir'))
  # IBus reads component files from its own data directory and nowhere else,
  # whatever this project's prefix.
  component_dir = ibus.get_variable(pkgconfig: 'pkgdatadir') / 'component'
  icon = get_option('prefix') / get_option('datadir') / 'ibus-ime-jd' / 'icons' / 'ime-jd.svg'

  executable('ibus-engine-ime-jd', 'main.cpp', 'ibus_engine.cpp',
    dependencies: [ibus, common],
    cpp_args: '-DIMEJD_ICON="@0@"'.format(icon),
    gnu_symbol_visibility: 'inlineshidden',
    install: true,
    install_dir: engine_dir)

  component = configuration_data()
  component.set('VERSION', version)
  component.set('EXEC', engine_dir / 'ibus-engine-ime-jd')
  component.set('ICON', icon)
  configure_file(input: 'ime-jd.xml.in', output: 'ime-jd.xml',
    configuration: component,
    install_dir: component_dir)

  install_data(icon_dir / 'jd.svg', rename: 'ime-jd.svg', install_dir: get_option('datadir') / 'ibus-ime-jd' / 'icons')
endif
