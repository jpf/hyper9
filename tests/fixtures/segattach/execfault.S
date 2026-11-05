// A ret written into a memory segment and called: an exec fault, since
// segments are never executable.

#include "lib.S"

	mov x1, #0
	adr x2, memory
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x19, x0
	movz w2, #0x03c0
	movk w2, #0xd65f, lsl #16
	str w2, [x19]
	blr x19
	mov x28, #1
	b die
