// brk to 0x21800 maps headroom beyond the break; a memory segment at
// 0x22000, just above the break, still attaches, and the data survives.

#include "lib.S"

	LI x1, 0x21800
	SYS 24
	CHECK 0
	LI x20, 0x21000
	mov w2, #0x55
	strb w2, [x20]
	mov x1, #0
	adr x2, memory
	LI x3, 0x22000
	mov x4, #0x1000
	SYS 30
	CHECK 1
	LI x5, 0x22000
	mov x28, #2
	cmp x0, x5
	b.ne die
	str x5, [x5]
	ldrb w2, [x20]
	mov x28, #3
	cmp w2, #0x55
	b.ne die
	b ok
