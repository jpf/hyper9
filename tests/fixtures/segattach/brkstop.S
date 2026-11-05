// A memory segment at 0x40000: brk can reach just below it, and brk past
// its base fails with "segments overlap".

#include "lib.S"

	mov x1, #0
	adr x2, memory
	LI x3, 0x40000
	mov x4, #0x1000
	SYS 30
	CHECK 0
	LI x1, 0x3f800
	SYS 24
	CHECK 1
	LI x5, 0x3f000
	str x5, [x5]
	LI x1, 0x40800
	SYS 24
	FAILS 2
