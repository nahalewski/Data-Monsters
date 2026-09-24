/* stb_vorbis in its own translation unit: it defines short macros (L, C, R)
 * that would clash with Lua code. */
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PUSHDATA_API
#include "stb_vorbis.c"
