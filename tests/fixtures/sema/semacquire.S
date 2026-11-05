// Semaphores in a shared segment. An RFMEM child releases after 100 ms
// while the parent waits in semacquire (step 2). Then: semacquire without
// block and tsemacquire with 0 ms fail at once on 0 (steps 4, 5),
// tsemacquire times out (6), semrelease returns the new value (7), and
// tsemacquire and semacquire take it down to 0 (8-10).

#include "lib.S"

	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x19, x0
	mov x1, #0x30           // rfork(RFPROC|RFMEM)
	SYS 19
	CHECK 1
	cbnz x0, 1f
	mov x1, #100
	SYS 17
	mov x1, x19
	mov x2, #1
	SYS 38
	b ok
1:	mov x1, x19
	mov x2, #1
	SYS 37
	mov x28, #2
	cmp x0, #1
	b.ne die
	add x1, sp, #128
	mov x2, #64
	SYS 47
	CHECK 3
	mov x1, x19
	mov x2, #0
	SYS 37
	mov x28, #4
	cbnz x0, die
	mov x1, x19
	mov x2, #0
	SYS 52
	mov x28, #5
	cbnz x0, die
	mov x1, x19
	mov x2, #50
	SYS 52
	mov x28, #6
	cbnz x0, die
	mov x1, x19
	mov x2, #2
	SYS 38
	mov x28, #7
	cmp x0, #2
	b.ne die
	mov x1, x19
	mov x2, #50
	SYS 52
	mov x28, #8
	cmp x0, #1
	b.ne die
	mov x1, x19
	mov x2, #0
	SYS 37
	mov x28, #9
	cmp x0, #1
	b.ne die
	ldr w2, [x19]
	mov x28, #10
	cbnz w2, die
	b ok
