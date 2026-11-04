/*
 * The Windows parts of glue.c, kept apart because <windows.h> clashes
 * with drawterm's draw.h.
 */
#include <windows.h>
#include "u.h"
#include "lib.h"

/* The host user, which is hostowner. */
char*
h9_hostuser(void)
{
	static char user[64];
	wchar_t w[64];
	DWORD n;

	n = nelem(w);
	if(!GetUserNameW(w, &n) || WideCharToMultiByte(CP_UTF8, 0, w, -1, user, sizeof user, nil, nil) == 0)
		return "none";
	return user;
}

/*
 * win32.c's WinMain calls drawterm's main, which dtos.h renames mymain.
 * h9 has its own entry point, so it's never called.
 */
int mymain(int argc, char **argv) { USED(argc); USED(argv); return 0; }
