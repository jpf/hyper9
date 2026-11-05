// A note interrupts rendezvous and semacquire, and the handler runs. With
// a handler that continues, the child waits in rendezvous and the parent
// in semacquire until the timeout's hangup: the child's rendezvous returns
// ~0 and it leaves an "r" in the segment, and the parent's semacquire
// fails; after waiting for the child, the parent writes the "r" and the
// error string ("interrupted"). The handler writes "h" each time it runs.

#include "lib.S"

	adr x1, handler
	SYS 28
	CHECK 0
	mov x1, #0
	adr x2, shared
	mov x3, #0
	mov x4, #0x1000
	SYS 30
	CHECK 1
	mov x19, x0
	mov x1, #0x10           // rfork(RFPROC)
	SYS 19
	CHECK 2
	cbnz x0, 1f
	mov x1, #0x77
	mov x2, #1
	SYS 34
	mov x28, #3
	cmn x0, #1
	b.ne die
	mov w2, #'r'
	strb w2, [x19, #32]
	b ok
1:	mov x1, x19
	mov x2, #1
	SYS 37
	mov x28, #4
	cmn x0, #1
	b.ne die
	add x1, sp, #256
	mov x2, #64
	SYS 41
	add x1, sp, #128
	mov x2, #64
	SYS 47
	CHECK 5
	mov x1, #1
	add x2, x19, #32
	mov x3, #1
	mov x4, #-1
	SYS 51
	mov x1, #1
	add x2, sp, #256
	mov x3, #11
	mov x4, #-1
	SYS 51
	b ok
handler:                        // handler(ureg, msg): write "h", noted(NCONT)
	sub sp, sp, #64
	mov x1, #1
	adr x2, hmsg
	mov x3, #1
	mov x4, #-1
	SYS 51
	mov x1, #0
	SYS 29
hmsg:	.ascii "h"
	.balign 4
