// Five segments attach; the sixth fails with "virtual memory allocation
// failed".

#include "lib.S"

	mov x21, #5
1:	mov x1, #0
	adr x2, memory
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	subs x21, x21, #1
	b.ne 1b
	mov x1, #0
	adr x2, memory
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	FAILS 1
