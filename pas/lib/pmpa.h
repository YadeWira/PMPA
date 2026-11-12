/* libpmpa: PMPA as a library, for archivers and other programs.

   PMPA recompresses MPEG audio files losslessly (MP1, MP2, MP3, with their
   tags; the JPEG covers of ID3v2 tags through PJA): the original comes back
   byte for byte. The library is one shared object (pmpa.so, pmpa.dll,
   pmpa.dylib) with a C interface, shaped as PJA's libpja (pja.h) and PPA's
   libppa (ppa.h); every function may be called from several threads at
   once.

   Two ways to use it:

   - One file in memory: pmpa_compress() writes a .pmpa (the same format as
     the `pmpa` command, with the original's size and BLAKE3 hash), and
     pmpa_decompress() gives the original back. A file PMPA does not take,
     or does not make smaller, comes back as PMPA_E_NOT_TAKEN, and the
     caller stores it its own way.

   - A filter over a stream of any bytes, for an archiver that puts many
     files in one stream (a solid block): pmpa_filter_encode() finds the
     runs of MPEG audio frames inside (with an ID3v2 tag just before a run
     and an ID3v1 tag just after it), recompresses each one that comes back
     byte for byte, and passes every other byte through untouched, so the
     archiver's own compressor (LZMA2, zstd...) still sees them.
     pmpa_filter_decode() gives the stream back. The filter's format is in
     doc/LIBRARY.md.

   Every buffer the library returns is freed with pmpa_free(), never with
   free().

   PMPA's formats are not frozen before a 0.9.x (doc/STABILITY.md): what a
   published release wrote is read by every later one; a .pmpa or a filter
   stream a later release wrote may not open in an earlier one, which says
   so with PMPA_E_VERSION. */
#ifndef PMPA_H
#define PMPA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && !defined(_WIN64)
#define PMPA_CALL __cdecl
#else
#define PMPA_CALL
#endif

enum {
  PMPA_OK = 0,
  PMPA_E_NOT_TAKEN = 1,  /* pmpa_compress: not a file PMPA takes or makes smaller (store it as is) */
  PMPA_E_DATA = 2,       /* the input is damaged or not PMPA's */
  PMPA_E_MEMORY = 3,     /* out of memory, or over a size limit */
  PMPA_E_READ = 4,       /* the filter's read callback failed */
  PMPA_E_WRITE = 5,      /* the filter's write callback failed */
  PMPA_E_ARG = 6,        /* a null pointer or a bad argument */
  PMPA_E_VERSION = 7     /* written by a newer PMPA: a .pmpa version, a codec stream
                            version, a filter version or record this release
                            does not know; also damage that lands on one of
                            those bytes, which cannot be told apart */
};

/* Error codes may be added; a caller treats one it does not know as an
   error, as it treats PMPA_E_DATA. */

/* "pmpa 0.5.0" */
const char *PMPA_CALL pmpa_version(void);

/* An MPEG audio file -> a .pmpa. threads: how many at once (1 to 64;
   outside that, the nearest): a file's bands of 2 MiB go on them. On
   PMPA_OK, *out holds *out_size bytes, to free with pmpa_free(). The .pmpa
   keeps no extension (the command's keeps the original's). */
int PMPA_CALL pmpa_compress(const void *in, size_t in_size, void **out, size_t *out_size, int threads);

/* A .pmpa -> the original, checked against its size and hash. max_size
   caps the original's size (0: no cap but the library's own, 2^31).
   PMPA_E_VERSION: a newer PMPA wrote it. */
int PMPA_CALL pmpa_decompress(const void *in, size_t in_size, void **out, size_t *out_size,
                              size_t max_size, int threads);

void PMPA_CALL pmpa_free(void *p);

/* The filter's callbacks. read: up to size bytes into buf; returns how
   many (0 at the end), or -1 on an error. write: all size bytes; returns 0,
   or -1 on an error. */
typedef ptrdiff_t (PMPA_CALL *pmpa_read_fn)(void *ctx, void *buf, size_t size);
typedef int (PMPA_CALL *pmpa_write_fn)(void *ctx, const void *buf, size_t size);

/* Every byte read -> the filter's stream, written. */
int PMPA_CALL pmpa_filter_encode(pmpa_read_fn read, void *read_ctx, pmpa_write_fn write, void *write_ctx,
                                 int threads);
/* The filter's stream, read -> the original bytes, written. PMPA_E_VERSION:
   a newer PMPA wrote it (a filter version or a record it does not know, or
   a run's codec stream of a later version); what came before it may have
   been written already. */
int PMPA_CALL pmpa_filter_decode(pmpa_read_fn read, void *read_ctx, pmpa_write_fn write, void *write_ctx,
                                 int threads);

#ifdef __cplusplus
}
#endif
#endif
