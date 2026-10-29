"""What the end-to-end tests share: checks that record failures instead of
stopping, and a way to let D-Bus signals arrive."""

import sys
import time

from gi.repository import GLib

_tests = []
_failures = 0
_current = ''


def test(function):
    """Registers `function` as a test, run in the order of registration."""
    _tests.append(function)
    return function


def check(condition, what):
    global _failures
    if not condition:
        _failures += 1
        print(f'FAIL {_current}: {what}', file=sys.stderr)
    return condition


def check_eq(actual, expected, what):
    return check(actual == expected, f'{what}: got {actual!r}, expected {expected!r}')


def pump(seconds=0.1):
    """Delivers what the daemon has sent: its signals arrive asynchronously."""
    context = GLib.MainContext.default()
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        while context.iteration(False):
            pass
        time.sleep(0.005)


def wait_for(predicate, seconds=5.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        pump(0.02)
        if predicate():
            return True
    return False


def value(shown):
    """A candidate's value, without the 〔hint〕 shown after it."""
    return shown.split(' 〔')[0]


def run():
    global _current
    for function in _tests:
        _current = function.__name__
        print(f'-- {_current}', flush=True)
        function()
    print(f'{len(_tests)} tests, {_failures} failures', flush=True)
    sys.exit(1 if _failures else 0)
