#!/usr/bin/env python3
"""键道's updater, installed, against a release feed served on this machine:
what it records in update.ini, what it tells the user — through a
notification service of the test's own, on the session bus — and an install,
run without pkexec, of a release built here. run.sh sets up the session and
passes the updater's path."""

import fcntl
import hashlib
import http.server
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

from gi.repository import Gio, GLib

from harness import check, check_eq, pump, run, test

UPDATER = sys.argv[1]
CONFIG_DIR = os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'ime-jd')
CACHE_DIR = os.path.join(os.environ.get('XDG_CACHE_HOME') or os.path.expanduser('~/.cache'), 'ime-jd')
VERSION = subprocess.run([UPDATER, '--version'], capture_output=True, text=True, check=True).stdout.strip()
ARCH = {'x86_64': 'x86_64', 'aarch64': 'arm64'}[os.uname().machine]
RESTART_HINT = '重启输入法框架（Fcitx 5：fcitx5 -r；IBus：ibus restart），或注销后重新登录即可生效。'
WORK = tempfile.mkdtemp(prefix='imejd-update-test-')
# What install.sh, the one in the tarballs built here, writes: its own path.
MARK = os.path.join(WORK, 'installed')

# ---- The notification service ----

NOTIFICATIONS = '''
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="Notify">
      <arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/>
      <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
      <arg type="u" direction="out"/>
    </method>
  </interface>
</node>'''

_notified = []


def _notify(connection, sender, path, interface, method, parameters, invocation):
    app, _, icon, title, body, _, _, _ = parameters.unpack()
    _notified.append({'app': app, 'icon': icon, 'title': title, 'body': body})
    invocation.return_value(GLib.Variant('(u)', (len(_notified),)))


BUS = Gio.bus_get_sync(Gio.BusType.SESSION)
BUS.register_object('/org/freedesktop/Notifications',
                    Gio.DBusNodeInfo.new_for_xml(NOTIFICATIONS).interfaces[0], _notify, None, None)
BUS.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
              GLib.Variant('(su)', ('org.freedesktop.Notifications', 0)), None, Gio.DBusCallFlags.NONE, -1, None)


def told():
    """What the user was told since last asked, as (title, body) pairs."""
    said = [(n['title'], n['body']) for n in _notified]
    for n in _notified:
        check_eq((n['app'], n['icon']), ('键道', 'fcitx-ime-jd'), 'the notification’s sender')
    _notified.clear()
    return said

# ---- The feed ----


class Feed:
    status = 200
    release = {}
    files = {}
    headers = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/latest':
            Feed.headers = dict(self.headers)
            body = json.dumps(Feed.release) if Feed.status == 200 else '{"message": "API rate limit exceeded"}'
            self._send(Feed.status, body.encode())
        elif self.path.startswith('/download/'):
            # As GitHub's: a redirect to where the file is.
            self.send_response(302)
            self.send_header('Location', '/objects/' + self.path[len('/download/'):])
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif self.path.startswith('/objects/') and self.path[len('/objects/'):] in Feed.files:
            self._send(200, Feed.files[self.path[len('/objects/'):]])
        else:
            self._send(404, b'')

    def _send(self, status, body):
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


SERVER = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=SERVER.serve_forever, daemon=True).start()
BASE = f'http://127.0.0.1:{SERVER.server_address[1]}'


def tarball(folder, script):
    """A release's tarball, as build.sh lays it out — but for install.sh."""
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w:xz') as archive:
        content = script.encode()
        info = tarfile.TarInfo(f'{folder}/install.sh')
        info.size = len(content)
        info.mode = 0o755
        archive.addfile(info, io.BytesIO(content))
    return data.getvalue()


def publish(tag, digest=True, tarball_for_this_machine=True):
    """Makes `tag` the latest release; returns its tarball's name and
    SHA-256."""
    name = f'jd-ime-{tag}-linux-{ARCH}.tar.xz'
    data = tarball(name[:-len('.tar.xz')], f'#!/bin/sh\necho "$0" > "{MARK}"\n')
    sha256 = hashlib.sha256(data).hexdigest()
    Feed.status = 200
    Feed.files = {name: data}
    assets = [
        # A package whose name starts the same.
        {'name': f'jd-ime-{tag}-linux-{ARCH}-fcitx5.deb', 'size': 1,
         'browser_download_url': f'{BASE}/download/x.deb'},
    ]
    if tarball_for_this_machine:
        asset = {'name': name, 'size': len(data), 'browser_download_url': f'{BASE}/download/{name}',
                 'uploader': {'login': 'hronro', 'name': 'someone'}}
        if digest:
            asset['digest'] = 'sha256:' + (sha256 if digest is True else digest)
        assets.append(asset)
    Feed.release = {'tag_name': tag, 'name': tag, 'assets': assets, 'body': '"tag_name": "v9.9.9"'}
    return name, sha256

# ---- The updater ----


def updater(*args, sudo=''):
    """Runs the updater against the feed here, with `sudo` in pkexec's place
    (none: install.sh runs as is), answering its notifications meanwhile.
    Returns its exit status and output."""
    env = dict(os.environ, IMEJD_UPDATE_FEED=f'{BASE}/latest', IMEJD_UPDATE_SUDO=sudo)
    process = subprocess.Popen([UPDATER, *args], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True)
    output = []
    reader = threading.Thread(target=lambda: output.append(process.stdout.read()))
    reader.start()
    while process.poll() is None:
        pump(0.02)
    reader.join()
    pump(0.1)
    return process.returncode, ''.join(output)


def state():
    """update.ini, as a dict."""
    try:
        with open(os.path.join(CONFIG_DIR, 'update.ini'), encoding='utf-8') as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return {}
    check_eq(lines[:1], ['[Update]'], 'update.ini’s group')
    return dict(line.split('=', 1) for line in lines[1:] if '=' in line)


def fresh():
    shutil.rmtree(CONFIG_DIR, ignore_errors=True)
    shutil.rmtree(CACHE_DIR, ignore_errors=True)
    if os.path.exists(MARK):
        os.remove(MARK)
    _notified.clear()


def fake_pkexec(status):
    """A pkexec that does nothing, and exits as pkexec does when the request
    is dismissed (126) or not authorized (127)."""
    path = os.path.join(WORK, f'pkexec-{status}')
    with open(path, 'w') as f:
        f.write(f'#!/bin/sh\nexit {status}\n')
    os.chmod(path, 0o755)
    return path


def script_of(name):
    return os.path.join(CACHE_DIR, 'updates', name[:-len('.tar.xz')], 'install.sh')

# ---- Tests ----


@test
def a_newer_release_is_recorded_and_told_once():
    fresh()
    name, sha256 = publish('v99.0.0')
    status, output = updater('check')
    check_eq(status, 0, f'the check’s exit status ({output})')
    recorded = state()
    check_eq(recorded.get('Latest'), 'v99.0.0', 'the latest release')
    check_eq(recorded.get('TarballName'), name, 'the tarball for this machine, not the package')
    check_eq(recorded.get('TarballUrl'), f'{BASE}/download/{name}', 'its URL')
    check_eq(recorded.get('TarballSha256'), sha256, 'its SHA-256')
    check_eq(recorded.get('Notified'), 'v99.0.0', 'told about')
    check_eq(recorded.get('Installed'), f'v{VERSION}', 'what is installed: the updater’s own version')
    check('Busy' not in recorded and 'BusyPid' not in recorded, f'no longer busy: {recorded}')
    check(abs(int(recorded.get('LastCheck', 0)) - time.time()) < 60, 'stamped now')
    check_eq(told(), [('键道输入法有新版本', 'v99.0.0 已发布，可从输入法菜单下载并安装。')], 'the notification')
    check_eq(Feed.headers.get('User-Agent'), f'ime-jd-linux/{VERSION}', 'the User-Agent')
    check_eq(Feed.headers.get('Accept'), 'application/vnd.github+json', 'the Accept header')
    check_eq(Feed.headers.get('X-GitHub-Api-Version'), '2022-11-28', 'the API version')

    # Once per release.
    updater('check')
    check_eq(told(), [], 'the next check says nothing')


@test
def a_check_from_the_menu_tells_every_outcome():
    fresh()
    publish('v99.0.0')
    updater('check', '--interactive')
    check_eq(told(), [('发现新版本 v99.0.0', f'当前版本 {VERSION}。在输入法菜单中选择「发现新版本 v99.0.0，'
                       '下载并安装…」即可更新，安装时需要输入管理员密码。')], 'a newer release')

    publish('v99.0.0', digest=False)
    updater('check', '--interactive')
    check_eq(told(), [('发现新版本 v99.0.0', f'当前版本 {VERSION}。此版本没有适用于本机的安装包，请前往发布页面下载。')],
             'a release with no tarball to check and install')
    fresh()
    publish('v99.0.0', digest=False)
    updater('check')
    check_eq(told(), [('键道输入法有新版本', 'v99.0.0 已发布，可从输入法菜单打开发布页面下载。')],
             'told automatically of a release with no tarball to install')

    publish(f'v{VERSION}')
    updater('check', '--interactive')
    check_eq(told(), [('已是最新版本', f'键道输入法 {VERSION} 已经是最新版本。')], 'this release')

    Feed.status = 403
    status, _ = updater('check', '--interactive')
    check_eq(status, 1, 'a failed check’s exit status')
    check_eq(told(), [('无法检查更新', 'HTTP 403\n可以稍后再试，或手动前往发布页面查看。')], 'a failed check')
    check_eq(state().get('Latest'), f'v{VERSION}', 'what the last good check found stays')
    updater('check')
    check_eq(told(), [], 'an automatic check that fails says nothing')


@test
def an_install_checks_the_download_and_runs_install_sh():
    fresh()
    name, _ = publish('v99.0.0')
    updater('check')
    told()
    status, output = updater('install')
    check_eq(status, 0, f'the install’s exit status ({output})')
    try:
        with open(MARK) as f:
            check_eq(f.read().strip(), script_of(name), 'install.sh ran, from the tarball downloaded')
    except FileNotFoundError:
        check(False, 'install.sh ran')
    check_eq(told(), [('键道输入法已更新到 v99.0.0', RESTART_HINT)], 'the notification')
    recorded = state()
    check_eq(recorded.get('Installed'), 'v99.0.0', 'what is installed now')
    check('Busy' not in recorded, f'no longer busy: {recorded}')
    check(not os.path.exists(os.path.join(CACHE_DIR, 'updates')), 'the download is cleared away')

    # Until the framework restarts, the menu still runs the old build, which
    # offers the update again: the updater, already the new one, says how to
    # restart. Here the updater is not the new one, so the feed stands in.
    publish(f'v{VERSION}')
    updater('check')
    status, _ = updater('install')
    check_eq(status, 0, 'nothing newer to install')
    check_eq(told(), [(f'键道输入法已更新到 v{VERSION}', RESTART_HINT)], 'how to restart')
    check(not os.path.exists(os.path.join(CACHE_DIR, 'updates')), 'nothing downloaded')


@test
def a_download_that_does_not_match_its_digest_is_not_installed():
    fresh()
    publish('v99.0.0', digest='0' * 64)
    updater('check')
    told()
    status, _ = updater('install')
    check_eq(status, 1, 'the install’s exit status')
    check(not os.path.exists(MARK), 'install.sh did not run')
    check_eq(told(), [('下载安装包失败', '下载的文件校验失败（SHA-256 不匹配），已放弃安装\n'
                       '可以稍后再试，或手动前往发布页面下载。')], 'the notification')
    check('Busy' not in state(), 'no longer busy')


@test
def an_authorization_not_given_leaves_the_command_to_run():
    log = os.path.join(CACHE_DIR, 'updates', 'install.log')
    for sudo, title, words in (
            (fake_pkexec(126), '没有安装新版本', '没有获得管理员授权。可以从输入法菜单重试，或在终端中运行：'),
            (fake_pkexec(127), '无法获得管理员权限', f'没能取得管理员授权，详见 {log}。请在终端中运行：'),
            (os.path.join(WORK, 'no-pkexec'), '无法获得管理员权限', '没有找到 pkexec。请在终端中运行：')):
        fresh()
        name, _ = publish('v99.0.0')
        updater('check')
        told()
        exit_status, _ = updater('install', sudo=sudo)
        what = os.path.basename(sudo)
        check_eq(exit_status, 1, f'{what}: the install’s exit status')
        check(not os.path.exists(MARK), f'{what}: install.sh did not run')
        check_eq(told(), [(title, f'{words}\nsudo sh {script_of(name)}')], f'{what}: the notification')
        check(os.access(script_of(name), os.R_OK), f'{what}: the script is there to run')
        check_eq(state().get('Installed'), f'v{VERSION}', f'{what}: still what was installed')


@test
def a_release_that_cannot_be_installed_here_opens_its_page():
    fresh()
    publish('v99.0.0', tarball_for_this_machine=False)
    updater('check')
    told()
    status, output = updater('install')
    check_eq(status, 0, 'the exit status')
    page = 'https://github.com/hronro/ime-jd/releases/tag/v99.0.0'
    check(f'Opening {page}' in output, f'the release page: {output}')
    # Where no browser opens it — as here, most likely — it is told.
    said = told()
    check(said in ([], [('发现新版本 v99.0.0', f'请前往发布页面下载：\n{page}')]), f'the notification: {said}')
    check(not os.path.exists(os.path.join(CACHE_DIR, 'updates')), 'nothing downloaded')


@test
def one_updater_runs_at_a_time():
    fresh()
    publish('v99.0.0')
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(os.path.join(CACHE_DIR, 'update.lock'), 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        status, _ = updater('check', '--interactive')
    check_eq(status, 0, 'the second updater’s exit status')
    check_eq(told(), [], 'it says nothing')
    check_eq(state(), {}, 'and records nothing')


try:
    run()
finally:
    shutil.rmtree(WORK, ignore_errors=True)
