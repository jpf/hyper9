/*
 * #d: /fd/N opens a duplicate of fd N, and /fd/Nctl describes it. Ported
 * from 9front's port/devdup.c at the pinned release (NINEFRONT_REV), with
 * procfdprint from port/devproc.c, which drawterm declares but doesn't
 * define. drawterm's Fgrp is locked through its Ref.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

/* Qid is (2*fd + (file is ctl))+1 */

int
procfdprint(Chan *c, int fd, int w, char *s, int ns)
{
	USED(w);
	return snprint(s, ns, "%3d %.2s %C %4ld (%.16llux %lud %.2ux) %5ld %8lld %s\n",
		fd,
		&"r w rw"[(c->mode&3)<<1],
		devtab[c->type]->dc, c->dev,
		c->qid.path, c->qid.vers, c->qid.type,
		c->iounit, c->offset, chanpath(c));
}

static int
dupgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Fgrp *fgrp = up->fgrp;
	Chan *f;
	static int perm[] = { 0400, 0200, 0600, 0 };
	int p, maxfd;
	Qid q;

	USED(name, tab, ntab);
	if(s == DEVDOTDOT){
		devdir(c, c->qid, ".", 0, eve, 0555, dp);
		return 1;
	}
	if(s == 0)
		return 0;
	s--;
	lock(&fgrp->ref.lk);
	maxfd = fgrp->maxfd;
	f = s/2 <= maxfd ? fgrp->fd[s/2] : nil;
	p = f != nil ? perm[f->mode&3] : 0;
	unlock(&fgrp->ref.lk);
	if(s/2 > maxfd)
		return -1;
	if(f == nil)
		return 0;
	if(s & 1){
		p = 0400;
		sprint(up->genbuf, "%dctl", s/2);
	}else
		sprint(up->genbuf, "%d", s/2);
	mkqid(&q, s+1, 0, QTFILE);
	devdir(c, q, up->genbuf, 0, eve, p, dp);
	return 1;
}

static Chan*
dupattach(char *spec)
{
	return devattach('d', spec);
}

static Walkqid*
dupwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, (Dirtab *)0, 0, dupgen);
}

static int
dupstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, (Dirtab *)0, 0L, dupgen);
}

static Chan*
dupopen(Chan *c, int omode)
{
	Chan *f;
	int fd, twicefd;

	if(omode & ORCLOSE)
		error(Eperm);
	if(c->qid.type & QTDIR){
		if(omode != 0)
			error(Eisdir);
		c->mode = 0;
		c->flag |= COPEN;
		c->offset = 0;
		return c;
	}
	if(c->qid.type & QTAUTH)
		error(Eperm);
	twicefd = c->qid.path - 1;
	fd = twicefd/2;
	if((twicefd & 1)){
		/* ctl file */
		f = c;
		f->mode = openmode(omode);
		f->flag |= COPEN;
		f->offset = 0;
	}else{
		/* fd file */
		f = fdtochan(fd, openmode(omode), 0, 1);
		cclose(c);
	}
	return f;
}

static void
dupclose(Chan *c)
{
	USED(c);
}

static long
dupread(Chan *c, void *va, long n, vlong offset)
{
	char *a = va;
	char buf[256];
	int fd, twicefd;

	if(c->qid.type == QTDIR)
		return devdirread(c, a, n, (Dirtab *)0, 0L, dupgen);
	twicefd = c->qid.path - 1;
	fd = twicefd/2;
	if(twicefd & 1){
		c = fdtochan(fd, -1, 0, 1);
		procfdprint(c, fd, 0, buf, sizeof buf);
		cclose(c);
		return readstr((ulong)offset, va, n, buf);
	}
	panic("dupread");
	return 0;
}

static long
dupwrite(Chan *c, void *va, long n, vlong off)
{
	USED(c, va, n, off);
	error(Eperm);
	return 0;
}

Dev dupdevtab = {
	'd',
	"dup",

	devreset,
	devinit,
	devshutdown,
	dupattach,
	dupwalk,
	dupstat,
	dupopen,
	devcreate,
	dupclose,
	dupread,
	devbread,
	dupwrite,
	devbwrite,
	devremove,
	devwstat,
};
