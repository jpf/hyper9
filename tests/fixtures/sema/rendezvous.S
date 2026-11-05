// rendezvous swaps values: an rfork child and its parent meet on one tag.
// The child writes "c" once it has the parent's value, and the parent
// writes "p" once it has the child's and has waited for it.

#include "lib.S"

	mov x1, #0x10           // rfork(RFPROC)
	SYS 19
	CHECK 0
	cbnz x0, 1f
	mov x1, #0x99
	mov x2, #22
	SYS 34
	mov x28, #1
	cmp x0, #11
	b.ne die
	mov x1, #1
	adr x2, cmsg
	mov x3, #1
	mov x4, #-1
	SYS 51
	b ok
1:	mov x1, #0x99
	mov x2, #11
	SYS 34
	mov x28, #2
	cmp x0, #22
	b.ne die
	add x1, sp, #128
	mov x2, #64
	SYS 47
	CHECK 3
	mov x1, #1
	adr x2, pmsg
	mov x3, #1
	mov x4, #-1
	SYS 51
	b ok
cmsg:	.ascii "c"
pmsg:	.ascii "p"
	.balign 4
