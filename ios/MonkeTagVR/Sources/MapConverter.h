#ifndef GTAG_MAP_CONVERTER_H
#define GTAG_MAP_CONVERTER_H
#ifdef __cplusplus
extern "C" {
#endif
int gtag_convert_fbx_to_obj(const char *fbx_path, const char *obj_path, const char *texture_dir, float *spawn_x, float *spawn_y, float *spawn_z);
#ifdef __cplusplus
}
#endif
#endif
