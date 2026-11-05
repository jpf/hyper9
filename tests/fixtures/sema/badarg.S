// Semaphore addresses and values 9front refuses with "bad arg in system
// call": a word in the text segment (step 0), a negative value (1), and a
// negative count (2), whose error the program exits with.

#include "lib.S"

	adr x1, _start
	mov x2, #0
	SYS 37
	mov x28, #0
	cmn x0, #1
	b.ne die
	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	mov x19, x0
	mov w2, #-1
	str w2, [x19]
	mov x1, x19
	mov x2, #0
	SYS 52
	mov x28, #1
	cmn x0, #1
	b.ne die
	str wzr, [x19]
	mov x1, x19
	mov x2, #-1
	SYS 38
	FAILS 2
