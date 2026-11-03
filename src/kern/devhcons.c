/*
 * #y: a machine's console. drawterm's #c/cons reads and writes the host
 * process's fds 0 and 1; this device serves each machine's Stdio instead,
 * through leaf calls into Zig (DESIGN.md, seam rule 3). The namespace
 * builder binds it over /dev, so /dev/cons is this device and the rest of
 * #c stays visible.
 *
 * The attach spec names the machine: #y<id>. The leaves never raise kernel
 * errors; they return -1 and this file raises the error.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

/* Implemented in Zig (src/kern.zig). */
extern long hp9_cons_read(ulong machine, void *buf, long n);
extern long hp9_cons_write(ulong machine, int fd, void *buf, long n);

enum {
	Qdir,
	Qcons,
	Qconsctl,
	Qstderr,	/* hp9 extension: writes go to the host stderr */
};

static Dirtab hconsdir[] = {
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"cons",		{Qcons},		0,	0660,
	"consctl",	{Qconsctl},		0,	0220,
	"stderr",	{Qstderr},		0,	0220,
};

static Chan*
hconsattach(char *spec)
{
	Chan *c;
	char *e;
	ulong id;

	id = strtoul(spec, &e, 10);
	if(*spec == 0 || *e != 0)
		error(Ebadspec);
	c = devattach('y', spec);
	c->dev = id;
	return c;
}

static Walkqid*
hconswalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, hconsdir, nelem(hconsdir), devgen);
}

static int
hconsstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, hconsdir, nelem(hconsdir), devgen);
}

static Chan*
hconsopen(Chan *c, int omode)
{
	return devopen(c, omode, hconsdir, nelem(hconsdir), devgen);
}

static void
hconsclose(Chan *c)
{
	USED(c);
}

static long
hconsread(Chan *c, void *va, long n, vlong off)
{
	long r;

	USED(off);
	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, va, n, hconsdir, nelem(hconsdir), devgen);
	case Qcons:
		r = hp9_cons_read(c->dev, va, n);
		if(r < 0)
			error(Eio);
		return r;
	}
	error(Egreg);
	return -1;
}

static long
hconswrite(Chan *c, void *va, long n, vlong off)
{
	long r;

	USED(off);
	switch((ulong)c->qid.path){
	case Qcons:
	case Qstderr:
		r = hp9_cons_write(c->dev, c->qid.path == Qcons ? 1 : 2, va, n);
		if(r < 0)
			error(Eio);
		return r;
	case Qconsctl:
		/* rawon/rawoff and the TTY come with the interactive console. */
		return n;
	}
	error(Egreg);
	return -1;
}

Dev hconsdevtab = {
	'y',
	"hcons",

	devreset,
	devinit,
	devshutdown,
	hconsattach,
	hconswalk,
	hconsstat,
	hconsopen,
	devcreate,
	hconsclose,
	hconsread,
	devbread,
	hconswrite,
	devbwrite,
	devremove,
	devwstat,
};
