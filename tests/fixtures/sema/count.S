// A semaphore used as a lock keeps a shared counter exact: four RFMEM
// children each add 1000 to it, one at a time, yielding (sleep(0)) while
// they hold the semaphore, so the others contend and wait.

#include "lib.S"

	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x19, x0
	mov w2, #1
	str w2, [x19]
	mov x20, #4
1:	mov x1, #0x30           // rfork(RFPROC|RFMEM)
	SYS 19
	CHECK 1
	cbz x0, child
	subs x20, x20, #1
	b.ne 1b
	mov x20, #4
2:	add x1, sp, #128
	mov x2, #64
	SYS 47
	CHECK 2
	subs x20, x20, #1
	b.ne 2b
	ldr x2, [x19, #8]
	mov x3, #4000
	mov x28, #3
	cmp x2, x3
	b.ne die
	b ok
child:
	mov x21, #1000
3:	mov x1, x19
	mov x2, #1
	SYS 37
	CHECK 4
	ldr x22, [x19, #8]
	mov x1, #0
	SYS 17
	add x22, x22, #1
	str x22, [x19, #8]
	mov x1, x19
	mov x2, #1
	SYS 38
	CHECK 5
	subs x21, x21, #1
	b.ne 3b
	b ok
