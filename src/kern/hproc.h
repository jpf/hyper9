/*
 * hp9's per-process records (proc.c), shared with devproc.c. See proc.c.
 */

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
	ARGSLEN		= 128,	/* args kept for /proc, as 9front's exec */
	NNOTE		= 5,	/* queued notes, as 9front */
};

/* hp9_kern_popnote's results. */
enum
{
	Nnone,		/* no note to act on */
	Nhandle,	/* enter the handler with the note */
	Nkill,		/* die with the note as the exit status */
	Nkilldebug,	/* the same, and print "suicide: note" first */
};

/* devenv.c */
extern void	*hp9_egrpnew(void);
extern void	*hp9_egrpcopy(void*);
extern void	hp9_egrpincref(void*);
extern void	hp9_egrpclose(void*);

typedef struct Hwait Hwait;
typedef struct Hproc Hproc;
typedef struct Hmach Hmach;
typedef struct Hnote Hnote;

/* A machine: the processes descended from one hp9_kern_spawn. */
struct Hmach
{
	Ref	ref;		/* one per record */
	Lock	lk;
	ulong	nextnoteid;
};

/* 9front's Note. One note posted to a group is shared by its queues. */
struct Hnote
{
	Ref	ref;
	int	flag;		/* NUser, NExit or NDebug */
	char	msg[ERRMAX];
};

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
	ulong	ppid;		/* the parent's pid when created, for /proc/n/ppid */
	Lock	alk;		/* guards args, nargs and setargs */
	char	args[ARGSLEN];	/* exec's argv, NUL-separated, as 9front's p->args */
	int	nargs;
	int	setargs;	/* args was written through /proc */
	int	hang;		/* ctl hang: stop at exec (kept, not acted on) */
	int	killed;		/* ctl kill: die with "Killed" at the next delivery; under nlk */
	char	exitstr[ERRMAX];
	void	*egrp;		/* devenv.c's HEgrp */
	void	*aux;		/* the Zig process */
	Hmach	*mach;
	QLock	debug;		/* held to swap or drop p's fgrp, pgrp and dot, and to read them from devproc */

	Lock	nlk;		/* guards the note fields below */
	ulong	noteid;
	int	notify;		/* has a note handler */
	int	notified;	/* in the handler */
	int	nnote;
	Hnote	*note[NNOTE];
	Hnote	*lastnote;	/* the note being handled, or that killed it */

	Hproc	*parent;	/* nil with RFNOWAIT or for a machine's first process */
	Lock	exl;		/* guards the fields below */
	int	dead;		/* exited; children leave no wait records */
	int	nchild;
	int	nwait;
	Hwait	*waitq;
	QLock	qwaitr;		/* one waiter at a time */
	Rendez	waitr;
};


/* proc.c, for devproc.c. Lookups take a reference; release it with hp9_putproc. */
Hproc*	hp9_uphproc(void);
Hproc*	hp9_pidlookup(Hmach*, ulong);
void	hp9_putproc(Hproc*);
Hnote*	hp9_mknote(char*, int);
void	hp9_freenote(Hnote*);
int	hp9_pushnote(Hproc*, Hnote*);
void	hp9_postnotepg(Hmach*, ulong, char*, int);
int	hp9_setnoteid(Hproc*, ulong);
void	hp9_killproc(Hproc*);
void	hp9_fgrpclose(Fgrp*);
int	hp9_pids(Hmach*, ulong*, int);

/*
 * Set by the Zig side: the state (a syscall's name, "Running"...) and the
 * mapped memory in KiB of Zig process aux. Called with the record's nlk
 * held, and only while its aux is set.
 */
extern void	(*hp9_procstatus)(void*, char*, int, ulong*);
