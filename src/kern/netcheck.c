/*
 * The C side of devip's sandbox hooks (src/kern/netcheck.h). The policy
 * itself, and the machine's resolved-name table, are in Zig.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "ip.h"
#include "devip.h"
#include "netcheck.h"

int
h9_net_proto(char *name)
{
	if(strcmp(name, "tcp") == 0)
		return S_TCP;
	if(strcmp(name, "udp") == 0)
		return S_UDP;
	return -1;
}
