#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#include "stb_image.h"
#include "digup_stb.h"

int digup_stb_info(const char *path, int *width, int *height) {
    int channels;
    return stbi_info(path, width, height, &channels);
}

uint8_t *digup_stb_load_rgb(const char *path, int *width, int *height) {
    int channels;
    return stbi_load(path, width, height, &channels, 3);
}

void digup_stb_free(void *pixels) {
    stbi_image_free(pixels);
}

int digup_stb_info_memory(const uint8_t *bytes, int length, int *width, int *height) {
    int channels;
    return stbi_info_from_memory(bytes, length, width, height, &channels);
}

uint8_t *digup_stb_load_rgb_memory(const uint8_t *bytes, int length, int *width, int *height) {
    int channels;
    return stbi_load_from_memory(bytes, length, width, height, &channels, 3);
}
