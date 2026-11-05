// An unmapped semaphore address is a bad address in a syscall.

#include "lib.S"

	mov x1, #0x1000
	mov x2, #1
	SYS 38
	b ok
