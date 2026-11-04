/*
 * memccpy for linux-musl builds. Zig 0.16's bundled musl memccpy
 * (lib/zig/c/string.zig) returns a pointer to the matching byte instead
 * of one past it, and never returns nil when there's no match, so
 * drawterm's strecpy and utfecpy leave strings unterminated. The build
 * defines memccpy as hp9_memccpy for kern and its libraries on musl, so
 * they call this standard one.
 */

#include <stddef.h>

void*
hp9_memccpy(void *dst, const void *src, int c, size_t n)
{
	unsigned char *d;
	const unsigned char *s;

	d = dst;
	s = src;
	while(n-- > 0)
		if((*d++ = *s++) == (unsigned char)c)
			return d;
	return NULL;
}
