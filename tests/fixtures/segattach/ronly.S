// A write to a segment attached with SG_RONLY faults.

#include "lib.S"

	mov x1, #0x20
	adr x2, memory
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x19, x0
	ldr x2, [x19]
	str x2, [x19]
	mov x28, #1
	b die
