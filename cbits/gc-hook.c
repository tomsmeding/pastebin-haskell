#include "Rts.h"
#include <string.h>
#include <time.h>
#include <arpa/inet.h>
#include <errno.h>
#include <unistd.h>

// needs C11
#include <threads.h>

extern RtsConfig rtsConfig;

// --------
// GLOBAL VARIABLES
// --------

static bool constructor_worked = false;
static bool hook_initialised = false;
static struct timespec app_init_time;

static mtx_t state_mutex;
static int log_sink_sock = -1;

static void (*old_hook)(const struct GCDetails_ *details) = NULL;

// --------
// END OF GLOBAL VARIABLES
// --------

static void hook_callback(const struct GCDetails_ *details) {
	static bool fatal_failure = false;

	if (fatal_failure) goto cleanup_no_mutex;

	// Do this now already, before waiting on the mutex
	struct timespec now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
		perror("clock_gettime");
		fatal_failure = true;
		goto cleanup_no_mutex;
	}

	if (mtx_lock(&state_mutex) != thrd_success) {
		fprintf(stderr, "gc-hook: ERROR: Mutex lock failed\n");
		fatal_failure = true;
		goto cleanup_no_mutex;
	}

	// mutex is locked from here

	// A 64-bit integer is at most 2^64 plus a negative sign.
	// 1 + log10(2^64) = 1 + 64 * log10(2) <= 21
	// There are 14 fields, so with
	// - header of length 3
	// - (!!!) some chars for the now timestamp
	// - 14 * 21 = 294 chars for data
	// - 13 spaces
	// - newline
	// we need 3 + 294 + 13 + 1 = 311 characters.
	char buffer[512];
	int nwr = snprintf(
			buffer, sizeof buffer,
			"GC %lf %u %u %lu %lu %lu %lu %lu %lu %lu %lu %lu %ld %ld %ld\n",
			now.tv_sec + now.tv_nsec / 1.0e9,
			details->gen, details->threads, details->allocated_bytes,
			details->live_bytes, details->large_objects_bytes, details->compact_bytes,
			details->slop_bytes, details->mem_in_use_bytes, details->copied_bytes,
			details->par_max_copied_bytes, details->par_balanced_copied_bytes, details->sync_elapsed_ns,
			details->cpu_ns, details->elapsed_ns);
	if (nwr >= 512) { printf("wat\n"); exit(1); }

	size_t cursor = 0;
	while (cursor < nwr) {
		ssize_t nsent = write(log_sink_sock, buffer + cursor, nwr - cursor);
		if (nsent < 0 && errno == EINTR) continue;
		if (nsent <= 0) break;
		cursor += nsent;
	}

// cleanup:
	mtx_unlock(&state_mutex);  // ignore return value

cleanup_no_mutex:
	if (old_hook) old_hook(details);
}

__attribute__((constructor))
static void constructor(void) {
	if (mtx_init(&state_mutex, mtx_plain) != thrd_success) {
		fprintf(stderr, "gc-hook: ERROR: Mutex initialisation failed\n");
		return;
	}

	constructor_worked = true;
}

static bool connect_log_sink(void) {
	int sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (sock < 0) { perror("socket"); return false; }

	struct sockaddr_in saddr;
	saddr.sin_family = AF_INET;
	saddr.sin_port = htons(8131);
	saddr.sin_addr.s_addr = htonl((127U << 24) | (0 << 16) | (0 << 8) | (1 << 0));

	int ret = connect(sock, &saddr, sizeof saddr);
	if (ret < 0) { perror("connect to 127.0.0.1:8131 for logging"); return false; }

	printf("Connected to log daemon on 127.0.0.1:8131\n");

	log_sink_sock = sock;

	return true;
}

// --------
// EXPORTED FUNCTIONS
// --------

// Sets the GC hook, logging or C hook delegate not yet enabled. Returns success.
bool set_gchook(void) {
	if (mtx_lock(&state_mutex) != thrd_success) {
		fprintf(stderr, "gc-hook: ERROR: Mutex lock failed\n");
		return false;
	}

	bool retval = false;

	if (!constructor_worked) {
		fprintf(stderr, "gc-hook: ERROR: Cannot set hook, system does not allow initialisation\n");
		goto unlock_return_retval;
	}

	if (hook_initialised) {
		fprintf(stderr, "gc-hook: ERROR: Hook already initialised\n");
		goto unlock_return_retval;
	}

	old_hook = rtsConfig.gcDoneHook;
	rtsConfig.gcDoneHook = hook_callback;

	if (clock_gettime(CLOCK_MONOTONIC, &app_init_time) != 0) {
		perror("clock_gettime");
		goto unlock_return_retval;
	}

	if (connect_log_sink()) {
		hook_initialised = true;
		retval = true;
	}

unlock_return_retval:
	mtx_unlock(&state_mutex);
	return retval;
}
