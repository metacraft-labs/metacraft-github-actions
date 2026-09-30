## Real x64 child for the existing borrowed-call tests on ARM hosts.
## Native ARM System32 cmd.exe cannot exercise an x64 entry-point park.
## Preserve the tests' command arguments and actual process exit status.
## No mocks: Windows creates, parks, injects, resumes and terminates this child.
import std/os

if commandLineParams() != @["/c", "exit", "42"]:
  quit(97)
quit(42)
