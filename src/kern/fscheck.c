/*
 * The devfs side of the sandbox policy (DESIGN.md, "Vendor hooks" and
 * "Path resolution"). devfs-posix calls these before touching a host path.
 * Each host path is resolved (symlinks followed, as devfs's own stat and
 * open do) and the resolved path is checked against the calling machine's
 * policy through a Zig leaf, hp9_policy_check, which never raises errors.
 * Checking the resolved path keeps a symlink inside a bound tree from
 * reaching anything the policy doesn't allow.
 */

#ifdef WINDOWS
#include <windows.h>
#endif
#include "u.h"
#ifndef WINDOWS
#include <sys/stat.h>
#include <stdlib.h>
#include <limits.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#endif
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "fscheck.h"

/* Implemented in Zig (src/kern.zig): 0 allows, -1 hides, -2 is read-only. */
extern int hp9_policy_check(char *path, long len, int op);
extern int hp9_policy_active(void);

enum {
	Hidden = -1,
	Readonly = -2,
};

#ifndef WINDOWS

/*
 * The canonical path of an existing entry without following it if it's a
 * symlink, so a differently cased name on a case-insensitive file system
 * can't dodge a rule. Returns 0, or -1 if it doesn't exist.
 */
static int
canonical(char *path, char *buf)
{
	struct stat st;

	if(lstat(path, &st) < 0)
		return -1;
#ifdef __APPLE__
	{
		int fd;

		fd = open(path, O_EVTONLY|O_SYMLINK|O_CLOEXEC);
		if(fd < 0)
			return -1;
		if(fcntl(fd, F_GETPATH, buf) < 0){
			close(fd);
			return -1;
		}
		close(fd);
		return 0;
	}
#else
	/* Other hosts' file systems are case-sensitive, so the name stands. */
	if(!S_ISLNK(st.st_mode))
		return realpath(path, buf) == nil ? -1 : 0;
	return -1;
#endif
}

/*
 * Resolves path into buf. With nofollow, the last element itself isn't
 * followed (create, remove and rename act on a link, not its target): an
 * existing entry is canonicalised, and a new name is appended to its
 * resolved parent. Returns 0, or -1 if the path can't be resolved.
 */
static int
resolve(char *path, char *buf, int nofollow)
{
	char parent[PATH_MAX], *slash, *name;
	int n;

	if(!nofollow || strcmp(path, "/") == 0)
		return realpath(path, buf) == nil ? -1 : 0;
	if(canonical(path, buf) == 0)
		return 0;
	slash = strrchr(path, '/');
	if(slash == nil)
		return -1;
	name = slash+1;
	if(slash == path)
		strcpy(parent, "/");
	else{
		n = slash - path;
		if(n >= sizeof parent)
			return -1;
		memmove(parent, path, n);
		parent[n] = 0;
	}
	if(realpath(parent, buf) == nil)
		return -1;
	n = strlen(buf);
	if(n + 1 + strlen(name) + 1 > PATH_MAX)
		return -1;
	if(n > 0 && buf[n-1] != '/')
		buf[n++] = '/';
	strcpy(buf+n, name);
	return 0;
}

static int
check(char *path, int op, int nofollow)
{
	char buf[PATH_MAX];
	struct stat st;

	if(!hp9_policy_active())
		return 0;
	if(resolve(path, buf, nofollow) < 0)
		return Hidden;
	/*
	 * Creating over an existing symlink writes its target, and over a
	 * dangling one creates a file wherever it points.
	 */
	if(op == HP9_FSCREATE && lstat(buf, &st) == 0 && S_ISLNK(st.st_mode)){
		char target[PATH_MAX];

		if(realpath(buf, target) == nil)
			return Hidden;
		if(hp9_policy_check(target, strlen(target), HP9_FSWRITE) < 0)
			return Hidden;
	}
	return hp9_policy_check(buf, strlen(buf), op);
}

int
hp9_fs_check(char *path, int op)
{
	return check(path, op, op == HP9_FSCREATE || op == HP9_FSREMOVE || op == HP9_FSRENAME);
}

#else

/*
 * devfs-win32's paths are "", "C:" or "C:\a\b". Policy paths use the
 * guest's spelling of #U paths, "/C:/a/b". Resolution opens the path and
 * asks for its final name, which follows symlinks and junctions and
 * canonicalises case and short names.
 */
static int
finalflags(wchar_t *path, char *buf, int nbuf, DWORD flags)
{
	wchar_t w[MAX_PATH*4];
	HANDLE h;
	DWORD n;
	char *p;
	int i;

	h = CreateFileW(path, 0, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
		nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS|flags, nil);
	if(h == INVALID_HANDLE_VALUE)
		return -1;
	n = GetFinalPathNameByHandleW(h, w, nelem(w), FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
	CloseHandle(h);
	if(n == 0 || n >= nelem(w))
		return -1;
	/* Only drive paths, \\?\C:\..., are allowed; not UNC or devices. */
	if(wcsncmp(w, L"\\\\?\\", 4) != 0 || w[5] != L':')
		return -1;
	buf[0] = '/';
	if(WideCharToMultiByte(CP_UTF8, 0, w+4, -1, buf+1, nbuf-1, nil, nil) == 0)
		return -1;
	for(p = buf; *p; p++)
		if(*p == '\\')
			*p = '/';
	i = strlen(buf);
	if(i > 1 && buf[i-1] == '/')
		buf[i-1] = 0;
	return 0;
}

static int
final(wchar_t *path, char *buf, int nbuf)
{
	return finalflags(path, buf, nbuf, 0);
}

static int
checkw(wchar_t *path, int op, int nofollow)
{
	char buf[MAX_PATH*4*UTFmax], *name;
	wchar_t parent[MAX_PATH*4], *slash;
	int n, len;

	if(!hp9_policy_active())
		return 0;
	/* The list of drives, and the drives themselves, can be walked. */
	if(path[0] == 0 || (path[1] == L':' && path[2] == 0)){
		if(path[0] == 0)
			strcpy(buf, "/");
		else{
			buf[0] = '/';
			buf[1] = toupper(path[0]);
			buf[2] = ':';
			buf[3] = 0;
		}
		return hp9_policy_check(buf, strlen(buf), op);
	}
	if(!nofollow){
		if(final(path, buf, sizeof buf) < 0)
			return Hidden;
		return hp9_policy_check(buf, strlen(buf), op);
	}
	/*
	 * An existing entry is checked by its own canonical name (case, short
	 * names and trailing dots folded); creating over a link also writes
	 * its target.
	 */
	if(finalflags(path, buf, sizeof buf, FILE_FLAG_OPEN_REPARSE_POINT) == 0){
		char target[MAX_PATH*4*UTFmax];

		if(op == HP9_FSCREATE && final(path, target, sizeof target) == 0
		&& strcmp(target, buf) != 0 && hp9_policy_check(target, strlen(target), HP9_FSWRITE) < 0)
			return Hidden;
		return hp9_policy_check(buf, strlen(buf), op);
	}
	slash = wcsrchr(path, L'\\');
	if(slash == nil || slash-path >= nelem(parent))
		return Hidden;
	n = slash - path;
	memmove(parent, path, n*sizeof(wchar_t));
	parent[n] = 0;
	if(n == 2)
		wcscat(parent, L"\\");
	if(final(parent, buf, sizeof buf) < 0)
		return Hidden;
	len = strlen(buf);
	name = buf+len+1;
	if(WideCharToMultiByte(CP_UTF8, 0, slash+1, -1, name, sizeof buf - len - 1, nil, nil) == 0)
		return Hidden;
	buf[len] = '/';
	return hp9_policy_check(buf, strlen(buf), op);
}

int
hp9_fs_checkw(wchar_t *path, int op)
{
	return checkw(path, op, op == HP9_FSCREATE || op == HP9_FSREMOVE || op == HP9_FSRENAME);
}

void
hp9_fs_allow(wchar_t *path, int op)
{
	switch(hp9_fs_checkw(path, op)){
	case 0:
		return;
	case Readonly:
		error(Eperm);
	default:
		error(Enonexist);
	}
}

#endif

#ifndef WINDOWS
void
hp9_fs_allow(char *path, int op)
{
	switch(hp9_fs_check(path, op)){
	case 0:
		return;
	case Readonly:
		error(Eperm);
	default:
		error(Enonexist);
	}
}
#endif
