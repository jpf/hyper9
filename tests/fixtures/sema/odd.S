// An odd semaphore address posts "sys: odd address", which kills the
// process: it has no handler.

#include "lib.S"

	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	add x1, x0, #2
	mov x2, #0
	SYS 37
	b ok
