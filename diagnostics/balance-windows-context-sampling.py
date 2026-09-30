"""Control only: observe real child registers under balanced suspension.

This patches a disposable bootstrap checkout. It changes neither the hard
deadline nor any context restoration, child termination or test assertion.
"""
from pathlib import Path
import re

source = Path('nim-stackable-hooks/src/stackable_hooks/windows_entry_park.nim')
text = source.read_text()
pattern = re.compile(
    r'      var ip: uint64 = 0\n'
    r'      if instructionPointer\(hThread, childIsWow64, ip\) and ip == wantIp:\n'
    r'        discard SuspendThread\(hThread\)\n'
    r'(?:        #.*\n)*'
    r'        var confirmed: uint64 = 0\n'
    r'        if instructionPointer\(hThread, childIsWow64, confirmed\) and\n'
    r'            confirmed == wantIp:\n'
    r'(?P<parked>(?:          .*\n)+)'
    r'        discard ResumeThread\(hThread\)\n')

def balance(match):
    return (
        '      # GetThreadContext requires a suspended thread for a valid sample.\n'
        '      # Retain that suspension only after proving the park address.\n'
        '      if SuspendThread(hThread) != high(uint32):\n'
        '        var confirmed: uint64 = 0\n'
        '        if instructionPointer(hThread, childIsWow64, confirmed) and\n'
        '            confirmed == wantIp:\n' + match['parked'] +
        '        discard ResumeThread(hThread)\n')

text, count = pattern.subn(balance, text)
assert count == 2, f'Expected both park loops, found {count}'
source.write_text(text)
print('Both context polls now suspend before sampling; deadlines unchanged.')

# The control's native x64 child has the same command/exit contract as cmd.
# Leave ComSpec unchanged for the compiler and every other spawned process.
fixture = Path('nim-stackable-hooks/tests/test_windows_entry_park_slow_call.nim')
text = fixture.read_text()
assert text.count('result = getEnv("ComSpec")') == 1
fixture.write_text(text.replace('result = getEnv("ComSpec")',
                               'result = getEnv("STACKABLE_HOOKS_CONTROL_CHILD")'))
