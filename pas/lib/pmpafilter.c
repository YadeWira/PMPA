/* libpmpa's filter (pmpa.h: pmpa_filter_encode and pmpa_filter_decode,
   through pmpalib.pas): the runs of MPEG audio frames inside a stream of any
   bytes, recompressed by PMPA; every other byte passed through as it was,
   for the archiver's own compressor. From PPA's ppafilter.c (itself from
   PJA's pjafilter.c), with MPEG audio's runs in place of PNG's files.

   The filter's stream (doc/LIBRARY.md):

     "PMPF" 01                     magic and version
     records, each a tag byte:
       00 n bytes                  n raw bytes (n a LEB128 number, >= 1)
       01 size n stream            a run of `size` bytes, as PMPA's codec
                                   stream of n bytes (pmpacodec.EncodeFile)
       FF                          the end
     02 to FE are left for records of later releases: a decoder that meets
     one stops with PMPA_E_VERSION, as it does at a version past its own.

   MPEG audio has no end marker: what the encoder takes is a run of frames,
   at least MIN_RUN in a row, each header valid and of the same stream
   (version, layer and sample rate) as the first, each frame starting where
   the one before ends, and each followed by another such header, a tag
   (ID3v1, ID3v2, APE) or the end of the input: a frame a file cuts short
   would otherwise run into the next file and swallow its ID3v2 tag. With
   the ID3v2 tag that ends where the run starts (and up to PAD_MAX zero
   bytes of padding after it), and the 128-byte ID3v1 tag that starts where
   the run ends. A free-format
   frame (no length in its header) ends a run. A run that PMPA does not
   take, that does not come back byte for byte (the codec verifies) or that
   does not get smaller stays raw; one past MAX_FILE is cut at a frame
   there, and goes on as another.

   Like the codec's C, this file calls no library: the host (pmpalib.pas)
   gives it memory and PMPA's codec through pmpafilter_host. */
#include <stddef.h>
#include <stdint.h>

#define PMPA_OK 0
#define PMPA_E_DATA 2
#define PMPA_E_MEMORY 3
#define PMPA_E_READ 4
#define PMPA_E_WRITE 5
#define PMPA_E_ARG 6
#define PMPA_E_VERSION 7

#if defined(_WIN32) && !defined(_WIN64)
#define PMPA_CALL __cdecl
#else
#define PMPA_CALL
#endif

typedef ptrdiff_t (PMPA_CALL *pmpa_read_fn)(void *ctx, void *buf, size_t size);
typedef int (PMPA_CALL *pmpa_write_fn)(void *ctx, const void *buf, size_t size);

/* what pmpalib.pas gives: memory, and a pool of threads that runs PMPA's
   codec on one run at a time each. A job is submitted, runs when a thread
   is free, and is waited for, in any order. Then ok is set and, when ok,
   out (from alloc) and out_size: encoding, PMPA's codec stream of the run
   (ok = 0 when PMPA does not take it); decoding, the run, which must be
   `expected` bytes. threads: how many threads the run's bands may use. */
typedef struct {
  const uint8_t *in;
  size_t size, expected;
  uint8_t *out;
  size_t out_size;
  int ok, threads;
  volatile int done;  /* set by the pool */
  /* decoding, not ok: why, when it is not damage (PMPA_E_DATA): 1, the
     file's codec stream is of a later version (PMPA_E_VERSION); 2, there
     was no memory for it (PMPA_E_MEMORY) */
  int cause;
} job_t;
typedef struct {
  void *(*alloc)(size_t size);
  void (*release)(void *p);
  void *(*pool_open)(int threads, int encode);
  void (*pool_submit)(void *pool, job_t *job);
  void (*pool_wait)(void *pool, job_t *job);
  void (*pool_close)(void *pool);
} host_t;

static host_t H;

void pmpafilter_host(const host_t *h) { H = *h; }

enum {
  MAX_FILE = 256 << 20,         /* the longest run recompressed at once */
  MIN_RUN = 3,                  /* frames in a row to take a run */
  PAD_MAX = 65536,              /* zero bytes after an ID3v2 tag, before the frames */
  WINDOW = 1 << 20,             /* the encoder's first buffer */
  RAW_RUN = 1 << 18,            /* the longest raw record */
  AHEAD_BYTES = 64 << 20,       /* the files' bytes in the pool at most */
  IOBUF = 1 << 16,              /* the decoder's read buffer */
  TAG_RAW = 0x00, TAG_FILE = 0x01, TAG_END = 0xFF
};
static const uint8_t MAGIC[5] = {'P', 'M', 'P', 'F', 1};

static void copy(uint8_t *d, const uint8_t *s, size_t n) {
  while (n--) *d++ = *s++;
}
static void move_down(uint8_t *d, const uint8_t *s, size_t n) {  /* d < s */
  while (n--) *d++ = *s++;
}

/* ---------- where a run of MPEG audio frames ends ---------- */

enum { EXT_NOT = 0, EXT_MORE = -1 };

/* kbit/s by [MPEG-1 or not][layer 1..3][index]; 0 for free format */
static const uint16_t BITRATE[2][3][15] = {
  {{0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448},
   {0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384},
   {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320}},
  {{0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256},
   {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160},
   {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160}}};
static const uint32_t RATE[3] = {44100, 48000, 32000};

/* the frame whose header is at p: its length, 0 if the header is not a
   valid one with a length (free format, a reserved field); *key: its
   stream (version, layer, sample rate) */
static uint32_t frame_len(const uint8_t *p, uint32_t *key) {
  uint32_t h = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
  if ((h >> 21) != 0x7FF) return 0;
  uint32_t ver = (h >> 19) & 3, layer = 4 - ((h >> 17) & 3), bi = (h >> 12) & 15, si = (h >> 10) & 3;
  uint32_t pad = (h >> 9) & 1, emph = h & 3;
  if (ver == 1 || layer == 4 || bi == 0 || bi == 15 || si == 3 || emph == 2) return 0;
  uint32_t br = BITRATE[ver != 3][layer - 1][bi] * 1000u;
  uint32_t sr = RATE[si] >> (ver == 3 ? 0 : ver == 2 ? 1 : 2);
  *key = h & 0xFFFE0C00u;   /* sync, version, layer and sample rate */
  if (layer == 1) return (12 * br / sr + pad) * 4;
  return (layer == 3 && ver != 3 ? 72 : 144) * br / sr + pad;
}

/* the ID3v2 tag at p (n bytes there): its length, 0 if there is none */
static size_t id3v2_len(const uint8_t *p, size_t n) {
  if (n < 10 || p[0] != 'I' || p[1] != 'D' || p[2] != '3' || p[3] == 0xFF || p[4] == 0xFF) return 0;
  if ((p[6] | p[7] | p[8] | p[9]) & 0x80) return 0;
  size_t len = 10 + ((size_t)p[6] << 21 | (size_t)p[7] << 14 | (size_t)p[8] << 7 | p[9]);
  if (p[5] & 0x10) len += 10;   /* a footer */
  return len;
}

/* what may follow a frame of a run (key: its stream) at p, k bytes there:
   1 yes, 0 no, -1 not enough bytes to tell */
static int follows(const uint8_t *p, size_t k, uint32_t key) {
  uint32_t k2 = 0;
  if (k < 4) return -1;
  if (frame_len(p, &k2) && k2 == key) return 1;
  if ((p[0] == 'T' && p[1] == 'A' && p[2] == 'G') || (p[0] == 'I' && p[1] == 'D' && p[2] == '3')) return 1;
  if (p[0] == 'A' && p[1] == 'P' && p[2] == 'E' && p[3] == 'T') return 1;
  return 0;
}

/* p[0..n): where a run may start (an ID3v2 tag, or a frame's header). Its
   length up to its last frame (and an ID3v1 tag after it), EXT_MORE if n
   bytes are not enough to tell and the input goes on, EXT_NOT if no run
   starts there. x keeps where it got to between calls on the same run with
   more bytes each time (start it as EXT_START), so that a long run is
   walked once. */
typedef struct { size_t i, start; int frames; uint32_t key; } ext_t;
static const ext_t EXT_START = {0, 0, -1, 0};
static ptrdiff_t mpeg_extent(const uint8_t *p, size_t n, int eof, ext_t *x) {
  if (x->frames < 0) {                       /* where the frames start */
    size_t t = id3v2_len(p, n);
    if (!t && n < 10 && !eof && n >= 3 && p[0] == 'I' && p[1] == 'D' && p[2] == '3') return EXT_MORE;
    if (t > MAX_FILE) return EXT_NOT;
    if (t && t + 4 > n) return eof ? EXT_NOT : EXT_MORE;
    if (t) {                                 /* zero padding after the tag */
      size_t z = t;
      while (z < n && z - t < PAD_MAX && !p[z]) z++;
      if (z == n && !eof && z - t < PAD_MAX) return EXT_MORE;
      if (z > t && z + 4 <= n) t = z;
    }
    x->i = x->start = t; x->frames = 0;
  }
  for (;;) {
    size_t i = x->i;
    uint32_t key = 0, len = 0;
    if (i + 4 <= n) len = frame_len(p + i, &key);
    else if (!eof) return EXT_MORE;
    if (len && x->frames && key != x->key) len = 0;
    if (len && i + len > n) {                /* a frame not all here */
      if (!eof) return EXT_MORE;
      len = 0;
    }
    if (len && i + len > MAX_FILE) len = 0;  /* cut: the rest is another run */
    if (len && i + len < n) {                /* what follows it */
      int f = follows(p + i + len, n - i - len, x->frames ? x->key : key);
      if (f < 0 && !eof) return EXT_MORE;
      if (f <= 0) len = 0;
    } else if (len && i + len == n && !eof) return EXT_MORE;
    if (!len) {                              /* the run ends at i */
      if (x->frames < MIN_RUN) return EXT_NOT;
      if (i + 128 <= n && p[i] == 'T' && p[i + 1] == 'A' && p[i + 2] == 'G') return (ptrdiff_t)(i + 128);
      if (i + 128 > n && !eof && i + 3 <= n && p[i] == 'T' && p[i + 1] == 'A' && p[i + 2] == 'G') return EXT_MORE;
      return (ptrdiff_t)i;
    }
    if (!x->frames) x->key = key;
    x->frames++;
    x->i = i + len;
  }
}

/* where a run may start at p: an ID3v2 tag, or a frame's sync */
static int may_start(const uint8_t *p) {
  return (p[0] == 0xFF && (p[1] & 0xE0) == 0xE0) || (p[0] == 'I' && p[1] == 'D' && p[2] == '3');
}

/* ---------- writing ---------- */

typedef struct {
  pmpa_write_fn write;
  void *ctx;
  int err;
} out_t;

static void put(out_t *o, const void *b, size_t n) {
  if (o->err || !n) return;
  if (o->write(o->ctx, b, n) != 0) o->err = PMPA_E_WRITE;
}
static void put_num(out_t *o, uint64_t v) {
  uint8_t b[10];
  int k = 0;
  do { b[k] = (uint8_t)(v & 0x7F); v >>= 7; if (v) b[k] |= 0x80; k++; } while (v);
  put(o, b, (size_t)k);
}
static void put_raw(out_t *o, const uint8_t *b, size_t n) {
  if (!n) return;
  uint8_t t = TAG_RAW;
  put(o, &t, 1); put_num(o, n); put(o, b, n);
}

/* ---------- the encoder ---------- */

/* Files go to the pool as they are found, up to 8 per thread (or
   AHEAD_BYTES) ahead of the oldest, which is written as soon as it is done,
   with the raw bytes before it; so reading, compressing and writing
   overlap. What is written does not depend on any of this (nor on how the
   bytes were read): raw bytes go out in records of RAW_RUN bytes counted
   from the end of the last file written, the rest of a run just before the
   next file. */

typedef struct {
  pmpa_read_fn read;
  void *ctx;
  uint8_t *buf;
  size_t cap, have;
  int eof, err;
  /* buf[rs..): not written yet; files in the pool, oldest first: a ring of
     np from first, their place in buf in at[] */
  size_t rs;
  job_t *files;
  size_t *at;
  int first, np, maxp;
  size_t pbytes;
  void *pool;
  int threads;
} in_t;

/* more bytes. When the buffer is full, what is before rs (written already)
   makes room, and every position kept moves with it (*x, the files); if it
   is still full, the buffer doubles. */
static void fill(in_t *s, size_t *x) {
  if (s->have == s->cap && s->rs) {
    size_t d = s->rs;
    move_down(s->buf, s->buf + d, s->have - d);
    s->have -= d; *x -= d; s->rs = 0;
    for (int k = 0; k < s->np; k++) s->at[(s->first + k) % s->maxp] -= d;
  }
  if (s->have == s->cap) {
    size_t c = s->cap * 2;
    uint8_t *b = H.alloc(c);
    if (!b) { s->err = PMPA_E_MEMORY; return; }
    copy(b, s->buf, s->have);
    H.release(s->buf);
    s->buf = b; s->cap = c;
  }
  ptrdiff_t got = s->read(s->ctx, s->buf + s->have, s->cap - s->have);
  if (got < 0) s->err = PMPA_E_READ;
  else if (got == 0) s->eof = 1;
  else s->have += (size_t)got;
}

/* raw bytes up to `to`: whole RAW_RUN records only, unless `all` */
static void raw_upto(in_t *s, out_t *o, size_t to, int all) {
  while (to - s->rs >= RAW_RUN) { put_raw(o, s->buf + s->rs, RAW_RUN); s->rs += RAW_RUN; }
  if (all) { put_raw(o, s->buf + s->rs, to - s->rs); s->rs = to; }
}

/* the file buf[c..c+len) to the pool, as a copy (the buffer moves) */
static void submit(in_t *s, size_t c, size_t len) {
  int k = (s->first + s->np) % s->maxp;
  job_t *f = &s->files[k];
  uint8_t *in = H.alloc(len);
  if (!in) { s->err = PMPA_E_MEMORY; return; }
  copy(in, s->buf + c, len);
  f->in = in; f->size = len; f->expected = 0; f->out = 0; f->out_size = 0; f->ok = 0; f->done = 0; f->cause = 0;
  /* a run alone gets the threads for its bands; more runs share them */
  f->threads = s->threads / (s->np + 1);
  if (f->threads < 1) f->threads = 1;
  s->at[k] = c;
  s->np++; s->pbytes += len;
  H.pool_submit(s->pool, f);
}

/* an error already: what is left is only waited for */
static int failed(const in_t *s, const out_t *o) {
  return s->err || o->err;
}

/* a run of size bytes PMPA took and made smaller, in a record the decoder
   takes (size <= MAX_FILE, 0 < n < size) */
static int smaller(const job_t *f, size_t size) {
  return f->ok && f->out_size && f->out_size + 12 < size && size <= MAX_FILE;
}

/* the oldest file in the pool, waited for and written with the raw bytes
   before it; one PMPA did not take, or that did not get smaller, stays in
   the raw run around it */
static void retire(in_t *s, out_t *o) {
  int k = s->first;
  job_t *f = &s->files[k];
  size_t size = f->size;
  H.pool_wait(s->pool, f);
  if (smaller(f, size) && !failed(s, o)) {
    raw_upto(s, o, s->at[k], 1);
    uint8_t t = TAG_FILE;
    put(o, &t, 1); put_num(o, size); put_num(o, f->out_size);
    put(o, f->out, f->out_size);
    s->rs = s->at[k] + size;
  }
  if (f->out) H.release(f->out);
  H.release((void *)f->in);
  s->first = (s->first + 1) % s->maxp;
  s->np--; s->pbytes -= f->size;
}

int pmpafilter_encode(pmpa_read_fn read, void *read_ctx, pmpa_write_fn write, void *write_ctx, int threads) {
  if (!read || !write || !H.alloc) return PMPA_E_ARG;
  if (threads < 1) threads = 1;
  in_t s = {0};
  s.read = read; s.ctx = read_ctx; s.cap = WINDOW;
  s.maxp = 8 * threads; s.threads = threads;
  out_t o = {write, write_ctx, 0};
  s.buf = H.alloc(s.cap);
  s.files = H.alloc(sizeof(job_t) * (size_t)s.maxp);
  s.at = H.alloc(sizeof(size_t) * (size_t)s.maxp);
  s.pool = H.pool_open(threads, 1);
  if (!s.buf || !s.files || !s.at || !s.pool) s.err = PMPA_E_MEMORY;
  put(&o, MAGIC, sizeof MAGIC);
  size_t pos = 0;                                 /* where the search goes on */
  while (!failed(&s, &o)) {
    size_t c = pos;
    while (c + 4 <= s.have && !may_start(s.buf + c)) c++;
    if (!s.np) raw_upto(&s, &o, c, 0);
    if (c + 4 > s.have) {                         /* no run starts in what is here */
      if (s.eof) {
        while (s.np) retire(&s, &o);
        raw_upto(&s, &o, s.have, 1);
        break;
      }
      pos = c;
      /* files in the pool while raw bytes pile up behind them: write them,
         so that the buffer does not grow with the raw bytes */
      if (s.np && s.have - s.rs >= AHEAD_BYTES) while (s.np) retire(&s, &o);
      fill(&s, &pos);
      continue;
    }
    ptrdiff_t len;
    ext_t x = EXT_START;
    for (;;) {
      len = mpeg_extent(s.buf + c, s.have - c, s.eof, &x);
      if (len != EXT_MORE || s.eof || s.err || s.have - c > MAX_FILE + 256) break;
      fill(&s, &c);
    }
    if (len == EXT_MORE) len = EXT_NOT;
    if (s.err) break;
    if (len <= 0) { pos = c + 1; continue; }
    while (s.np && (s.np == s.maxp || s.pbytes + (size_t)len > AHEAD_BYTES)) retire(&s, &o);
    submit(&s, c, (size_t)len);
    pos = c + (size_t)len;
  }
  /* on an error, the files still in the pool are waited for and dropped */
  while (s.np) {
    job_t *f = &s.files[s.first];
    H.pool_wait(s.pool, f);
    if (f->out) H.release(f->out);
    H.release((void *)f->in);
    s.first = (s.first + 1) % s.maxp; s.np--;
  }
  if (!failed(&s, &o)) { uint8_t t = TAG_END; put(&o, &t, 1); }
  if (s.pool) H.pool_close(s.pool);
  if (s.buf) H.release(s.buf);
  if (s.files) H.release(s.files);
  if (s.at) H.release(s.at);
  return s.err ? s.err : o.err;
}

/* ---------- the decoder ---------- */

typedef struct {
  pmpa_read_fn read;
  void *ctx;
  uint8_t *buf;
  size_t p, n;
  int err;
} rd_t;

static size_t rd(rd_t *r, uint8_t *d, size_t want) {
  size_t got = 0;
  while (got < want && !r->err) {
    if (r->p == r->n) {
      ptrdiff_t k = r->read(r->ctx, r->buf, IOBUF);
      if (k < 0) { r->err = PMPA_E_READ; break; }
      if (k == 0) break;
      r->p = 0; r->n = (size_t)k;
    }
    size_t k = r->n - r->p;
    if (k > want - got) k = want - got;
    copy(d + got, r->buf + r->p, k);
    r->p += k; got += k;
  }
  return got;
}
static int rd_byte(rd_t *r) {
  if (r->p == r->n) {
    if (r->err) return -1;
    ptrdiff_t k = r->read(r->ctx, r->buf, IOBUF);
    if (k < 0) r->err = PMPA_E_READ;
    if (k <= 0) return -1;
    r->p = 0; r->n = (size_t)k;
  }
  return r->buf[r->p++];
}
static int rd_num(rd_t *r, uint64_t *v) {
  *v = 0;
  for (int sh = 0; sh < 64; sh += 7) {
    int b = rd_byte(r);
    if (b < 0) return 0;
    *v |= (uint64_t)(b & 0x7F) << sh;
    if (!(b & 0x80)) return 1;
  }
  return 0;
}

/* The decoder works the same way: each file's stream goes to the pool as
   it is read, raw records wait in memory behind the files before them, and
   the oldest item is written as soon as it can be: up to 8 files per
   thread (or AHEAD_BYTES) ahead. */
typedef struct {
  int file;          /* 1: job holds a file in the pool; 0: raw bytes in job.in */
  job_t job;
} item_t;
typedef struct {
  item_t *items;     /* a ring of n from first */
  int first, n, max, files, maxf;
  size_t bytes;
  void *pool;
} queue_t;

static void drop(queue_t *q, item_t *it) {
  if (it->file) {
    H.pool_wait(q->pool, &it->job);
    if (it->job.out) H.release(it->job.out);
    q->files--;
  }
  H.release((void *)it->job.in);
  q->bytes -= it->file ? it->job.expected : it->job.size;
  q->first = (q->first + 1) % q->max; q->n--;
}

/* the oldest item written; PMPA_E_DATA when its file did not come back
   (PMPA_E_VERSION when a later PMPA wrote its codec stream) */
static int retire_item(queue_t *q, out_t *o) {
  item_t *it = &q->items[q->first];
  int res = PMPA_OK;
  if (!it->file) put(o, it->job.in, it->job.size);
  else {
    H.pool_wait(q->pool, &it->job);
    if (!it->job.ok) res = it->job.cause == 1 ? PMPA_E_VERSION : it->job.cause == 2 ? PMPA_E_MEMORY : PMPA_E_DATA;
    else if (it->job.out_size != it->job.expected) res = PMPA_E_DATA;
    else put(o, it->job.out, it->job.out_size);
  }
  drop(q, it);
  return res;
}

int pmpafilter_decode(pmpa_read_fn read, void *read_ctx, pmpa_write_fn write, void *write_ctx, int threads) {
  if (!read || !write || !H.alloc) return PMPA_E_ARG;
  if (threads < 1) threads = 1;
  rd_t r = {read, read_ctx, 0, 0, 0, 0};
  out_t o = {write, write_ctx, 0};
  queue_t q = {0};
  q.maxf = 8 * threads; q.max = 2 * q.maxf + 2;
  r.buf = H.alloc(IOBUF);
  q.items = H.alloc(sizeof(item_t) * (size_t)q.max);
  q.pool = H.pool_open(threads, 0);
  int res = PMPA_E_DATA;
  if (!r.buf || !q.items || !q.pool) { res = PMPA_E_MEMORY; goto done; }
  /* the magic, then the version: one past this release's is a later PMPA's
     (PMPA_E_VERSION) */
  {
    for (size_t k = 0; k + 1 < sizeof MAGIC; k++) if (rd_byte(&r) != MAGIC[k]) goto done;
    int v = rd_byte(&r);
    if (v > MAGIC[4]) { res = PMPA_E_VERSION; goto done; }
    if (v != MAGIC[4]) goto done;
  }
  for (;;) {
    int t = rd_byte(&r);
    uint64_t n, size;
    if (t == TAG_END) {
      res = PMPA_OK;
      while (q.n && res == PMPA_OK && !o.err) res = retire_item(&q, &o);
      break;
    }
    /* room for one more item */
    int bad = 0;
    while (q.n && (q.n >= q.max - 1 || q.files >= q.maxf || q.bytes >= AHEAD_BYTES)) {
      int rr = retire_item(&q, &o);
      if (rr != PMPA_OK) { res = rr; bad = 1; break; }
    }
    if (bad || o.err) break;
    item_t *it = &q.items[(q.first + q.n) % q.max];
    if (t == TAG_RAW) {
      if (!rd_num(&r, &n) || !n || n > RAW_RUN) break;
      uint8_t *b = H.alloc((size_t)n);
      if (!b) { res = PMPA_E_MEMORY; break; }
      it->file = 0; it->job.in = b; it->job.size = (size_t)n; it->job.out = 0;
      q.n++; q.bytes += (size_t)n;
      if (rd(&r, b, (size_t)n) != n) break;
    } else if (t == TAG_FILE) {
      if (!rd_num(&r, &size) || !rd_num(&r, &n) || !size || size > MAX_FILE || !n || n >= size) break;
      uint8_t *st = H.alloc((size_t)n);
      if (!st) { res = PMPA_E_MEMORY; break; }
      it->file = 0; it->job.in = st; it->job.size = (size_t)n; it->job.expected = (size_t)size;
      it->job.out = 0; it->job.out_size = 0; it->job.ok = 0; it->job.done = 0; it->job.cause = 0;
      q.n++; q.bytes += (size_t)n;
      if (rd(&r, st, (size_t)n) != n) break;
      q.bytes += (size_t)size - (size_t)n;
      it->file = 1; q.files++;
      it->job.threads = threads / q.files; if (it->job.threads < 1) it->job.threads = 1;
      H.pool_submit(q.pool, &it->job);
    } else {
      /* 02 to FE: a record of a later PMPA; anything else (the end of the
         input) a data error */
      if (t >= 0x02 && t < TAG_END) res = PMPA_E_VERSION;
      break;
    }
  }
done:
  if (q.items) while (q.n) drop(&q, &q.items[q.first]);
  if (q.pool) H.pool_close(q.pool);
  if (q.items) H.release(q.items);
  if (r.buf) H.release(r.buf);
  if (r.err) return r.err;
  if (o.err) return o.err;
  return res;
}
