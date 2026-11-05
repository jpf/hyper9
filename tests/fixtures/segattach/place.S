// segattach with va 0 goes just below the stack's 16 MiB (0x7fefef000 on
// arm64), then the next one below it; one at a taken va fails with
// "segments overlap".

#include "lib.S"

	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x19, x0
	LI x5, 0x7fefef000
	mov x28, #1
	cmp x19, x5
	b.ne die
	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 2
	LI x5, 0x7fefee000
	mov x28, #3
	cmp x0, x5
	b.ne die
	mov x1, #0
	adr x2, shared
	mov x3, x19
	mov x4, #0x1000
	SYS 30
	FAILS 4
