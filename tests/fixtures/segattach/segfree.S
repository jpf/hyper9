// segfree of a memory segment's first page zeroes it, and leaves the
// second alone.

#include "lib.S"

	mov x1, #0
	adr x2, memory
	mov x3, #0
	mov x4, #0x2000
	SYS 30
	CHECK 0
	mov x19, x0
	add x20, x19, #0x1000
	mov w2, #7
	strb w2, [x19, #8]
	strb w2, [x20]
	mov x1, x19
	mov x2, #0x1000
	SYS 32
	CHECK 1
	ldrb w2, [x19, #8]
	mov x28, #2
	cbnz w2, die
	ldrb w2, [x20]
	mov x28, #3
	cmp w2, #7
	b.ne die
	b ok
