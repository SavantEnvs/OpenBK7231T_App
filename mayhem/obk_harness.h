#ifndef OBK_HARNESS_H
#define OBK_HARNESS_H
#include <stddef.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include "cmnds/cmd_local.h"

/* simulator entry points defined in src/win_main.c and src/sim/sim_uart.c */
void SIM_StartOBK(const char *flashPath);
void SIM_ClearOBK(const char *flashPath);
void SIM_ShutdownOBK(void);
void Sim_RunFrames(int n, bool bApplyRealtimeWait);
void SIM_UART_InitReceiveRingBuffer(int size);
void SIM_AppendUARTByte(unsigned char rc);
/* src/win32/stubs/win_flash_stub.c: frees and re-zeroes the simulator's 2 MB flash image */
void SIM_SetupEmptyFlashModeNoFile(void);

/* The simulator logs every action to stdout and the HTTP upload handlers recv() from request->fd (0 in
   the simulator's fake-packet mode): point both at /dev/null so the harness never blocks or floods. */
static void obk_harness_quiet(void)
{
	int fd = open("/dev/null", O_RDWR);
	if (fd >= 0) {
		dup2(fd, 0);
		dup2(fd, 1);
		if (fd > 2)
			close(fd);
	}
}

/* Deliberate-crash and simulator-control commands are not firmware behaviour: crashNull writes through a
   NULL pointer in a loop and stackOverflow recurses without bound (src/cmnds/cmd_test.c, self-test
   commands), ExitSimulator calls exit(0) (src/cmnds/cmd_simulatorOnly.c, simulator front-end control).
   The rest of the input still runs; only their handlers are replaced, in the command table, so aliases,
   backlog, prefixes and the HTTP /cm endpoint all reach the replacement. */
static commandResult_t obk_harness_noop_command(const void *context, const char *cmd, const char *args, int cmdFlags)
{
	(void)context;
	(void)cmd;
	(void)args;
	(void)cmdFlags;
	return CMD_RES_OK;
}

static void obk_harness_disarm_commands(void)
{
	static const char *const names[] = { "crashNull", "stackOverflow", "ExitSimulator" };
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		command_t *c = CMD_Find(names[i]);
		if (c)
			c->handler = obk_harness_noop_command;
	}
}

/* Per-input reset. SIM_StartOBK(NULL) skips reading a flash file, so the static g_flash image (saved
   config, LFS files, OTA/TuyaMCU writes) would survive SIM_ClearOBK into the next input. Shut down first
   (it may still write flash), re-zero the image, then boot from blank flash. */
static void obk_harness_reset(void)
{
	SIM_ShutdownOBK();
	SIM_SetupEmptyFlashModeNoFile();
	SIM_StartOBK(0);
	obk_harness_disarm_commands();
}
#endif
