// A shared segment, and a child that waits on a pipe. The parent detaches
// the segment, closes the pipe and waits: the child still reads the
// segment and writes "ok", and then the parent's read faults.

#include "lib.S"

	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x19, x0
	mov x2, #9
	str x2, [x19]
	add x1, sp, #128
	SYS 21
	CHECK 1
	mov x1, #0x10
	SYS 19
	CHECK 2
	cbnz x0, 1f
	ldrsw x1, [sp, #128]
	add x2, sp, #160
	mov x3, #8
	mov x4, #-1
	SYS 50
	ldr x2, [x19]
	mov x28, #3
	cmp x2, #9
	b.ne die
	mov x1, #1
	adr x2, okmsg
	mov x3, #2
	mov x4, #-1
	SYS 51
	b ok
1:	mov x1, x19
	SYS 31
	CHECK 4
	ldrsw x1, [sp, #132]
	SYS 4
	add x1, sp, #160
	mov x2, #64
	SYS 47
	CHECK 5
	ldr x2, [x19]
	mov x28, #6
	b die
okmsg:	.asciz "ok"
	.balign 4
