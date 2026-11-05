// Run by exec_a's exec: the memory segment is still there with 42 in it,
// and reading the SG_CEXEC one faults.

#include "lib.S"

	LI x5, 0x100000000
	ldr x2, [x5]
	mov x28, #0
	cmp x2, #42
	b.ne die
	LI x5, 0x100100000
	ldr x2, [x5]
	mov x28, #1
	b die
