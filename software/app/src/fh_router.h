#ifndef FH_ROUTER_H
#define FH_ROUTER_H
#include "fh_frame_export.h"
typedef struct { u32 mode, n, x0, y0, x1, y1; } FhRoute;
typedef struct { u32 width, height, origin_x, origin_y, step, bytes; } FhRouteGeometry;
int fh_router_available(void);
int fh_router_geometry(const FhRoute *c, const FhFrameRecord *r, FhRouteGeometry *g);
int fh_router_start(const FhRoute *c, const FhFrameRecord *r, u32 sensor);
int fh_router_poll(void); /* 0 busy, 1 complete, -1 error */
void fh_router_abort(void);
const u8 *fh_router_pixels(void);
#endif
