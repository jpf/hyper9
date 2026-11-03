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
 * Boots the kernel. The calling thread becomes the first Proc, with the
 * host directory root as its / and the host directory cwd (if not nil) at
 * /mnt/term as its dot. Returns 0, or -1 with the error string set.
 */
int
hp9_kern_boot(char *root, char *cwd)
{
	char buf[1024];

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

	snprint(buf, sizeof buf, "#U%s", root);
	if(bind(buf, "/", MREPL) < 0)
		return -1;
	if(bind("#c", "/dev", MREPL) < 0)
		return -1;
	if(bind("#e", "/env", MREPL|MCREATE) < 0)
		return -1;
	if(bind("#I", "/net", MREPL) < 0)
		return -1;
	if(cwd != nil){
		snprint(buf, sizeof buf, "#U%s", cwd);
		if(bind(buf, "/mnt/term", MREPL) < 0)
			return -1;
		if(chdir("/mnt/term") < 0)
			return -1;
	}
	return 0;
}

/* The current Proc's error string, for the Zig side. */
char*
hp9_kern_errstr(void)
{
	return up->nerrlab ? up->errstr : up->syserrstr;
}
