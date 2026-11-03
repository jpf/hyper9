/*
 * hp9's replacement for drawterm's main.c, cpu.c and GUI backend: boots
 * drawterm's kern without a window or a cpu connection. See DESIGN.md,
 * "Kernel: drawterm kern/ and the Zig seam".
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "user.h"

#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"

#include <pwd.h>

char *argv0;
extern ulong kerndate;

/* No GUI until --gfx (M7): devdraw, devmouse and snarf see no screen. */
Memimage *gscreen;
void screeninit(void) {}
void screensize(Rectangle r, ulong chan) { USED(r, chan); }
Memdata *attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen) { return nil; }
void flushmemscreen(Rectangle r) { USED(r); }
void getcolor(ulong i, ulong *r, ulong *g, ulong *b) { *r = *g = *b = 0; }
void setcolor(ulong i, ulong r, ulong g, ulong b) { USED(i, r, g, b); }
void setcursor(void) {}
void mouseset(Point p) { USED(p); }
char *clipread(void) { return nil; }
int clipwrite(char *s) { USED(s); return 0; }

/* Compose sequences only matter for GUI keyboard input. */
long latin1(Rune *k, int n) { USED(k, n); return -1; }

/* devtls's factotum path; there's no factotum until M5. */
void *auth_allocrpc(int afd) { USED(afd); werrstr("no factotum"); return nil; }
void auth_freerpc(void *rpc) { USED(rpc); }
int auth_rpc(void *rpc, char *verb, void *a, int n) { USED(rpc, verb, a, n); return -1; }

static char*
hostuser(void)
{
	static char user[64];
	struct passwd *pw;

	pw = getpwuid(getuid());
	if(pw == nil)
		return "none";
	strecpy(user, user+sizeof user, pw->pw_name);
	return user;
}

/*
 * Boots the kernel. The calling thread becomes the kernel's first Proc for
 * good, so callers use a private thread (src/kern.zig). Machines' processes
 * are made later with hp9_kern_spawn. Returns 0, or -1 with the error
 * string set.
 */
static Proc *bootproc;
void hp9_kern_exit(void);
extern int hp9_newegrp(void);
extern void hp9_closeegrp(void);

int
hp9_kern_boot(void)
{
	kerndate = seconds();
	eve = hostuser();

	osinit();
	procinit0();
	printinit();
	chandevreset();
	chandevinit();
	/* After chandevinit: devip sets sysname to the host name. */
	kstrdup(&sysname, "hp9");
	quotefmtinstall();
	bootproc = up;
	return 0;
}

/* Parks the boot thread for good once the kernel is up. */
void
hp9_kern_park(void)
{
	for(;;)
		procsleep();
}

typedef struct Spawn Spawn;
struct Spawn {
	void	(*fn)(void*);
	void	*arg;
};

static void
spawntramp(void *v)
{
	Spawn s;

	s = *(Spawn*)v;
	free(v);
	/* Now that up is set, kernel calls (and their errors) are allowed. */
	up->slash = cclone(bootproc->slash);
	up->dot = cclone(bootproc->slash);
	up->pgrp = newpgrp();
	up->fgrp = dupfgrp(nil);
	up->rgrp = newrgrp();
	if(hp9_newegrp() < 0)
		panic("hp9_newegrp");
	s.fn(s.arg);
	hp9_kern_exit();
}

/*
 * Runs fn(arg) on a new kernel process with its own thread, a fresh
 * namespace (just #/, as the boot Proc has), no fds and its own rendezvous
 * group. Unlike drawterm's kproc it can be called from a thread that isn't
 * a Proc: it only allocates here, and the new thread sets up its groups
 * once up is set. Returns 0, or -1 if allocation fails.
 */
int
hp9_kern_spawn(char *name, void (*fn)(void*), void *arg)
{
	Proc *p;
	Spawn *s;

	s = malloc(sizeof *s);
	if(s == nil)
		return -1;
	s->fn = fn;
	s->arg = arg;
	p = newproc();
	p->fn = spawntramp;
	p->arg = s;
	strecpy(p->text, p->text+sizeof p->text, name);
	osproc(p);
	return 0;
}

/* Ends the calling kernel process; it doesn't return. */
void
hp9_kern_exit(void)
{
	hp9_closeegrp();
	pexit("", 1);
}

/* The host user, which is hostowner. */
char*
hp9_kern_user(void)
{
	return eve;
}

/* The calling Proc's pid. */
ulong
hp9_kern_pid(void)
{
	return up->pid;
}

/* Masks the devices whose letters are in devs from future attaches. */
void
hp9_kern_devmask(char *devs)
{
	devmask(up->pgrp, 0, devs);
}

/* The current Proc's error string, for the Zig side. */
char*
hp9_kern_errstr(void)
{
	return up->nerrlab ? up->errstr : up->syserrstr;
}

/*
 * fd2path: drawterm's _sysfd2path passes an uninitialised
 * length and has no sys* wrapper.
 */
int
hp9_fd2path(int fd, char *buf, uint nbuf)
{
	Chan *c;

	if(waserror()){
		char *p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	c = fdtochan(fd, -1, 0, 1);
	snprint(buf, nbuf, "%s", chanpath(c));
	cclose(c);
	poperror();
	return 0;
}
