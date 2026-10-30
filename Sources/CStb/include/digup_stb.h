// stb_image (v2.30, public domain / MIT, Sources/CStb/stb_image.h) behind names of our own: llama.cpp links its own
// copy of stb_image into the same binary, so ours is compiled static and only these are exported.
#pragma once
#include <stdint.h>

/// Width and height without decoding; 0 when the file isn't a picture stb_image reads.
int digup_stb_info(const char *path, int *width, int *height);
/// The pixels as 8-bit RGB, rows top to bottom; NULL when unreadable. Free with digup_stb_free.
uint8_t *digup_stb_load_rgb(const char *path, int *width, int *height);
void digup_stb_free(void *pixels);
