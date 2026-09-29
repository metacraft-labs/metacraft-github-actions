"""Pass inferior INT3 signals while leaving GDB's own traps private."""
import gdb

stopped_signal = None


def remember_stop(event):
    global stopped_signal
    stopped_signal = event.stop_signal if isinstance(event, gdb.SignalEvent) else None


gdb.events.stop.connect(remember_stop)
command = 'run'
trap_count = 0
for _ in range(200000):
    stopped_signal = None
    output = gdb.execute(command, to_string=True)
    if stopped_signal != 'SIGTRAP':
        print(output)
        break
    trap_count += 1
    if trap_count <= 3:
        print('Inferior trap', trap_count, gdb.selected_frame().name())
        print(gdb.execute('bt 5', to_string=True))
    # Unlike a global `handle ... pass`, this delivers only the inferior's
    # reported signal. The debugger's loader breakpoints retain `nopass`.
    command = 'signal SIGTRAP'
else:
    raise gdb.GdbError('Inferior trap budget exhausted')
print('Inferior SIGTRAP count:', trap_count, 'final signal:', stopped_signal)
