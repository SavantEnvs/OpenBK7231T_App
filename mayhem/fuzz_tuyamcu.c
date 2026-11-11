// libFuzzer harness: bytes arriving on the UART from a Tuya MCU -> TuyaMCU packet framing and parsing.
// Byte 0 picks the driver configuration, the rest is the UART stream.
#include "new_common.h"
#include "cmnds/cmd_public.h"
#include "obk_harness.h"

#define MAX_STREAM 1500

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
	if (size < 8 || size > MAX_STREAM)
		return -1;

	uint8_t mode = data[0];
	data++;
	size--;

	obk_harness_reset();
	SIM_UART_InitReceiveRingBuffer(2048);
	CMD_ExecuteCommand("startDriver TuyaMCU", 0);
	if (mode & 1)
		CMD_ExecuteCommand("tuyaMcu_batteryPoweredMode 1", 0);
	if (mode & 2)
		CMD_ExecuteCommand("tuyaMcu_defWiFiState 4", 0);
	CMD_ExecuteCommand("linkTuyaMCUOutputToChannel 1 bool 1", 0);
	CMD_ExecuteCommand("linkTuyaMCUOutputToChannel 2 val 2", 0);
	CMD_ExecuteCommand("linkTuyaMCUOutputToChannel 3 enum 3", 0);
	CMD_ExecuteCommand("linkTuyaMCUOutputToChannel 4 str 4", 0);
	CMD_ExecuteCommand("linkTuyaMCUOutputToChannel 5 raw 5", 0);

	for (size_t i = 0; i < size; i++)
		SIM_AppendUARTByte(data[i]);
	Sim_RunFrames(10, false);
	return 0;
}
