/*
 * hp9's per-process records: what 9front keeps in its Proc and drawterm's
 * lacks (parent, children, wait queue, Egrp, the machine-local pid and a
 * pointer to the Zig process). kern/dat.h stays unmodified, so a record is
 * found from its Proc through a table here. See DESIGN.md, "Process model".
 *
 * Also here, ported from 9front at the pinned release: the group handling
 * of sysrfork (port/sysproc.c), pgrpcpy (port/pgrp.c), and pexit's and
 * pwait's wait records (port/proc.c).
 *
 * Records are reference counted: the table holds one for the process's
 * life, and each child holds one on its parent's record, so a child that
 * outlives its parent never touches freed memory. A parent that exits
 * marks its record dead, and children's exits then leave no wait record.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

enum
{
	RFNAMEG		= (1<<0),
	RFENVG		= (1<<1),
	RFFDG		= (1<<2),
	RFNOTEG		= (1<<3),
	RFPROC		= (1<<4),
	RFMEM		= (1<<5),
	RFNOWAIT	= (1<<6),
	RFCNAMEG	= (1<<10),
	RFCENVG		= (1<<11),
	RFCFDG		= (1<<12),
	RFREND		= (1<<13),
	RFNOMNT		= (1<<14),

	Maxwait		= 128,	/* wait records a parent keeps, as 9front */
	PROCHASH	= 64,
	TEXTLEN		= 64,
};

/* devenv.c */
extern void	*hp9_egrpnew(void);
extern void	*hp9_egrpcopy(void*);
extern void	hp9_egrpincref(void*);
extern void	hp9_egrpclose(void*);

typedef struct Hwait Hwait;
typedef struct Hproc Hproc;

struct Hwait
{
	Hwait	*next;
	ulong	pid;
	ulong	time[3];	/* user, sys, real, in ms */
	char	msg[ERRMAX];
};

struct Hproc
{
	Ref	ref;
	Proc	*p;
	Hproc	*hash;		/* table chain */

	ulong	pid;		/* machine-local */
	char	text[TEXTLEN];
	ulong	start;		/* ticks() at creation, for the real time */
	char	exitstr[ERRMAX];
	void	*egrp;		/* devenv.c's HEgrp */
	void	*aux;		/* the Zig process */

	Hproc	*parent;	/* nil with RFNOWAIT or for a machine's first process */
	Lock	exl;		/* guards the fields below */
	int	dead;		/* exited; children leave no wait records */
	int	nchild;
	int	nwait;
	Hwait	*waitq;
	QLock	qwaitr;		/* one waiter at a time */
	Rendez	waitr;
};

static Lock tablk;
static Hproc *table[PROCHASH];

static uint
prochash(Proc *p)
{
	return ((uintptr)p >> 4) % PROCHASH;
}

static Hproc*
lookup(Proc *p)
{
	Hproc *h;

	lock(&tablk);
	for(h = table[prochash(p)]; h != nil; h = h->hash)
		if(h->p == p)
			break;
	unlock(&tablk);
	return h;
}

static void
enter(Hproc *h)
{
	uint i;

	i = prochash(h->p);
	lock(&tablk);
	h->hash = table[i];
	table[i] = h;
	unlock(&tablk);
}

static void
leave(Hproc *h)
{
	Hproc **l;

	lock(&tablk);
	for(l = &table[prochash(h->p)]; *l != nil; l = &(*l)->hash)
		if(*l == h){
			*l = h->hash;
			break;
		}
	unlock(&tablk);
}

static void
putproc(Hproc *h)
{
	Hwait *w;

	if(h == nil || decref(&h->ref))
		return;
	while((w = h->waitq) != nil){
		h->waitq = w->next;
		free(w);
	}
	free(h);
}

static Hproc*
newhproc(Proc *p, char *text)
{
	Hproc *h;

	h = mallocz(sizeof *h, 1);
	if(h == nil)
		return nil;
	h->ref.ref = 1;
	h->p = p;
	h->start = ticks();
	strecpy(h->text, h->text+sizeof h->text, text);
	return h;
}

static Hproc*
uphproc(void)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil)
		error("not an hp9 process");
	return h;
}

/* The calling process's Egrp, for devenv; raises an error if it has none. */
void*
hp9_upegrp(void)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil || h->egrp == nil)
		error("no environment");
	return h->egrp;
}

/*
 * 9front's pgrpcpy: copies the mount table of from into to when flag has
 * RFNAMEG, and always the device mask.
 */
static void
pgrpcpy(Pgrp *to, Pgrp *from, int flag)
{
	Mount *n, *m, **link;
	Mhead *f, **l, *mh;
	int i;

	wlock(&to->ns);
	wlock(&from->ns);	/* must wlock to protect from->mntorder->norder */
	if(waserror()){
		wunlock(&from->ns);
		wunlock(&to->ns);
		nexterror();
	}

	memmove(to->devmask, from->devmask, sizeof from->devmask);

	if((flag & RFNAMEG) == 0)
		goto Done;

	for(i = 0; i < MNTHASH; i++){
		l = &to->mnthash[i];
		for(f = from->mnthash[i]; f != nil; f = f->hash){
			rlock(&f->lock);
			if(waserror()){
				runlock(&f->lock);
				nexterror();
			}
			mh = newmhead(f->from);
			*l = mh;
			l = &mh->hash;
			link = &mh->mount;
			for(m = f->mount; m != nil; m = m->next){
				n = newmount(m->to, m->mflag, m->spec);
				n->umh = mh;
				*link = n;
				link = &n->next;
				m->norder = n;	/* for the mntorder loop below */
			}
			runlock(&f->lock);
			poperror();
		}
	}
	/* add mounts in original mntorder */
	for(m = from->mntorder; m != nil; m = m->order){
		n = m->norder;
		m->norder = nil;
		pgrpinsert(to, n);
	}
Done:
	wunlock(&from->ns);
	wunlock(&to->ns);
	poperror();
}

/*
 * drawterm's closefgrp frees the fd table without closing its channels
 * (its kprocs never exit holding fds), so a pipe's write end would outlive
 * the last process holding it and its reader would never see EOF. This is
 * 9front's closefgrp. All Fgrp releases in this file go through it.
 */
static void
fgrpclose(Fgrp *f)
{
	int i;
	Chan *c;

	if(f == nil || decref(&f->ref))
		return;
	for(i = 0; i <= f->maxfd; i++)
		if((c = f->fd[i]) != nil){
			f->fd[i] = nil;
			cclose(c);
		}
	free(f->flag);
	free(f->fd);
	free(f);
}
#define closefgrp fgrpclose

/* Code using RFNOMNT expects to block all but these devices. */
static char nomntdevs[] = "|decp";

static void
checkflags(int flag)
{
	if((flag & (RFFDG|RFCFDG)) == (RFFDG|RFCFDG))
		error(Ebadarg);
	if((flag & (RFNAMEG|RFCNAMEG)) == (RFNAMEG|RFCNAMEG))
		error(Ebadarg);
	if((flag & (RFENVG|RFCENVG)) == (RFENVG|RFCENVG))
		error(Ebadarg);
}

/* Swaps the error strings after a caught error, as sysfile.c's wrappers do. */
static int
syserr(void)
{
	char *p;

	p = up->syserrstr;
	up->syserrstr = up->errstr;
	up->errstr = p;
	return -1;
}

typedef struct Spawn Spawn;
struct Spawn {
	void	(*fn)(void*);
	void	*arg;
};

static Proc *bootproc;

/* Called once the kernel is up, from the boot Proc (glue.c). */
void
hp9_proc_boot(void)
{
	bootproc = up;
}

void hp9_kern_exit(void);

static void
spawntramp(void *v)
{
	Spawn s;
	Hproc *h;

	s = *(Spawn*)v;
	free(v);
	/* Now that up is set, kernel calls (and their errors) are allowed. */
	if(waserror())
		panic("hp9_kern_spawn: %s", up->errstr);
	h = uphproc();
	up->slash = cclone(bootproc->slash);
	up->dot = cclone(bootproc->slash);
	up->pgrp = newpgrp();
	up->fgrp = dupfgrp(nil);
	up->rgrp = newrgrp();
	h->egrp = hp9_egrpnew();
	poperror();
	s.fn(s.arg);
	hp9_kern_exit();
}

/*
 * Runs fn(arg) on a new kernel process with its own thread, a fresh
 * namespace (just #/, as the boot Proc has), no fds, an empty environment
 * and its own rendezvous group; it has no parent. Unlike drawterm's kproc
 * it can be called from a thread that isn't a Proc: it only allocates
 * here, and the new thread sets up its groups once up is set. Returns 0,
 * or -1 if allocation fails.
 */
int
hp9_kern_spawn(char *name, void (*fn)(void*), void *arg)
{
	Proc *p;
	Spawn *s;
	Hproc *h;

	s = malloc(sizeof *s);
	if(s == nil)
		return -1;
	s->fn = fn;
	s->arg = arg;
	p = newproc();
	h = newhproc(p, name);
	if(h == nil){
		free(s);
		free(p);
		return -1;
	}
	p->fn = spawntramp;
	p->arg = s;
	strecpy(p->text, p->text+sizeof p->text, name);
	enter(h);
	osproc(p);
	return 0;
}

static void
forktramp(void *v)
{
	Spawn s;

	s = *(Spawn*)v;
	free(v);
	s.fn(s.arg);
	hp9_kern_exit();
}

/*
 * rfork with RFPROC: runs fn(arg) on a new kernel process that is a child
 * of the caller, with groups shared or copied from the caller's as flag
 * says (9front's sysrfork). pid is the child's machine-local pid. RFMEM
 * is the caller's business, and note groups (RFNOTEG) come in M4. Returns
 * 0, or -1 with the error string set; on error, fn never runs.
 */
int
hp9_kern_fork(int flag, ulong pid, void (*fn)(void*), void *arg)
{
	Proc *p;
	Hproc *h, *ph;
	Spawn *s;

	p = nil;
	h = nil;
	s = nil;
	if(waserror()){
		if(p != nil){
			if(p->fgrp != nil)
				closefgrp(p->fgrp);
			if(p->pgrp != nil)
				closepgrp(p->pgrp);
			if(p->rgrp != nil)
				closergrp(p->rgrp);
			if(p->dot != nil)
				cclose(p->dot);
			if(p->slash != nil)
				cclose(p->slash);
			free(p);
		}
		if(h != nil){
			if(h->egrp != nil)
				hp9_egrpclose(h->egrp);
			free(h);
		}
		free(s);
		return syserr();
	}
	if((flag & RFPROC) == 0)
		error(Ebadarg);
	checkflags(flag);
	ph = uphproc();

	s = malloc(sizeof *s);
	if(s == nil)
		error(Enomem);
	s->fn = fn;
	s->arg = arg;
	p = newproc();
	h = newhproc(p, ph->text);
	if(h == nil)
		error(Enomem);
	h->pid = pid;
	strecpy(p->text, p->text+sizeof p->text, up->text);

	p->slash = up->slash;
	incref(&p->slash->ref);
	p->dot = up->dot;
	incref(&p->dot->ref);

	/* File descriptors */
	if(flag & (RFFDG|RFCFDG)){
		if(flag & RFFDG)
			p->fgrp = dupfgrp(up->fgrp);
		else
			p->fgrp = dupfgrp(nil);
	} else {
		p->fgrp = up->fgrp;
		incref(&up->fgrp->ref);
	}

	/* Process groups */
	if(flag & (RFNAMEG|RFCNAMEG)){
		p->pgrp = newpgrp();
		pgrpcpy(p->pgrp, up->pgrp, flag);
	} else {
		p->pgrp = up->pgrp;
		incref(&up->pgrp->ref);
	}

	/* Rendezvous group */
	if(flag & RFREND)
		p->rgrp = newrgrp();
	else {
		p->rgrp = up->rgrp;
		incref(&up->rgrp->ref);
	}

	/* Environment group */
	if(flag & (RFENVG|RFCENVG)){
		if(flag & RFENVG)
			h->egrp = hp9_egrpcopy(ph->egrp);
		else
			h->egrp = hp9_egrpnew();
	} else {
		h->egrp = ph->egrp;
		hp9_egrpincref(ph->egrp);
	}
	poperror();

	if(flag & RFNOMNT)
		devmask(p->pgrp, 1, nomntdevs);

	if((flag & RFNOWAIT) == 0){
		incref(&ph->ref);
		h->parent = ph;
		lock(&ph->exl);
		ph->nchild++;
		unlock(&ph->exl);
	}

	p->fn = forktramp;
	p->arg = s;
	enter(h);
	osproc(p);
	return 0;
}

/*
 * rfork without RFPROC: changes the caller's own groups (9front's
 * sysrfork). Returns 0, or -1 with the error string set.
 */
int
hp9_kern_rfork(int flag)
{
	Fgrp *ofg;
	Pgrp *opg;
	Rgrp *org;
	void *oeg;
	Hproc *h;

	if(waserror())
		return syserr();
	checkflags(flag);
	if(flag & (RFPROC|RFMEM|RFNOWAIT))
		error(Ebadarg);
	h = uphproc();
	poperror();

	ofg = up->fgrp;
	opg = up->pgrp;
	org = up->rgrp;
	oeg = h->egrp;

	if(waserror()){
		if(up->fgrp != ofg){
			closefgrp(up->fgrp);
			up->fgrp = ofg;
		}
		if(up->pgrp != opg){
			closepgrp(up->pgrp);
			up->pgrp = opg;
		}
		if(up->rgrp != org){
			closergrp(up->rgrp);
			up->rgrp = org;
		}
		if(h->egrp != oeg){
			hp9_egrpclose(h->egrp);
			h->egrp = oeg;
		}
		return syserr();
	}

	/* File descriptors */
	if(flag & (RFFDG|RFCFDG)){
		if(flag & RFFDG)
			up->fgrp = dupfgrp(ofg);
		else
			up->fgrp = dupfgrp(nil);
	}

	/* Process group */
	if(flag & (RFNAMEG|RFCNAMEG)){
		up->pgrp = newpgrp();
		pgrpcpy(up->pgrp, opg, flag);
	}

	/* Rendezvous group */
	if(flag & RFREND)
		up->rgrp = newrgrp();

	/* Environment group */
	if(flag & (RFENVG|RFCENVG)){
		if(flag & RFENVG)
			h->egrp = hp9_egrpcopy(oeg);
		else
			h->egrp = hp9_egrpnew();
	}

	if(ofg != up->fgrp)
		closefgrp(ofg);
	if(opg != up->pgrp)
		closepgrp(opg);
	if(org != up->rgrp)
		closergrp(org);
	if(oeg != h->egrp)
		hp9_egrpclose(oeg);

	poperror();

	if(flag & RFNOMNT)
		devmask(up->pgrp, 1, nomntdevs);
	return 0;
}

/*
 * Ends the calling kernel process; it doesn't return. The parent, if any,
 * gets a wait record built from the exit string set with hp9_kern_setexits,
 * as 9front's pexit builds it.
 */
void
hp9_kern_exit(void)
{
	Hproc *h, *ph;
	Hwait *w;

	h = lookup(up);
	if(h == nil){
		pexit("", 1);
		return;
	}
	leave(h);

	ph = h->parent;
	if(ph != nil){
		w = mallocz(sizeof *w, 1);
		if(w != nil){
			w->pid = h->pid;
			w->time[2] = ticks() - h->start;
			if(h->exitstr[0])
				snprint(w->msg, sizeof w->msg, "%s %lud: %s", h->text, h->pid, h->exitstr);
		}
		lock(&ph->exl);
		if(!ph->dead){
			ph->nchild--;
			if(w != nil && ph->nwait < Maxwait){
				w->next = ph->waitq;
				ph->waitq = w;
				ph->nwait++;
				w = nil;
				wakeup(&ph->waitr);
			}
		}
		unlock(&ph->exl);
		free(w);
		h->parent = nil;
		putproc(ph);
	}

	/* Prevent my children from leaving waits. */
	lock(&h->exl);
	h->dead = 1;
	h->nchild = h->nwait = 0;
	while((w = h->waitq) != nil){
		h->waitq = w->next;
		free(w);
	}
	unlock(&h->exl);

	if(h->egrp != nil){
		hp9_egrpclose(h->egrp);
		h->egrp = nil;
	}
	putproc(h);
	/* drawterm's pexit would leak the fds' channels. */
	if(up->fgrp != nil){
		fgrpclose(up->fgrp);
		up->fgrp = nil;
	}
	pexit("", 1);
}

static int
haswaitq(void *x)
{
	return ((Hproc*)x)->waitq != nil;
}

/*
 * await: waits for a child to exit and formats its wait record into buf
 * as 9front's sysawait does ("pid utime stime real 'msg'"). Returns the
 * length, or -1 with the error string set: no children ("no living
 * children"), another await in progress, or interrupted.
 */
int
hp9_kern_await(char *buf, int n)
{
	Hproc *h;
	Hwait *w;
	int len;

	if(waserror())
		return syserr();
	h = uphproc();
	if(!canqlock(&h->qwaitr))
		error(Einuse);
	if(waserror()){
		qunlock(&h->qwaitr);
		nexterror();
	}
	lock(&h->exl);
	while(h->waitq == nil){
		if(h->nchild == 0){
			unlock(&h->exl);
			error(Enochild);
		}
		unlock(&h->exl);
		sleep(&h->waitr, haswaitq, h);
		lock(&h->exl);
	}
	w = h->waitq;
	h->waitq = w->next;
	h->nwait--;
	unlock(&h->exl);
	qunlock(&h->qwaitr);
	poperror();
	poperror();

	len = snprint(buf, n, "%lud %lud %lud %lud %q", w->pid, w->time[0], w->time[1], w->time[2], w->msg);
	free(w);
	return len;
}

/* The exit string the parent's wait record will carry; empty for success. */
void
hp9_kern_setexits(char *msg)
{
	Hproc *h;

	h = lookup(up);
	if(h != nil)
		strecpy(h->exitstr, h->exitstr+sizeof h->exitstr, msg);
}

/* The calling process's machine-local pid, and setting it. */
ulong
hp9_kern_gpid(void)
{
	Hproc *h;

	h = lookup(up);
	return h != nil ? h->pid : 0;
}

void
hp9_kern_setgpid(ulong pid)
{
	Hproc *h;

	h = lookup(up);
	if(h != nil)
		h->pid = pid;
}

/* The process's name in wait records; exec sets it to the program's. */
void
hp9_kern_settext(char *text)
{
	Hproc *h;

	h = lookup(up);
	if(h != nil)
		strecpy(h->text, h->text+sizeof h->text, text);
	strecpy(up->text, up->text+sizeof up->text, text);
}

/* The Zig process behind the calling kernel process. */
void*
hp9_kern_aux(void)
{
	Hproc *h;

	h = lookup(up);
	return h != nil ? h->aux : nil;
}

void
hp9_kern_setaux(void *aux)
{
	Hproc *h;

	h = lookup(up);
	if(h != nil)
		h->aux = aux;
}

extern int sysclose(int);

/* Closes the calling process's close-on-exec fds, as exec does. */
void
hp9_kern_closeexec(void)
{
	Fgrp *f;
	int i, cexec;

	f = up->fgrp;
	for(i = 0; ; i++){
		lock(&f->ref.lk);
		if(i > f->maxfd){
			unlock(&f->ref.lk);
			break;
		}
		cexec = f->fd[i] != nil && (f->flag[i] & CCEXEC) != 0;
		unlock(&f->ref.lk);
		if(cexec)
			sysclose(i);
	}
}

/*
 * Returns and clears the calling process's pending note flag. devpipe
 * posts a note (which drawterm reduces to this flag) on a write to a
 * closed pipe; hp9 turns that into the process's death, as 9front does
 * for a process with no note handler.
 */
int
hp9_kern_takenote(void)
{
	int n;

	n = up->notepending;
	up->notepending = 0;
	return n;
}
