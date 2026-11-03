/*
 * hp9's sandbox hooks for devfs (src/kern/fscheck.c). The operation
 * numbers match policy.Op in src/policy.zig.
 */
enum {
	HP9_FSWALK = 0,
	HP9_FSREAD = 1,
	HP9_FSWRITE = 2,
	HP9_FSCREATE = 3,
	HP9_FSREMOVE = 4,
	HP9_FSRENAME = 5,	/* the source of a rename */
};

#ifndef WINDOWS
/* Returns 0 if op on the host path is allowed, -1 if hidden, -2 if read-only. */
int	hp9_fs_check(char *path, int op);
/* Like hp9_fs_check, but raises "file does not exist" or "permission denied". */
void	hp9_fs_allow(char *path, int op);
#else
/* The same, for devfs-win32's paths. */
int	hp9_fs_checkw(wchar_t *path, int op);
void	hp9_fs_allow(wchar_t *path, int op);
#endif
