// A shared segment, then /proc/1/segment written to fd 1.

#include "lib.S"

	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	adr x1, procpath
	mov x2, #0
	SYS 14
	CHECK 1
	mov x20, x0
	mov x1, x20
	add x2, sp, #128
	mov x3, #256
	mov x4, #0
	SYS 50
	CHECK 2
	mov x3, x0
	mov x1, #1
	add x2, sp, #128
	mov x4, #-1
	SYS 51
	b ok
procpath:	.asciz "#p/1/segment"
	.balign 4
