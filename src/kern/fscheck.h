/*
 * h9's sandbox hooks for devfs (src/kern/fscheck.c). The operation
 * numbers match policy.Op in src/policy.zig.
 */
enum {
	H9_FSWALK = 0,
	H9_FSREAD = 1,
	H9_FSWRITE = 2,
	H9_FSCREATE = 3,
	H9_FSREMOVE = 4,
	H9_FSRENAME = 5,	/* the source of a rename */
};

#ifndef WINDOWS
/* Returns 0 if op on the host path is allowed, -1 if hidden, -2 if read-only. */
int	h9_fs_check(char *path, int op);
/* Like h9_fs_check, but raises "file does not exist" or "permission denied". */
void	h9_fs_allow(char *path, int op);
#else
/* The same, for devfs-win32's paths. */
int	h9_fs_checkw(wchar_t *path, int op);
void	h9_fs_allow(wchar_t *path, int op);
#endif
