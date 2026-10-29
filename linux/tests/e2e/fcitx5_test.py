#!/usr/bin/env python3
"""键道's Fcitx 5 addon, installed, in a real fcitx5: keys go in through an
input context of Fcitx's D-Bus frontend, as fcitx5-gtk and fcitx5-qt send
them, and what reaches the application comes back as the context's signals.
run.sh sets up the session and Fcitx's profile, with 键道 in the group."""

import os
import time

from gi.repository import Gio, GLib

from harness import check, check_eq, pump, run, test, value, wait_for

SERVICE = 'org.fcitx.Fcitx5'
CONFIG_DIR = os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'ime-jd')

# fcitx-utils/capabilityflags.h
PREEDIT = 1 << 1
PASSWORD = 1 << 3
FORMATTED_PREEDIT = 1 << 4
CLIENT_SIDE_INPUT_PANEL = 1 << 39

BackSpace, Return, Escape, Shift_L, space = 0xff08, 0xff0d, 0xff1b, 0xffe1, 0x20
SHIFT = 1 << 0

BUS = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def proxy(path, interface):
    return Gio.DBusProxy.new_sync(BUS, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None, SERVICE, path, interface, None)


def call(target, method, signature=None, *args):
    parameters = GLib.Variant(signature, args) if signature else None
    return target.call_sync(method, parameters, Gio.DBusCallFlags.NONE, -1, None).unpack()


def wait_for_fcitx():
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        names = call(proxy_of_bus(), 'ListNames')[0]
        if SERVICE in names:
            return
        time.sleep(0.2)
    raise SystemExit('fcitx5 is not on the bus')


def proxy_of_bus():
    return Gio.DBusProxy.new_sync(BUS, Gio.DBusProxyFlags.NONE, None, 'org.freedesktop.DBus',
                                  '/org/freedesktop/DBus', 'org.freedesktop.DBus', None)


wait_for_fcitx()
CONTROLLER = proxy('/controller', 'org.fcitx.Fcitx.Controller1')


def current_im():
    return call(CONTROLLER, 'CurrentInputMethod')[0]


class Context:
    """An application's input context, focused, with 键道 as its input
    method. It shows the input panel itself, so the candidates come to it."""

    def __init__(self, capabilities=PREEDIT | FORMATTED_PREEDIT | CLIENT_SIDE_INPUT_PANEL):
        im = proxy('/org/freedesktop/portal/inputmethod', 'org.fcitx.Fcitx.InputMethod1')
        path, _ = call(im, 'CreateInputContext', '(a(ss))', [('program', 'imejd-e2e')])
        self.ic = proxy(path, 'org.fcitx.Fcitx.InputContext1')
        self.committed = ''
        self.preedit = ''
        self.candidates = []
        self.ic.connect('g-signal', self._signal)
        self.capability(capabilities)
        call(self.ic, 'FocusIn')
        call(CONTROLLER, 'SetCurrentIM', '(s)', 'ime-jd')
        check(wait_for(lambda: current_im() == 'ime-jd'), f'键道 is the current input method: {current_im()}')

    def capability(self, capabilities):
        call(self.ic, 'SetCapability', '(t)', capabilities)

    def _signal(self, proxy, sender, name, parameters):
        args = parameters.unpack()
        if name == 'CommitString':
            self.committed += args[0]
        elif name == 'UpdateFormattedPreedit':
            self.preedit = ''.join(text for text, _ in args[0])
        elif name == 'UpdateClientSideUI':
            self.candidates = [value(text) for _, text in args[4]]

    def key(self, keyval, state=0, release=False):
        handled = call(self.ic, 'ProcessKeyEvent', '(uuubu)', keyval, 0, state, release, 0)[0]
        pump(0.05)
        return handled

    def press(self, keyval, state=0):
        handled = self.key(keyval, state)
        self.key(keyval, state, release=True)
        return handled

    def type(self, keys):
        return all([self.press(ord(c)) for c in keys])


@test
def typing_composes_and_space_commits():
    c = Context()
    check(c.type('n'), 'n is consumed')
    check_eq(c.preedit, 'n', 'the preedit')
    check(c.candidates, 'candidates are shown')
    first = c.candidates[0] if c.candidates else None
    check(c.press(space), 'space is consumed')
    check_eq(c.committed, first, 'space commits the first candidate')
    check_eq(c.candidates, [], 'the candidates once committed')
    check_eq(c.preedit, '', 'the preedit once committed')


@test
def a_period_commits_the_chinese_full_stop():
    c = Context()
    check(c.type('.'), '. is consumed')
    check_eq(c.committed, '。', 'what . commits')


@test
def a_digit_selects():
    c = Context()
    c.type('j')
    second = c.candidates[1]
    check(c.type('2'), '2 is consumed')
    check_eq(c.committed, second, 'what 2 commits')


@test
def a_click_selects():
    c = Context()
    c.type('j')
    third = c.candidates[2]
    call(c.ic, 'SelectCandidate', '(i)', 2)
    check(wait_for(lambda: c.committed == third, 2), f'a click commits the candidate: got {c.committed!r}')


@test
def minus_and_equals_page():
    c = Context()
    c.type('j')
    first_page = list(c.candidates)
    c.type('=')
    check(c.candidates and c.candidates != first_page, '= shows the next page')
    c.type('-')
    check_eq(c.candidates, first_page, '- shows the first page again')


@test
def backspace_shrinks_then_ends():
    c = Context()
    c.type('jd')
    check(c.press(BackSpace), 'BackSpace is consumed')
    check_eq(c.preedit, 'j', 'the preedit after one BackSpace')
    c.press(BackSpace)
    check_eq(c.preedit, '', 'the preedit after two')
    check_eq(c.candidates, [], 'the candidates after two')
    check(not c.press(BackSpace), 'with nothing composing, BackSpace goes to the application')


@test
def return_commits_the_letters():
    c = Context()
    c.type('jd')
    check(c.press(Return), 'Return is consumed')
    check_eq(c.committed, 'jd', 'what Return commits')


@test
def escape_cancels():
    c = Context()
    c.type('jd')
    check(c.press(Escape), 'Escape is consumed')
    check_eq(c.committed, '', 'what Escape commits')
    check_eq(c.preedit, '', 'the preedit after Escape')


@test
def a_control_chord_goes_to_the_application():
    c = Context()
    check(not c.press(ord('a'), 1 << 2), 'Ctrl+a goes to the application')
    check_eq(c.committed, '', 'what Ctrl+a commits')


@test
def switching_input_methods_commits_the_letters():
    c = Context()
    c.type('jd')
    call(CONTROLLER, 'SetCurrentIM', '(s)', 'keyboard-us')
    check(wait_for(lambda: c.committed == 'jd', 2), f'the letters go in as typed: got {c.committed!r}')


@test
def focus_out_commits_the_letters_once():
    # Fcitx commits the preedit for an application that cannot do it itself
    # once unfocused, as this one; the addon must not add its own.
    c = Context()
    c.type('jd')
    call(c.ic, 'FocusOut')
    pump(0.3)
    check_eq(c.committed, 'jd', 'what focus out commits')


@test
def focus_out_without_a_preedit_commits_the_letters():
    # The application could not show a preedit, so the letters were in
    # Fcitx's own panel, and only the addon can put them in.
    c = Context(capabilities=CLIENT_SIDE_INPUT_PANEL)
    c.type('jd')
    call(c.ic, 'FocusOut')
    pump(0.3)
    check_eq(c.committed, 'jd', 'what focus out commits')


@test
def reset_drops_the_composition():
    # Fcitx's GTK and Qt modules commit their preedit before they reset; this
    # client does not, so nothing is committed at all.
    c = Context()
    c.type('jd')
    call(c.ic, 'Reset')
    pump(0.3)
    check_eq(c.committed, '', 'what reset commits')
    check(c.type('j') and c.preedit == 'j', f'the next key starts afresh: {c.preedit!r}')


@test
def left_shift_while_composing_commits_the_letters():
    c = Context()
    c.type('jd')
    c.key(Shift_L)
    c.key(Shift_L, SHIFT, release=True)
    check(wait_for(lambda: current_im() == 'keyboard-us', 2), 'Left Shift switches to the layout')
    check_eq(c.committed, 'jd', 'the letters go in as typed')


@test
def left_shift_is_fcitx_s_own_switch():
    c = Context()
    c.key(Shift_L)
    c.key(Shift_L, SHIFT, release=True)
    check(wait_for(lambda: current_im() == 'keyboard-us', 2), f'Left Shift switches to the layout: {current_im()}')
    c.key(Shift_L)
    c.key(Shift_L, SHIFT, release=True)
    check(wait_for(lambda: current_im() == 'ime-jd', 2), f'and back: {current_im()}')


@test
def password_fields_get_the_keys_as_typed():
    c = Context()
    c.capability(PREEDIT | FORMATTED_PREEDIT | CLIENT_SIDE_INPUT_PANEL | PASSWORD)
    check(not c.press(ord('a')), 'in a password field, a goes to the application')


@test
def the_user_dictionary_is_read_live():
    c = Context()
    c.type('z')
    check(c.candidates and c.candidates[0] != '键道', 'with no phrases, the built-in word comes first')
    c.press(Escape)
    # Written by the editor, or by hand: fcitx5's event loop sees the save.
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(os.path.join(CONFIG_DIR, '用户自造词.txt'), 'w', encoding='utf-8') as f:
        f.write('键道\tz\n')
    with open(os.path.join(CONFIG_DIR, 'settings.ini'), 'w', encoding='utf-8') as f:
        f.write('[UserDict]\nEnabled=true\n')
    pump(1.0)
    c.type('z')
    check(c.candidates and c.candidates[0] == '键道', f'the phrase comes first: {c.candidates[:3]}')


run()
