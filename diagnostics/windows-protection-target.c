/* A real executable image page for the protection/suspension comparison.
 * mov eax, 7; ret. The disposable probe changes the immediate after its one
 * initial call, and never executes the changed bytes. No mocks. */
__declspec(dllexport) __attribute__((naked, noinline, aligned(4096)))
int repro_probe_code(void) {
    __asm__("mov $7, %eax\nret");
}
