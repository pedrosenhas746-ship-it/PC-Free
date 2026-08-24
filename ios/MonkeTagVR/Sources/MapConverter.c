#include "MapConverter.h"
#include "UFBX/ufbx.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct GTagVertex {
    float x,y,z;
    float nx,ny,nz;
    float u,v;
} GTagVertex;

static const char *base_name(const char *p) {
    if (!p) return "";
    const char *a = strrchr(p, '/');
    const char *b = strrchr(p, '\\');
    const char *r = a > b ? a : b;
    return r ? r + 1 : p;
}

static void sanitize_name(char *dst, size_t cap, const char *src, size_t len, unsigned id) {
    if (!src || !len) { snprintf(dst, cap, "mat_%u", id); return; }
    size_t n = 0;
    for (size_t i=0;i<len && n+1<cap;i++) {
        char c = src[i];
        if ((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-') dst[n++]=c;
        else dst[n++]='_';
    }
    dst[n]='\0';
}

static void write_materials(FILE *mtl, ufbx_scene *scene, const char *texture_dir) {
    for (size_t i=0; i<scene->materials.count; i++) {
        ufbx_material *m = scene->materials.data[i];
        char name[160]; sanitize_name(name, sizeof(name), m->name.data, m->name.length, (unsigned)m->typed_id);
        ufbx_vec3 c = {0.65,0.65,0.65};
        if (m->pbr.base_color.has_value) c = m->pbr.base_color.value_vec3;
        else if (m->fbx.diffuse_color.has_value) c = m->fbx.diffuse_color.value_vec3;
        fprintf(mtl, "newmtl %s\nKd %.6f %.6f %.6f\nKa 0.08 0.08 0.08\nKs 0.03 0.03 0.03\nNs 8\n", name, (double)c.x, (double)c.y, (double)c.z);
        ufbx_texture *tex = m->pbr.base_color.texture;
        if (!tex) tex = m->fbx.diffuse_color.texture;
        if (tex && tex->filename.length && texture_dir) {
            const char *bn = base_name(tex->filename.data);
            if (bn && *bn) fprintf(mtl, "map_Kd %s/%s\n", texture_dir, bn);
        }
        fprintf(mtl, "\n");
    }
}

int gtag_convert_fbx_to_obj(const char *fbx_path, const char *obj_path, const char *texture_dir, float *spawn_x, float *spawn_y, float *spawn_z) {
    if (!fbx_path || !obj_path) return 1;
    ufbx_load_opts opts = {0};
    opts.target_axes = ufbx_axes_right_handed_y_up;
    opts.target_unit_meters = 1.0f;
    opts.space_conversion = UFBX_SPACE_CONVERSION_MODIFY_GEOMETRY;
    ufbx_error error;
    ufbx_scene *scene = ufbx_load_file(fbx_path, &opts, &error);
    if (!scene) return 2;

    char mtl_path[4096];
    snprintf(mtl_path, sizeof(mtl_path), "%s", obj_path);
    char *dot = strrchr(mtl_path, '.');
    if (dot) strcpy(dot, ".mtl"); else strncat(mtl_path, ".mtl", sizeof(mtl_path)-strlen(mtl_path)-1);
    const char *mtl_name = base_name(mtl_path);

    FILE *obj = fopen(obj_path, "wb");
    FILE *mtl = fopen(mtl_path, "wb");
    if (!obj || !mtl) { if(obj)fclose(obj); if(mtl)fclose(mtl); ufbx_free_scene(scene); return 3; }
    fprintf(obj, "mtllib %s\n", mtl_name);
    write_materials(mtl, scene, texture_dir);

    if (spawn_x) *spawn_x = 0.0f; if (spawn_y) *spawn_y = 1.55f; if (spawn_z) *spawn_z = 3.2f;
    for (size_t ni=0; ni<scene->nodes.count; ni++) {
        ufbx_node *node = scene->nodes.data[ni];
        if (node->name.data && strstr(node->name.data, "treeroom_fixed")) {
            ufbx_vec3 p = ufbx_transform_position(&node->node_to_world, (ufbx_vec3){0,0,0});
            if (spawn_x) *spawn_x = (float)p.x;
            if (spawn_y) *spawn_y = (float)p.y + 1.45f;
            if (spawn_z) *spawn_z = (float)p.z;
        }
    }

    size_t vertex_base = 1;
    for (size_t ni=0; ni<scene->nodes.count; ni++) {
        ufbx_node *node = scene->nodes.data[ni];
        ufbx_mesh *mesh = node->mesh;
        if (!mesh || !node->visible || mesh->num_triangles == 0) continue;
        size_t corner_cap = mesh->num_triangles * 3;
        GTagVertex *verts = (GTagVertex*)malloc(corner_cap * sizeof(GTagVertex));
        uint32_t *corner_indices = (uint32_t*)malloc(corner_cap * sizeof(uint32_t));
        uint32_t *tri_mats = (uint32_t*)malloc(mesh->num_triangles * sizeof(uint32_t));
        uint32_t *tri_tmp = (uint32_t*)malloc(mesh->max_face_triangles * 3 * sizeof(uint32_t));
        if (!verts || !corner_indices || !tri_mats || !tri_tmp) { free(verts); free(corner_indices); free(tri_mats); free(tri_tmp); continue; }
        ufbx_matrix normal_m = ufbx_matrix_for_normals(&node->geometry_to_world);
        size_t vc=0, tc=0;
        for (size_t fi=0; fi<mesh->faces.count; fi++) {
            ufbx_face face = mesh->faces.data[fi];
            uint32_t nt = ufbx_triangulate_face(tri_tmp, mesh->max_face_triangles*3, mesh, face);
            uint32_t mi = (mesh->face_material.count > fi) ? mesh->face_material.data[fi] : 0;
            uint32_t mat_id = 0xffffffffu;
            if (node->materials.count > mi && node->materials.data[mi]) mat_id = node->materials.data[mi]->typed_id;
            for (uint32_t t=0; t<nt; t++) tri_mats[tc++] = mat_id;
            for (uint32_t k=0; k<nt*3; k++) {
                uint32_t ix = tri_tmp[k];
                ufbx_vec3 p = ufbx_get_vertex_vec3(&mesh->vertex_position, ix);
                ufbx_vec3 n = mesh->vertex_normal.exists ? ufbx_get_vertex_vec3(&mesh->vertex_normal, ix) : (ufbx_vec3){0,1,0};
                ufbx_vec2 uv = mesh->vertex_uv.exists ? ufbx_get_vertex_vec2(&mesh->vertex_uv, ix) : (ufbx_vec2){0,0};
                p = ufbx_transform_position(&node->geometry_to_world, p);
                n = ufbx_transform_direction(&normal_m, n);
                double nl = sqrt(n.x*n.x+n.y*n.y+n.z*n.z); if (nl > 1e-9) { n.x/=nl; n.y/=nl; n.z/=nl; }
                verts[vc++] = (GTagVertex){(float)p.x,(float)p.y,(float)p.z,(float)n.x,(float)n.y,(float)n.z,(float)uv.x,(float)uv.y};
            }
        }
        if (vc == 0) { free(verts); free(corner_indices); free(tri_mats); free(tri_tmp); continue; }
        ufbx_vertex_stream stream = { verts, vc, sizeof(GTagVertex) };
        size_t unique = ufbx_generate_indices(&stream, 1, corner_indices, vc, NULL, NULL);
        fprintf(obj, "o node_%zu_%s\n", ni, node->name.data ? node->name.data : "mesh");
        for (size_t i=0;i<unique;i++) fprintf(obj, "v %.7g %.7g %.7g\n", verts[i].x, verts[i].y, verts[i].z);
        for (size_t i=0;i<unique;i++) fprintf(obj, "vt %.7g %.7g\n", verts[i].u, verts[i].v);
        for (size_t i=0;i<unique;i++) fprintf(obj, "vn %.7g %.7g %.7g\n", verts[i].nx, verts[i].ny, verts[i].nz);
        uint32_t current_mat = 0xfffffffeu;
        for (size_t t=0;t<tc;t++) {
            uint32_t mat_id = tri_mats[t];
            if (mat_id != current_mat) {
                current_mat = mat_id;
                if (mat_id != 0xffffffffu && mat_id < scene->materials.count) {
                    ufbx_material *m = scene->materials.data[mat_id];
                    char mn[160]; sanitize_name(mn, sizeof(mn), m->name.data, m->name.length, (unsigned)m->typed_id);
                    fprintf(obj, "usemtl %s\n", mn);
                }
            }
            size_t a = vertex_base + corner_indices[t*3+0];
            size_t b = vertex_base + corner_indices[t*3+1];
            size_t c = vertex_base + corner_indices[t*3+2];
            fprintf(obj, "f %zu/%zu/%zu %zu/%zu/%zu %zu/%zu/%zu\n", a,a,a,b,b,b,c,c,c);
        }
        vertex_base += unique;
        free(verts); free(corner_indices); free(tri_mats); free(tri_tmp);
    }
    fclose(obj); fclose(mtl); ufbx_free_scene(scene); return 0;
}
