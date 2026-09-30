"""Add volatile checkpoints to the disposable hook transaction.

No logging, allocation, extra suspension or deadline change. The existing
parent reads the exported phase only after the borrowed call has failed.
"""
import json
from pathlib import Path

base = Path('nim-stackable-hooks/src/stackable_hooks/inline_hook/windows')
phases_path = Path('build/windows-arm-injection/init-phases.json')
phases = json.loads(phases_path.read_text())
declaration = '''
#include <stdint.h>
extern volatile unsigned long repro_diagnostic_init_phase;
extern volatile uintptr_t repro_diagnostic_patch_target;
extern volatile unsigned long repro_diagnostic_frozen_count;
extern volatile unsigned long repro_diagnostic_frozen_tids[4096];
#define CT_INIT_PHASE(n) (repro_diagnostic_init_phase = (n))
'''


def instrument(path, functions):
    source = path.read_text()
    # Keep the declaration outside any conditional platform implementation.
    source = declaration + source
    for signature, checkpoints in functions:
        start = source.index(signature)
        # The signature includes the opening brace. Find its matching end
        # using brace depth; these selected functions have balanced comments.
        end = start + len(signature)
        depth = 1
        while depth:
            if source[end] == '{':
                depth += 1
            elif source[end] == '}':
                depth -= 1
            end += 1
        body = source[start:end]
        for needle, number, description in checkpoints:
            assert body.count('\n' + needle) == 1, (signature, needle, body.count('\n' + needle))
            indent = needle[:len(needle) - len(needle.lstrip())]
            body = body.replace('\n' + needle, '\n' + indent + f'CT_INIT_PHASE({number});\n' + needle)
            phases[str(number)] = description
        source = source[:start] + body + source[end:]
    path.write_text(source)


instrument(base / 'install_windows.c', [
    ('int ct_inline_hook_commit_transaction(void)\n{', [
        ('    ensure_cs_initialised();', 100, 'transaction initialize registry lock'),
        ('    EnterCriticalSection(&g_hooks_cs);', 101, 'transaction enter registry lock'),
        ('    if (suspend_other_threads(&fr) != 0) {', 102, 'transaction freeze threads'),
        ('    int rc = 0;', 103, 'transaction threads frozen'),
        ('            op_rc = install_locked(op->target, op->hook, op->out_trampoline);', 104, 'transaction install queued hook'),
        ('    resume_other_threads(&fr);', 105, 'transaction resume threads'),
        ('    return rc;', 106, 'transaction complete'),
    ]),
    ('static int suspend_other_threads(ct_frozen_t *out)\n{', [
        ('    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);', 110, 'freeze snapshot threads'),
        ('    if (Thread32First(snap, &te)) {', 111, 'freeze first snapshot entry'),
        ('                HANDLE h = OpenThread(CT_FROZEN_THREAD_ACCESS, FALSE, te.th32ThreadID);', 112, 'freeze open thread'),
        ('                    DWORD prev = SuspendThread(h);', 113, 'freeze suspend thread'),
        ('                    if (prev == (DWORD)-1) {', 114, 'freeze suspension returned'),
        ('            te.dwSize = sizeof(te);', 115, 'freeze next snapshot entry'),
        ('    CloseHandle(snap);', 116, 'freeze close snapshot'),
        ('    return 0;', 117, 'freeze complete'),
    ]),
    ('static void resume_other_threads(ct_frozen_t *f)\n{', [
        ('        ResumeThread(f->handles[i]);', 118, 'unfreeze resume thread'),
        ('        CloseHandle(f->handles[i]);', 119, 'unfreeze close thread'),
    ]),
    ('static int install_locked(void *target, void *hook, void **out_trampoline)\n{', [
        ('    CT_DBG("[ct_inline_hook] install_locked target=%p hook=%p\\n", target, hook);', 120, 'install debug environment probe'),
        ('    int hotpatch = detect_hotpatch(t);', 121, 'install detect hotpatch'),
        ('    int prologue_len = ct_ild_decode_to_cover(t, 5, (size_t)decode_max);', 122, 'install decode prologue'),
        ('    uint8_t *slot = alloc_tramp_slot((uintptr_t)t);', 123, 'install allocate trampoline'),
        ('        if (ct_thunk_arena_init(&pg->arena, (uintptr_t)pg->base) != 0) {', 124, 'install initialize thunk arena'),
        ('    int frc = ct_rel32_fixup_prologue(t, (size_t)prologue_len,', 125, 'install relocate prologue'),
        ('    if (write_patch((void *)t, 5, jmp) != 0) {', 126, 'install write patch'),
        ('    entry->target = target;', 127, 'install publish target'),
    ]),
    ('static int write_patch(void *from, size_t len, const uint8_t *bytes)\n{', [
        ('    DWORD old_prot;', 130, 'patch before writable protection'),
        ('    memcpy(from, bytes, len);', 131, 'patch copy bytes'),
        ('    VirtualProtect(from, len, old_prot, &restored);', 132, 'patch restore protection'),
        ('    FlushInstructionCache(GetCurrentProcess(), from, len);', 133, 'patch flush instruction cache'),
        ('    return 0;', 134, 'patch complete'),
    ]),
    ('static uint8_t *alloc_tramp_slot(uintptr_t target_addr)\n{', [
        ('    GetSystemInfo(&si);', 140, 'trampoline get system info'),
        ('            if (VirtualQuery((LPVOID)hi, &mbi, sizeof(mbi)) != 0) {', 141, 'trampoline query higher address'),
        ('            if (VirtualQuery((LPVOID)lo, &mbi, sizeof(mbi)) != 0) {', 142, 'trampoline query lower address'),
        ('        got = VirtualAlloc(NULL, CT_TRAMP_PAGE_BYTES,', 143, 'trampoline allocate fallback'),
        ('    memset(pg->base, 0xCC, CT_TRAMP_PAGE_BYTES);', 144, 'trampoline fill new page'),
    ]),
])

instrument(base / 'rel32_fixup.c', [
    ('int ct_thunk_arena_init(ct_thunk_arena_t *arena, uintptr_t near_addr)\n{', [
        ('    GetSystemInfo(&si);', 150, 'thunk arena get system info'),
        ('            got = VirtualAlloc((LPVOID)hi, CT_THUNK_ARENA_BYTES,', 151, 'thunk arena allocate higher address'),
        ('            got = VirtualAlloc((LPVOID)lo, CT_THUNK_ARENA_BYTES,', 152, 'thunk arena allocate lower address'),
        ('        got = VirtualAlloc(NULL, CT_THUNK_ARENA_BYTES,', 153, 'thunk arena allocate fallback'),
        ('    arena->base = (uint8_t *)got;', 154, 'thunk arena allocation complete'),
    ]),
])

# Retain only code addresses and thread ids. Stores add no calls inside the
# suspended region; the parent reads them after an already-fatal deadline.
p = base / 'install_windows.c'
s = p.read_text()
for old, new in [
    ('    out->count = 0;', '    out->count = 0;\n    repro_diagnostic_frozen_count = 0;'),
    ('                        out->count++;',
     '                        repro_diagnostic_frozen_tids[out->count] = te.th32ThreadID;\n'
     '                        out->count++;\n'
     '                        repro_diagnostic_frozen_count = out->count;'),
    ('    CT_INIT_PHASE(130);',
     '    repro_diagnostic_patch_target = (uintptr_t)from;\n    CT_INIT_PHASE(130);'),
]:
    assert s.count(old) == 1, old
    s = s.replace(old, new)
p.write_text(s)

# The broad transaction checkpoints distinguish snapshot/suspension, install,
# allocation and instruction-cache flushing without depending on stack unwinding.
phases_path.write_text(json.dumps(phases, indent=2))
print('Added volatile hook-transaction checkpoints to the disposable shim.')
