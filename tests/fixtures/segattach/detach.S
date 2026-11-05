// segdetach of the stack fails; of a shared segment, it succeeds, and the
// next read of it faults.

#include "lib.S"

	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x19, x0
	str x19, [x19]
	mov x1, sp
	SYS 31
	mov x28, #1
	cmn x0, #1
	b.ne die
	mov x1, x19
	SYS 31
	CHECK 2
	ldr x2, [x19]
	mov x28, #3
	b die
