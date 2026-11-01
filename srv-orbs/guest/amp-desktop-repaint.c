// amp-desktop-repaint: keeps a fully transparent 1x1 surface on the wlroots
// overlay layer of Amp's orb Desktop and recommits it on SIGUSR1.
//
// Amp's Desktop stream (waymote) encodes only when the screen is damaged. A
// viewer that (re)connects while the screen is static, after the gateway lost
// its cached keyframe, waits forever for a first frame and shows nothing. Each
// recommit damages one invisible pixel, so the compositor renders a frame and
// the stream sends a keyframe. The surface takes no input and never focus.
//
// Exits when the compositor goes away. Build:
//   wayland-scanner client-header  wlr-layer-shell-unstable-v1.xml layer-shell.h
//   wayland-scanner private-code   wlr-layer-shell-unstable-v1.xml layer-shell.c
//   wayland-scanner private-code   xdg-shell.xml xdg-shell.c
//   cc -O2 -o amp-desktop-repaint amp-desktop-repaint.c layer-shell.c xdg-shell.c -lwayland-client
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/signalfd.h>
#include <unistd.h>
#include <wayland-client.h>

#include "layer-shell.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct zwlr_layer_shell_v1 *layer_shell;
static int configured;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface,
		   uint32_t version) {
	(void)data;
	if (strcmp(interface, wl_compositor_interface.name) == 0)
		compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
	else if (strcmp(interface, wl_shm_interface.name) == 0)
		shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	else if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0)
		layer_shell = wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, version < 3 ? version : 3);
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
	(void)data, (void)registry, (void)name;
}

static const struct wl_registry_listener registry_listener = {global, global_remove};

static void layer_configure(void *data, struct zwlr_layer_surface_v1 *layer, uint32_t serial, uint32_t w,
			    uint32_t h) {
	(void)data, (void)w, (void)h;
	zwlr_layer_surface_v1_ack_configure(layer, serial);
	configured = 1;
}

static void layer_closed(void *data, struct zwlr_layer_surface_v1 *layer) {
	(void)data, (void)layer;
	_exit(0);
}

static const struct zwlr_layer_surface_v1_listener layer_listener = {layer_configure, layer_closed};

static void buffer_release(void *data, struct wl_buffer *buffer) {
	(void)data;
	wl_buffer_destroy(buffer);
}

static const struct wl_buffer_listener buffer_listener = {buffer_release};

// A fresh transparent 1x1 buffer per commit: never reattach one the compositor holds.
static struct wl_buffer *transparent_pixel(void) {
	int fd = memfd_create("amp-desktop-repaint", MFD_CLOEXEC);
	if (fd < 0 || ftruncate(fd, 4) < 0)
		return NULL;
	uint32_t *pixel = mmap(NULL, 4, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (pixel == MAP_FAILED) {
		close(fd);
		return NULL;
	}
	*pixel = 0; // ARGB8888, alpha 0
	munmap(pixel, 4);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, 4);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, 1, 1, 4, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	wl_buffer_add_listener(buffer, &buffer_listener, NULL);
	return buffer;
}

static int repaint(struct wl_surface *surface) {
	struct wl_buffer *buffer = transparent_pixel();
	if (!buffer)
		return -1;
	wl_surface_attach(surface, buffer, 0, 0);
	wl_surface_damage_buffer(surface, 0, 0, 1, 1);
	wl_surface_commit(surface);
	return 0;
}

int main(void) {
	struct wl_display *display = wl_display_connect(NULL);
	if (!display) {
		fprintf(stderr, "amp-desktop-repaint: cannot connect to the Wayland display\n");
		return 1;
	}
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);
	wl_display_roundtrip(display);
	if (!compositor || !shm || !layer_shell) {
		fprintf(stderr, "amp-desktop-repaint: the compositor lacks wl_compositor, wl_shm or layer shell\n");
		return 1;
	}

	struct wl_surface *surface = wl_compositor_create_surface(compositor);
	struct wl_region *empty = wl_compositor_create_region(compositor);
	wl_surface_set_input_region(surface, empty); // clicks pass through
	wl_region_destroy(empty);
	struct zwlr_layer_surface_v1 *layer = zwlr_layer_shell_v1_get_layer_surface(
		layer_shell, surface, NULL, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "amp-desktop-repaint");
	zwlr_layer_surface_v1_add_listener(layer, &layer_listener, NULL);
	zwlr_layer_surface_v1_set_size(layer, 1, 1);
	zwlr_layer_surface_v1_set_anchor(layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
	zwlr_layer_surface_v1_set_exclusive_zone(layer, -1);
	zwlr_layer_surface_v1_set_keyboard_interactivity(layer, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
	wl_surface_commit(surface);
	while (!configured)
		if (wl_display_dispatch(display) < 0)
			return 1;
	if (repaint(surface) < 0)
		return 1;

	sigset_t signals;
	sigemptyset(&signals);
	sigaddset(&signals, SIGUSR1);
	sigaddset(&signals, SIGTERM);
	sigaddset(&signals, SIGINT);
	sigprocmask(SIG_BLOCK, &signals, NULL);
	int sfd = signalfd(-1, &signals, SFD_CLOEXEC);
	if (sfd < 0)
		return 1;

	struct pollfd fds[2] = {{wl_display_get_fd(display), POLLIN, 0}, {sfd, POLLIN, 0}};
	for (;;) {
		while (wl_display_prepare_read(display) != 0)
			wl_display_dispatch_pending(display);
		if (wl_display_flush(display) < 0 && errno != EAGAIN)
			return 0;
		if (poll(fds, 2, -1) < 0) {
			wl_display_cancel_read(display);
			if (errno == EINTR)
				continue;
			return 1;
		}
		if (fds[0].revents & POLLIN) {
			if (wl_display_read_events(display) < 0)
				return 0;
		} else {
			wl_display_cancel_read(display);
		}
		if (fds[0].revents & (POLLERR | POLLHUP))
			return 0;
		if (wl_display_dispatch_pending(display) < 0)
			return 0;
		if (fds[1].revents & POLLIN) {
			struct signalfd_siginfo info;
			if (read(sfd, &info, sizeof info) != sizeof info)
				continue;
			if (info.ssi_signo != SIGUSR1)
				return 0;
			if (repaint(surface) < 0)
				return 1;
		}
	}
}
