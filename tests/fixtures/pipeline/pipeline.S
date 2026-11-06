// A pipeline like rc's `echo deep | cat | cat | ...`, arm64: the parent
// forks DEPTH stages, each connected to the next by a pipe. The first stage
// writes "deep\n"; every other stage copies its input to its output until
// EOF, as cat does. The parent copies the last pipe to fd 1, then waits for
// every stage. Most stages sit blocked reading a pipe while later ones are
// still being forked, which is the pattern that hangs on Windows x64.

#include "lib.S"

#ifndef DEPTH
#define DEPTH 80
#endif

	mov x20, #-1            // read end of the previous stage, -1 for none
	mov x21, #DEPTH
loop:
	add x1, sp, #64         // pipe(fd)
	SYS 21
	CHECK 0
	ldr w22, [sp, #64]      // read end
	ldr w23, [sp, #68]      // write end
	mov x1, #0x14           // rfork(RFPROC|RFFDG)
	SYS 19
	CHECK 1
	cbz x0, stage
	cmn x20, #1             // parent: keep only the new read end
	b.eq 1f
	mov x1, x20
	SYS 4
1:	mov x1, x23
	SYS 4
	mov x20, x22
	subs x21, x21, #1
	b.ne loop
	mov x23, #1             // the parent copies the last pipe to stdout
	b copy

stage:
	mov x1, x22
	SYS 4
	cmn x20, #1
	b.ne copy
	mov x1, x23             // the first stage: echo deep
	adr x2, deep
	mov x3, #5
	mov x4, #-1
	SYS 51
	CHECK 2
	b ok

copy:                           // copy x20 to x23 until EOF
	mov x1, x20
	add x2, sp, #128
	mov x3, #256
	mov x4, #-1
	SYS 50
	CHECK 3
	cbz x0, done
	mov x3, x0
	mov x1, x23
	add x2, sp, #128
	mov x4, #-1
	SYS 51
	CHECK 4
	b copy
done:
	cmp x23, #1
	b.ne ok
	mov x1, x20             // the parent: close, then reap every stage
	SYS 4
	mov x21, #DEPTH
reap:
	add x1, sp, #128
	mov x2, #256
	SYS 47
	CHECK 5
	subs x21, x21, #1
	b.ne reap
	b ok
deep:	.ascii "deep\n"
