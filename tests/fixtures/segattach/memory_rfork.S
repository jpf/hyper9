// A memory segment: an rfork(RFPROC) child's write isn't seen by the
// parent (step 3), and an rfork(RFPROC|RFMEM) child's is (step 6).

#include "lib.S"

	mov x1, #0
	adr x2, memory
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x19, x0
	mov x1, #0x10
	SYS 19
	CHECK 1
	cbnz x0, 1f
	mov x2, #1
	str x2, [x19]
	b ok
1:	add x1, sp, #128
	mov x2, #64
	SYS 47
	CHECK 2
	ldr x2, [x19]
	mov x28, #3
	cbnz x2, die
	mov x1, #0x30
	SYS 19
	CHECK 4
	cbnz x0, 2f
	mov x2, #2
	str x2, [x19]
	b ok
2:	add x1, sp, #128
	mov x2, #64
	SYS 47
	CHECK 5
	ldr x2, [x19]
	mov x28, #6
	cmp x2, #2
	b.ne die
	b ok
