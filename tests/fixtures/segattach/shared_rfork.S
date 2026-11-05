// A shared segment, then rfork(RFPROC): the child writes 42 into it, and
// the parent, after await, reads 42.

#include "lib.S"

	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x19, x0
	mov x1, #0x10
	SYS 19
	CHECK 1
	cbnz x0, 1f
	mov x2, #42
	str x2, [x19]
	b ok
1:	add x1, sp, #128
	mov x2, #64
	SYS 47
	CHECK 2
	ldr x2, [x19]
	mov x28, #3
	cmp x2, #42
	b.ne die
	b ok
