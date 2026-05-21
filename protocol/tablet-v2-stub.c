// Minimal `zwp_tablet_tool_v2_interface` definition.
//
// `cursor-shape-v1`'s scanner-generated message table references this
// symbol (it's the type argument of `get_tablet_tool_v2`), but scrgo
// only ever talks to `wl_pointer`. Defining a small wl_interface here
// satisfies the linker without us having to ship the entire tablet-v2
// protocol code.
#include <wayland-util.h>

const struct wl_interface zwp_tablet_tool_v2_interface = {
    "zwp_tablet_tool_v2", 1, 0, NULL, 0, NULL,
};
