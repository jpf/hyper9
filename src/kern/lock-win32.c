/*
 * Lock for Windows hosts, built in place of drawterm's libc/lock.c.
 *
 * POSIX hosts build kern with -DPTHREAD, which makes Lock a pthread mutex.
 * Windows has no pthreads, so lock.c falls back to a test-and-set
 * spinlock whose unlock is a plain store, `lk->key = 0`, with no release
 * ordering. On arm64, and on x64 code under Prism (which doesn't keep x86
 * store ordering for plain stores by default), another thread could take
 * the lock before it saw the writes made under it. That corrupted QLock
 * queues and Rendez state, and left processes asleep in procsleep with
 * nobody to wake them: the "more live processes than HVF has vCPUs" hang.
 *
 * Lock's layout comes from drawterm's lib.h (an int key without PTHREAD),
 * so this is a futex-style mutex on that int: 0 free, 1 held, 2 held with
 * waiters. Every access is an Interlocked operation, a full barrier on
 * both architectures (a locked instruction on x64, which Prism honours),
 * and waiters block in WaitOnAddress instead of lock.c's sleep loop.
 */
#include <windows.h>
#include "u.h"
#include "lib.h"

enum {
	Free,
	Held,
	Contended,
	Spins = 100,
};

int
canlock(Lock *lk)
{
	return InterlockedCompareExchange((LONG volatile*)&lk->key, Held, Free) == Free;
}

void
lock(Lock *lk)
{
	LONG contended;
	int i;

	for(i = 0; i < Spins; i++){
		if(canlock(lk))
			return;
		YieldProcessor();
	}
	/*
	 * Mark it contended as we take it, so whoever holds it now wakes a
	 * waiter on unlock. Taking it this way leaves it contended even if
	 * nobody else is waiting, which only costs a spurious wake.
	 */
	contended = Contended;
	while(InterlockedExchange((LONG volatile*)&lk->key, Contended) != Free)
		WaitOnAddress(&lk->key, &contended, sizeof lk->key, INFINITE);
}

void
unlock(Lock *lk)
{
	LONG v;

	v = InterlockedExchange((LONG volatile*)&lk->key, Free);
	assert(v != Free);
	if(v == Contended)
		WakeByAddressSingle(&lk->key);
}

void
ilock(Lock *lk)
{
	lock(lk);
}

void
iunlock(Lock *lk)
{
	unlock(lk);
}
