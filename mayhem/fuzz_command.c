// libFuzzer harness: one command line -> CMD_ExecuteCommand (tokenizer, $CH expansion, expression
// evaluator, alias/backlog/if scripting and every registered console command).
#include "new_common.h"
#include "cmnds/cmd_public.h"
#include "obk_harness.h"

#define MAX_COMMAND 2048

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	(void)argc;
	(void)argv;
	obk_harness_quiet();
	SIM_StartOBK(0);
	return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	if (size < 1 || size > MAX_COMMAND)
		return -1;

	obk_harness_reset();

	char *cmd = (char *)malloc(size + 1);
	memcpy(cmd, data, size);
	cmd[size] = 0;

	CMD_ExecuteCommand(cmd, 0);
	Sim_RunFrames(5, false);

	free(cmd);
	return 0;
}
