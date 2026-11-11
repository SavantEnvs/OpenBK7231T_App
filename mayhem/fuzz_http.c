// libFuzzer harness: raw HTTP request bytes -> HTTP_ProcessPacket (the OpenBeken web server / REST API).
#include "new_common.h"
#include "httpserver/new_http.h"
#include "obk_harness.h"

#define MAX_REQUEST 8192
#define REPLY_BUFFER_SIZE 2048

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
	if (size < 4 || size > MAX_REQUEST)
		return -1;

	obk_harness_reset();

	/* same buffer layout as the real TCP server (new_tcp_server.c): +2 slack, NUL after the data */
	char *in = (char *)malloc(size + 2);
	char *reply = (char *)malloc(REPLY_BUFFER_SIZE);
	memcpy(in, data, size);
	in[size] = 0;
	in[size + 1] = 0;
	reply[0] = 0;

	http_request_t request;
	memset(&request, 0, sizeof(request));
	request.fd = 0;
	request.received = in;
	request.receivedLen = (int)size;
	request.receivedLenmax = (int)size;
	request.responseCode = HTTP_RESPONSE_OK;
	request.reply = reply;
	request.replylen = 0;
	request.replymaxlen = REPLY_BUFFER_SIZE - 1;

	HTTP_ProcessPacket(&request);

	free(in);
	free(reply);
	return 0;
}
