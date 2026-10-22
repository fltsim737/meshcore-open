/* Variable-length arrays for MeshCore Open's Codec2 build. Microsoft's C
 * compiler has none, so there they become _alloca stack allocations, freed
 * when the function returns; other compilers keep the original arrays.
 * CODEC2_FORCE_ALLOCA builds the _alloca form elsewhere, for testing. */
#ifndef CODEC2_VLA_H
#define CODEC2_VLA_H

#include <stddef.h>

#if defined(_MSC_VER) || defined(CODEC2_FORCE_ALLOCA)
#ifdef _MSC_VER
#include <malloc.h>
#define C2_ALLOCA _alloca
#else
#include <alloca.h>
#define C2_ALLOCA alloca
#endif
#define VLA(type, name, n) type *name = (type *)C2_ALLOCA(sizeof(type) * (size_t)(n))
/* n rows of a fixed number of columns */
#define VLA2(type, name, n, cols) \
  type(*name)[cols] = (type(*)[cols])C2_ALLOCA(sizeof(type) * (cols) * (size_t)(n))
#else
#define VLA(type, name, n) type name[n]
#define VLA2(type, name, n, cols) type name[n][cols]
#endif

#endif
