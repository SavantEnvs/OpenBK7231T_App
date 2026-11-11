// Known-answer probes over the simulator, built with normal flags. mayhem/test.sh compares the exact
// lines this program prints with fixed expected values.
#include "new_common.h"
#include "new_pins.h"
#include "cmnds/cmd_public.h"
#include "httpserver/new_http.h"
#include "obk_harness.h"

uint32_t flash_read(char *user_buf, uint32_t count, uint32_t address);

static char g_in[4096];
static char g_out[65536];

static void http_get(const char *url)
{
	http_request_t request;
	snprintf(g_in, sizeof(g_in), "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", url);
	memset(&request, 0, sizeof(request));
	request.fd = 0;
	request.received = g_in;
	request.receivedLen = (int)strlen(g_in);
	request.receivedLenmax = request.receivedLen;
	request.responseCode = HTTP_RESPONSE_OK;
	g_out[0] = 0;
	request.reply = g_out;
	request.replymaxlen = sizeof(g_out) - 1;
	HTTP_ProcessPacket(&request);
	g_out[request.replylen] = 0;
}

static const char *http_body(void)
{
	const char *p = strstr(g_out, "\r\n\r\n");
	return p ? p + 4 : "(no body)";
}

/* FNV-1a over the simulator's whole 2 MB flash image */
static uint32_t flash_digest(void)
{
	static char chunk[4096];
	uint32_t h = 2166136261u;
	for (uint32_t addr = 0; addr < 2u * 1024 * 1024; addr += sizeof(chunk)) {
		flash_read(chunk, sizeof(chunk), addr);
		for (size_t i = 0; i < sizeof(chunk); i++)
			h = (h ^ (uint8_t)chunk[i]) * 16777619u;
	}
	return h;
}

/* what one input leaves behind: flash image + a few channels, after the same reset the harnesses use */
static uint32_t run_after_reset(const char *input)
{
	obk_harness_reset();
	CMD_ExecuteCommand(input, 0);
	Sim_RunFrames(5, false);
	return flash_digest() * 31u + (uint32_t)CHANNEL_Get(3);
}

int main(void)
{
	obk_harness_quiet();
	/* the simulator's log goes to the real stdout, the KAT lines go to stderr */
	SIM_StartOBK(0);

	SIM_ClearOBK(0);
	CMD_ExecuteCommand("setChannel 7 42", 0);
	fprintf(stderr, "KAT setChannel ch7=%d\n", CHANNEL_Get(7));

	CMD_ExecuteCommand("setChannel 8 $CH7*2+1", 0);
	fprintf(stderr, "KAT expression ch8=%d\n", CHANNEL_Get(8));

	CMD_ExecuteCommand("addChannel 8 -5", 0);
	fprintf(stderr, "KAT addChannel ch8=%d\n", CHANNEL_Get(8));

	SIM_ClearOBK(0);
	http_get("/cm?cmnd=setChannel%209%2013");
	fprintf(stderr, "KAT http-cmnd ch9=%d\n", CHANNEL_Get(9));

	fprintf(stderr, "KAT http-body=[%s]\n", http_body());
	http_get("/cm?cmnd=setChannel%209%2077");
	fprintf(stderr, "KAT http-cmnd2 ch9=%d\n", CHANNEL_Get(9));

	SIM_ClearOBK(0);
	SIM_UART_InitReceiveRingBuffer(2048);
	CMD_ExecuteCommand("startDriver TuyaMCU", 0);
	CMD_ExecuteCommand("linkTuyaMCUOutputToChannel 1 val 20", 0);
	CMD_ExecuteCommand("uartFakeHex 55AA03070008010200040000000119", 0);
	Sim_RunFrames(100, false);
	fprintf(stderr, "KAT tuyamcu dp1=%d\n", CHANNEL_Get(20));

	/* Flash must not carry over between inputs: dirty it, reset, expect the blank image again, and the
	   same input twice (with a different flash-dirtying input in between) must leave identical state. */
	obk_harness_reset();
	uint32_t blank = flash_digest();
	CMD_ExecuteCommand("lfs_format", 0);
	CMD_ExecuteCommand("lfs_append dirty.txt hello", 0);
	Sim_RunFrames(5, false);
	fprintf(stderr, "KAT flash-dirtied=%d\n", flash_digest() != blank);
	obk_harness_reset();
	fprintf(stderr, "KAT flash-reset-blank=%d\n", flash_digest() == blank);

	const char *same = "backlog setChannel 3 5; lfs_format; lfs_append same.txt abc";
	uint32_t first = run_after_reset(same);
	run_after_reset("backlog lfs_format; lfs_append other.txt zzzzzzzz");
	uint32_t second = run_after_reset(same);
	fprintf(stderr, "KAT flash-deterministic=%d\n", first == second);
	return 0;
}
