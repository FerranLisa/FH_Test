#ifndef FH_VERSION_H
#define FH_VERSION_H
/* Product release, independent of capture register IDs and wire protocols.
 * Keep software/host/fh_version.py aligned; scripts/verify_sources.py checks this. */
#define FH_RELEASE "V25.3"
#define FH_RELEASE_STATE "emmc-ext4"
#define FH_RELEASE_LABEL FH_RELEASE " (" FH_RELEASE_STATE ")"
#endif
