#!/usr/bin/env python3
"""键道's IBus engine, installed, in a real ibus-daemon: keys go in through an
input context, as an application's IM module sends them, and what reaches
the application comes back as the context's signals. run.sh sets up the
session."""

import os
import time

import gi

gi.require_version('IBus', '1.0')
from gi.repository import IBus  # noqa: E402

from harness import check, check_eq, pump, run, test, value, wait_for  # noqa: E402

CONFIG_DIR = os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'ime-jd')
RELEASE = IBus.ModifierType.RELEASE_MASK
SHIFT = IBus.ModifierType.SHIFT_MASK


def connect():
    # ibus-daemon writes its address once it is up.
    deadline = time.monotonic() + 10
    while True:
        bus = IBus.Bus()
        if bus.is_connected() or time.monotonic() > deadline:
            return bus
        time.sleep(0.2)


IBus.init()
BUS = connect()

# What the input context's signals hand over, kept for the rest of the run.
# libibus emits them floating and unrefs any still floating once the handlers
# return, but newer PyGObject sinks such an argument and lets go of it with
# its Python wrapper: libibus then checks a freed object — a warning under
# glibc, a crash under musl. Holding on keeps them alive past that check.
_received = []


def keep(*objects):
    _received.extend(objects)


def describe(prop):
    symbol = prop.get_symbol()
    return {
        'label': prop.get_label().get_text(),
        'symbol': symbol.get_text() if symbol else '',
        'state': prop.get_state(),
    }


class Context:
    """An application's input context, focused, with 键道 as its engine."""

    def __init__(self):
        self.ic = BUS.create_input_context('imejd-e2e')
        self.committed = ''
        self.preedit = ''
        self.candidates = []
        self.properties = {}
        self.ic.connect('commit-text', self._commit)
        self.ic.connect('update-preedit-text', self._preedit)
        self.ic.connect('hide-preedit-text', lambda ic: setattr(self, 'preedit', ''))
        self.ic.connect('update-lookup-table', self._table)
        self.ic.connect('hide-lookup-table', lambda ic: setattr(self, 'candidates', []))
        self.ic.connect('register-properties', self._properties)
        self.ic.connect('update-property', self._property)
        self.ic.set_capabilities(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.LOOKUP_TABLE
                                 | IBus.Capabilite.PROPERTY | IBus.Capabilite.FOCUS)
        self.ic.focus_in()
        # As GNOME's panel does: one engine for every application, which
        # newer IBus insists on by default.
        BUS.set_global_engine('ime-jd')
        check(wait_for(lambda: 'InputMode' in self.properties), 'the engine registered its properties')
        # The engine is shared, so is its mode: start each test in 中.
        if self.properties.get('InputMode', {}).get('symbol') == '英':
            self.ic.property_activate('InputMode', IBus.PropState.UNCHECKED)
            check(wait_for(lambda: self.mode() == '中'), 'the InputMode item switches back to 中')

    def _commit(self, ic, text):
        keep(text)
        self.committed += text.get_text()

    def _preedit(self, ic, text, cursor, visible):
        keep(text)
        self.preedit = text.get_text() if visible else ''

    def _table(self, ic, table, visible):
        keep(table)
        count = table.get_number_of_candidates() if visible else 0
        self.candidates = [value(table.get_candidate(i).get_text()) for i in range(count)]

    # The menu as GNOME's panel keeps it: the first one the engine registers,
    # and from then on only updates to its items, so the engine has to send
    # every change as one.

    def _properties(self, ic, props):
        keep(props)
        if self.properties or props.get(0) is None:
            return
        i = 0
        while (prop := props.get(i)) is not None:
            self.properties[prop.get_key()] = describe(prop)
            i += 1

    def _property(self, ic, prop):
        keep(prop)
        if prop.get_key() in self.properties:
            self.properties[prop.get_key()] = describe(prop)

    def mode(self):
        return self.properties['InputMode']['symbol']

    def key(self, keyval, state=0):
        """One key event, press or release; returns whether it was consumed."""
        handled = self.ic.process_key_event(keyval, 0, state)
        pump(0.05)
        return handled

    def press(self, keyval, state=0):
        """A key pressed and released; returns whether the press was consumed."""
        handled = self.key(keyval, state)
        self.key(keyval, state | RELEASE)
        return handled

    def type(self, keys):
        return all([self.press(ord(c)) for c in keys])

    def tap_shift(self):
        self.key(IBus.KEY_Shift_L)
        self.key(IBus.KEY_Shift_L, SHIFT | RELEASE)

    def refocus(self):
        self.ic.focus_out()
        self.ic.focus_in()
        pump(0.2)


@test
def typing_composes_and_space_commits():
    c = Context()
    check(c.type('n'), 'n is consumed')
    check_eq(c.preedit, 'n', 'the preedit')
    check(c.candidates, 'candidates are shown')
    first = c.candidates[0] if c.candidates else None
    check(c.press(IBus.KEY_space), 'space is consumed')
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
def minus_and_equals_page():
    c = Context()
    c.type('j')
    first_page = list(c.candidates)
    c.type('=')
    check(c.candidates and c.candidates != first_page, '= shows the next page')
    c.type('-')
    check_eq(c.candidates, first_page, '- shows the first page again')


@test
def return_commits_the_letters():
    c = Context()
    c.type('jd')
    check(c.press(IBus.KEY_Return), 'Return is consumed')
    check_eq(c.committed, 'jd', 'what Return commits')


@test
def escape_cancels():
    c = Context()
    c.type('jd')
    check(c.press(IBus.KEY_Escape), 'Escape is consumed')
    check_eq(c.committed, '', 'what Escape commits')
    check_eq(c.preedit, '', 'the preedit after Escape')
    check_eq(c.candidates, [], 'the candidates after Escape')


@test
def focus_out_commits_the_letters_once():
    c = Context()
    c.type('jd')
    c.ic.focus_out()
    pump(0.3)
    check_eq(c.committed, 'jd', 'what focus out commits')


@test
def reset_commits_the_letters_once():
    c = Context()
    c.type('jd')
    c.ic.reset()
    pump(0.3)
    check_eq(c.committed, 'jd', 'what reset commits')
    check(c.type('j') and c.preedit == 'j', f'the next key starts afresh: {c.preedit!r}')


@test
def switching_engines_commits_the_letters_once():
    c = Context()
    c.type('jd')
    BUS.set_global_engine('xkb:us::eng')
    pump(0.3)
    check_eq(c.committed, 'jd', 'what switching engines commits')


@test
def shift_alone_switches_to_english_and_back():
    c = Context()
    check_eq(c.mode(), '中', 'the mode before the switch')
    c.tap_shift()
    check(wait_for(lambda: c.mode() == '英'), 'a Shift tap switches to 英')
    check(not c.press(ord('a')), 'in 英, a goes to the application')
    check_eq(c.committed, '', 'what 英 commits')
    c.tap_shift()
    check(wait_for(lambda: c.mode() == '中'), 'a second tap switches back to 中')
    check(c.press(ord('a')), 'in 中, a is the engine’s')


@test
def shift_used_as_a_modifier_does_not_switch():
    c = Context()
    c.key(IBus.KEY_Shift_L)
    c.key(ord('A'), SHIFT)
    c.key(ord('A'), SHIFT | RELEASE)
    c.key(IBus.KEY_Shift_L, SHIFT | RELEASE)
    pump(0.3)
    check_eq(c.mode(), '中', 'the mode after Shift+A')


@test
def switching_to_english_commits_the_letters():
    c = Context()
    c.type('jd')
    c.tap_shift()
    check(wait_for(lambda: c.committed == 'jd'), f'the letters go in as typed: got {c.committed!r}')


@test
def the_mode_item_switches_too():
    c = Context()
    c.ic.property_activate('InputMode', IBus.PropState.UNCHECKED)
    check(wait_for(lambda: c.mode() == '英'), 'the InputMode item switches to 英')


@test
def the_panel_icon_follows_the_mode():
    # IBus's own panel draws the named property's symbol, 中 or 英, as its
    # tray icon, as it draws "en" for an English layout.
    engines = BUS.get_engines_by_names(['ime-jd'])
    check_eq(engines[0].get_icon_prop_key() if engines else None, 'InputMode', 'the panel icon’s property')


@test
def password_fields_get_the_keys_as_typed():
    c = Context()
    c.ic.set_content_type(IBus.InputPurpose.PASSWORD, 0)
    pump(0.2)
    check(not c.press(ord('a')), 'in a password field, a goes to the application')
    c.ic.set_content_type(IBus.InputPurpose.FREE_FORM, 0)
    pump(0.2)
    check(c.press(ord('a')), 'out of it, a is the engine’s again')


@test
def the_user_dictionary_is_read_live_and_switched_from_the_menu():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(os.path.join(CONFIG_DIR, '用户自造词.txt'), 'w', encoding='utf-8') as f:
        f.write('键道\tz\n')
    c = Context()
    # The engine's process watches the file; give the reload its moment.
    check(wait_for(lambda: (c.refocus() or True)
                   and c.properties['imejd-user-dict-status']['label'] == '用户自造词：1 条'),
          f'the status line: {c.properties.get("imejd-user-dict-status")}')
    c.type('z')
    check(c.candidates and c.candidates[0] != '键道', 'switched off, the phrase is not offered')
    c.press(IBus.KEY_Escape)

    c.ic.property_activate('imejd-user-dict-enabled', IBus.PropState.CHECKED)
    check(wait_for(lambda: c.properties['imejd-user-dict-enabled']['state'] == IBus.PropState.CHECKED),
          'the switch shows as on')
    with open(os.path.join(CONFIG_DIR, 'settings.ini'), encoding='utf-8') as f:
        check_eq(f.read(), '[UserDict]\nEnabled=true\n', 'settings.ini')
    c.type('z')
    check(c.candidates and c.candidates[0] == '键道', f'switched on, the phrase comes first: {c.candidates[:3]}')


run()
