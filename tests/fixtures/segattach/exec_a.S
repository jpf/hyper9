// A memory segment holding 42 and an SG_CEXEC one, then exec of /b
// (exec_b, served by the test).

#include "lib.S"

	mov x1, #0
	adr x2, memory
	LI x3, 0x100000000
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x2, #42
	str x2, [x0]
	mov x1, #0x40
	adr x2, memory
	LI x3, 0x100100000
	mov x4, #0x1000
	SYS 30
	CHECK 1
	adr x1, path
	str x1, [sp, #128]
	str xzr, [sp, #136]
	add x2, sp, #128
	SYS 7
	mov x28, #2
	b die
path:	.asciz "/b"
	.balign 4
