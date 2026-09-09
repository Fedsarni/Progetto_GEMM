#include "platform.h"

/* Minimal stubs: no real UART/interrupt setup needed for standalone use
 * with the BSP's built-in stdin/stdout already pointed at ps7_uart_0. */

void init_platform()
{
}

void cleanup_platform()
{
}

/* Normally provided by the toolchain's crti.o/crtn.o, excluded by
 * -nostartfiles: empty stubs are enough for a standalone app like this. */
void _init(void)
{
}

void _fini(void)
{
}
