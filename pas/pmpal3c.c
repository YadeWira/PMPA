/* PMPA's hot loop in C: stream version 6's model of a Layer III granule's
   values (pmpacodec.pas's CodeValues4, its version 6 path), the same
   arithmetic bit for bit.

   It takes no memory and calls no library: pmpac.pas hands it the counters,
   the mixer's weights, the APM, the adaptive bits, the tables and the
   coder's state, and two callbacks carry bytes in and out of pmpaarith's
   coder. Everything is 32-bit integer arithmetic, as in Pascal; -fwrapv
   (pas/build_c.sh) makes the hashes' wrapping defined. The suite checks
   that this and the Pascal write the same streams (PMPA_NOC=1). */

#include <stdint.h>
#include <stddef.h>


typedef struct { uint16_t p; uint8_t n; uint8_t pad; } counter_t;   /* TCounter, TAdaptiveBit */

/* the encoder: its interval and where its bytes go */
#define EBUF 4096
typedef struct {
    uint32_t x1, x2;
    void *ctx;                              /* pmpaarith's TArithEncoder */
    intptr_t n;                             /* bytes in buf */
    uint8_t buf[EBUF];
} enc_t;

/* the decoder: its interval, and its bytes (an array, or a live stream) */
typedef struct {
    uint32_t x1, x2, x;
    const uint8_t *d;
    intptr_t len, p;
    void *live;                             /* a TLiveStream, or NULL */
} dec_t;

typedef struct {
    void (*put)(void *ctx, const uint8_t *b, intptr_t n);
    uint32_t (*get)(void *live, intptr_t p);
    const int16_t *stretch;                 /* 4096 */
    const int32_t *recip;                   /* pmpamodel's RECIP, 1024 */
    const int32_t *reciprocal;              /* pmpaarith's RECIPROCAL, 256 */
} tables_t;

static tables_t T;
static int16_t SQUASH_T[4095];              /* squash(d) for d = -2047..2047 */

static int32_t squash_calc(int32_t d);

void pmpac_tables(const tables_t *t)
{
    int32_t d;
    T = *t;
    for (d = -2047; d <= 2047; d++) SQUASH_T[d + 2047] = (int16_t)squash_calc(d);
}

/* ---------- the coder ---------- */

static uint32_t split(uint32_t x1, uint32_t x2, int32_t p)
{
    if (p < 1) p = 1; else if (p > 65535) p = 65535;
    return x1 + (uint32_t)(((uint64_t)(x2 - x1) * (uint32_t)p) >> 16);
}

static void enc_bit(enc_t *e, int bit, int32_t p)
{
    uint32_t xm = split(e->x1, e->x2, p);
    if (bit) e->x2 = xm; else e->x1 = xm + 1;
    while (((e->x1 ^ e->x2) & 0xFF000000u) == 0) {
        if (e->n == EBUF) { T.put(e->ctx, e->buf, e->n); e->n = 0; }
        e->buf[e->n++] = (uint8_t)(e->x2 >> 24);
        e->x1 <<= 8;
        e->x2 = (e->x2 << 8) | 255;
    }
}

static int dec_bit(dec_t *c, int32_t p)
{
    uint32_t xm = split(c->x1, c->x2, p);
    int r;
    uint32_t b;
    if (c->x <= xm) { r = 1; c->x2 = xm; } else { r = 0; c->x1 = xm + 1; }
    while (((c->x1 ^ c->x2) & 0xFF000000u) == 0) {
        c->x1 <<= 8;
        c->x2 = (c->x2 << 8) | 255;
        if (c->live) b = T.get(c->live, c->p);
        else if (c->p >= 0 && c->p < c->len) b = c->d[c->p];
        else b = 0;
        c->p++;
        c->x = (c->x << 8) | b;
    }
    return r;
}

/* ---------- the model's pieces, as pmpamodel and pmpaarith have them ---------- */

static const int32_t SQUASH_POINTS[33] = {
    1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546,
    2047, 2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079,
    4085, 4089, 4092, 4093, 4094 };

static int32_t squash_calc(int32_t d)
{
    int32_t w, r;
    if (d > 2047) return 4095;
    if (d < -2047) return 1;
    w = d & 127;
    d = (d >> 7) + 16;
    r = (SQUASH_POINTS[d] * (128 - w) + SQUASH_POINTS[d + 1] * w + 64) >> 7;
    return r < 1 ? 1 : r;
}

/* squash, by the table pmpac_tables fills */
static int32_t squash(int32_t d)
{
    if (d > 2047) return 4095;
    if (d < -2047) return 1;
    return SQUASH_T[d + 2047];
}

/* the mixer's dot product and training over n lanes:
   dot = sum of (x[i] * w[i]) >> 16; w[i] += (x[i] * err) >> 14, clamped to
   +-W_MAX. (SSE4.1 was tried for these: with 9 lanes, slower, 01/11/2026.) */
#define W_MAX (1 << 19)

static int32_t dot(const int32_t *x, const int32_t *w, int n)
{
    int32_t r = 0;
    int i;
    for (i = 0; i < n; i++) r += (x[i] * w[i]) >> 16;
    return r;
}

static void train(const int32_t *x, int32_t *w, int n, int32_t err)
{
    int i;
    for (i = 0; i < n; i++) {
        int32_t wi = w[i] + ((x[i] * err) >> 14);
        if (wi > W_MAX) wi = W_MAX; else if (wi < -W_MAX) wi = -W_MAX;
        w[i] = wi;
    }
}

static void counter_update(counter_t *c, int bit, int limit)
{
    int32_t target = bit ? 65535 : 0;
    c->p = (uint16_t)(c->p + ((int32_t)(target - c->p) * T.recip[c->n] >> 10));
    if (c->n < limit) c->n++;
}

/* pmpaarith's TAdaptiveBit.Update */
static void abit_update(counter_t *a, int bit, int limit)
{
    int32_t target = bit ? 65535 : 1;
    int64_t q = (int64_t)(target - a->p) * T.reciprocal[a->n];
    q = (q + ((q >> 63) & 0xFFFF)) >> 16;
    a->p = (uint16_t)(a->p + q);
    if (a->n < limit && a->n < 255) a->n++;
}

static uint32_t hash2(uint32_t a, uint32_t b)
{
    uint32_t r = (a * 0x9E3779B1u) ^ (b * 0x85EBCA77u);
    r ^= r >> 15;
    r *= 0xC2B2AE3Du;
    r ^= r >> 13;
    return r;
}
static uint32_t hash3(uint32_t a, uint32_t b, uint32_t c) { return hash2(hash2(a, b), c); }
static uint32_t hash4(uint32_t a, uint32_t b, uint32_t c, uint32_t d) { return hash2(hash2(hash2(a, b), c), d); }

static int bitlen(int32_t v) { int r = 0; while (v > 0) { r++; v >>= 1; } return r; }

/* ---------- a granule's values ---------- */

#define V_LIMIT 255
#define LIMIT_STRUCT 127
#define LIMIT_BYTES 60
#define N_IN 8
#define EST_BUCKETS 14

typedef struct {
    int32_t *v;                     /* the 576 values, in or out */
    const int32_t *pv;              /* the same channel's granule before */
    const int32_t *ov;              /* the other channel's this granule, or NULL */
    const int32_t *steps, *prevStep;
    const int8_t *cap, *cls, *lin;  /* by position: the table's limit, class, linbits; cls -1: table 0 */
    int32_t bigEnd, end, dg;
    counter_t *vt; uint32_t vtMask;
    int32_t *w; int32_t inputs, rate;           /* the mixer: weights by set */
    int32_t *apm; int32_t apmRate;
    counter_t *sign4;               /* [3][3][4] */
    counter_t *linLen;              /* [1..15]: element 0 is linLen[1] */
    counter_t *linLow;              /* [0..12] */
    int32_t decoding;
    enc_t *enc;
    dec_t *dec;
} values_t;

static int code_bit(values_t *s, int bit, int32_t p)
{
    if (s->decoding) return dec_bit(s->dec, p);
    enc_bit(s->enc, bit, p);
    return bit;
}

static int abit(values_t *s, int bit, counter_t *a, int limit)
{
    int r = code_bit(s, bit, a->p);
    abit_update(a, r, limit);
    return r;
}

/* DecideApm: 8 counters and a bias mixed with set `sel`, the APM in actx */
static int decide(values_t *s, int bit, const uint32_t *hs, int sel, int actx)
{
    counter_t *cp[N_IN];
    int32_t x[12] = {0}, *w = s->w + sel * s->inputs;
    int32_t pr, st, wt, idx, pa, p, err, target, i, r;
    for (i = 0; i < N_IN; i++) {
        cp[i] = &s->vt[hs[i] & s->vtMask];
        x[i] = T.stretch[cp[i]->p >> 4];
    }
    x[N_IN] = 256;
    /* pmpamodel's mixer goes on to 12 lanes, the 3 past the inputs at x = 0:
       their weights neither add nor move, so 9 give the same */
    pr = squash(dot(x, w, N_IN + 1));
    /* the APM */
    st = T.stretch[pr] + 2048;
    wt = st & 127;
    idx = actx * 33 + (st >> 7);
    pa = (s->apm[idx] * (128 - wt) + s->apm[idx + 1] * wt) >> 11;
    if (wt >= 64) idx++;
    if (pa < 1) pa = 1; else if (pa > 4095) pa = 4095;
    p = (pr + 3 * pa) * 4;
    if (p < 1) p = 1; else if (p > 65535) p = 65535;
    r = code_bit(s, bit, p);
    /* the mixer, the APM, the counters */
    err = ((r << 12) - pr) * s->rate;
    train(x, w, N_IN + 1, err);
    target = r ? 65535 : 0;
    s->apm[idx] += (target - s->apm[idx]) >> s->apmRate;
    for (i = 0; i < N_IN; i++) counter_update(cp[i], r, V_LIMIT);
    return r;
}

/* one decision of a value: each context's line of 16 counters, at slot */
static int decide_slot(values_t *s, const uint32_t *base, int id, int slot, int b, int cls, int est)
{
    uint32_t hs[N_IN];
    int j;
    for (j = 0; j < N_IN; j++) hs[j] = (base[j] & 0xFFFFFFF0u) | (uint32_t)slot;
    return decide(s, b, hs, id * 8 + cls, (id * 8 + cls) * EST_BUCKETS + est);
}

static int cap15(int32_t n) { return n > 15 ? 15 : n; }
static int min3(int32_t n) { return n > 3 ? 3 : n; }
static int min7(int32_t n) { return n > 7 ? 7 : n; }
static int32_t iabs(int32_t n) { return n < 0 ? -n : n; }
static int sgn3(int32_t n) { return n == 0 ? 0 : n > 0 ? 1 : 2; }

static int nb_bucket(int n)
{
    if (n < 3) return n;
    if (n < 5) return 3;
    if (n < 8) return 4;
    if (n < 13) return 5;
    if (n < 24) return 6;
    return 7;
}

static int est_bucket(int n)
{
    int b, r;
    if (n < 4) return n;
    b = bitlen(n);
    r = 2 * b - 2 + ((n >> (b - 2)) & 1);
    return r > 13 ? 13 : r;
}

/* 1 if the values were coded, 0 if a decoded escape is longer than its
   table allows (a damaged stream) */
int32_t pmpac_values(values_t *s)
{
    int32_t *v = s->v;
    const int32_t *pv = s->pv, *ov = s->ov;
    uint32_t base[N_IN];
    int i, cls, cap, lin, n1, n2, p0, pn, oc, pos, nbb, ds, sa, dist, est, a, k, L, maxL, bit, e, n, node, so, sb;

    for (i = 0; i < 576; i++) {
        if (i >= s->end || s->cls[i] < 0) { v[i] = 0; continue; }
        cls = s->cls[i]; cap = s->cap[i]; lin = s->lin[i];
        n1 = i > 0 ? cap15(iabs(v[i - 1])) : 0;
        n2 = i > 1 ? cap15(iabs(v[i - 2])) : 0;
        p0 = cap15(iabs(pv[i]));
        pn = 2 * p0;
        if (i > 0) pn += cap15(iabs(pv[i - 1]));
        if (i < 575) pn += cap15(iabs(pv[i + 1]));
        if (pn > 31) pn = 31;
        oc = ov ? cap15(iabs(ov[i])) : 16;
        pos = i >> 2;
        nbb = nb_bucket(2 * n1 + n2);
        ds = s->steps[i] - s->prevStep[i];
        if (ds < -8) ds = -8; else if (ds > 8) ds = 8;
        ds += 8;
        /* Pascal's div truncates toward zero */
        sa = s->steps[i] / 4;
        if (sa < 0) sa = 0; else if (sa > 63) sa = 63;
        dist = bitlen(i < s->bigEnd ? s->bigEnd - i : s->end - i);
        est = 4 * n1 + 2 * n2 + 3 * p0;
        if (i > 0) est += cap15(iabs(pv[i - 1]));
        if (i < 575) est += cap15(iabs(pv[i + 1]));
        if (oc < 16) est += 2 * oc;
        est = est_bucket(est);
        a = s->decoding ? 0 : iabs(v[i]);
        base[0] = hash4(1, cls, n1, n2);
        base[1] = hash4(2, cls, pn, nbb);
        base[2] = hash3(3, cls, pos);
        base[3] = hash4(4, cls, oc, min3(n1));
        base[4] = hash4(5, cls, s->dg * 16 + min7(p0), min3(n1));
        base[5] = hash4(7, cls, ds, min3(p0) * 4 + min3(n1));
        base[6] = hash4(8, cls, sa, pos >> 3);
        base[7] = hash4(9, cls, dist, min3(n1) * 4 + min3(p0));

#define D(id, slot, b) decide_slot(s, base, (id), (slot), (b), cls, est)

        if (D(0, 0, a > 0) == 0) k = 0;
        else {
            maxL = bitlen(cap);
            L = 1;
            while (L < maxL && D(L, L, bitlen(cap15(a)) > L) == 1) L++;
            k = 1;
            for (bit = L - 2; bit >= 0; bit--) {
                int id = 4 + (L - 2) * (L - 1) / 2 + (L - 2 - bit), slot;
                switch (id) {
                    case 4: case 5: slot = id; break;
                    case 6: slot = 6 + k - 2; break;
                    case 7: slot = 8; break;
                    case 8: slot = 9 + k - 2; break;
                    default: slot = 11 + k - 4;
                }
                k = k * 2 + D(id, slot, (cap15(a) >> bit) & 1);
            }
            if (k > cap) return 0;
        }
#undef D
        if (lin > 0 && k == 15) {
            e = a - 15;
            n = 0;
            if (!s->decoding) while ((e >> n) > 0) n++;
            node = 1;
            for (bit = 3; bit >= 0; bit--)
                node = node * 2 + abit(s, (n >> bit) & 1, &s->linLen[node - 1], LIMIT_STRUCT);
            n = node - 16;
            if (n > lin) return 0;
            if (n == 0) e = 0;
            else {
                e = 1;
                for (bit = n - 2; bit >= 0; bit--)
                    e = e * 2 + abit(s, ((a - 15) >> bit) & 1, &s->linLow[bit], LIMIT_BYTES);
            }
            k = 15 + e;
        }
        if (k == 0) v[i] = 0;
        else {
            so = ov ? sgn3(ov[i]) : 0;
            sb = i > 0 ? sgn3(v[i - 1]) : 0;
            if (abit(s, v[i] < 0, &s->sign4[(so * 3 + sb) * 4 + min3(k)], LIMIT_BYTES)) v[i] = -k;
            else v[i] = k;
        }
    }
    return 1;
}

/* ---------- Layer I and II's samples (stream version 6) ---------- */

#define L_IN 6

typedef struct {
    int32_t *smp;                   /* this channel and subband's samples (codes), n of them */
    const int32_t *last;            /* the last frame's, centred, or NULL */
    const int32_t *other;           /* channel 0's codes in this subband, or NULL */
    const int32_t *scf;             /* the 3 scale factors */
    int32_t n, layer, levels, bits, mid, top, ci, sb, otherMid;
    counter_t *vt; uint32_t vtMask;
    int32_t *w; int32_t inputs, rate;           /* lmix */
    counter_t *oddCode;
    counter_t *fieldsOdd;           /* [512][2][2] */
    int32_t decoding;
    enc_t *enc;
    dec_t *dec;
} samples_t;

static int l_bit(samples_t *s, int bit, int32_t p)
{
    if (s->decoding) return dec_bit(s->dec, p);
    enc_bit(s->enc, bit, p);
    return bit;
}

static int l_abit(samples_t *s, int bit, counter_t *a, int limit)
{
    int r = l_bit(s, bit, a->p);
    abit_update(a, r, limit);
    return r;
}

/* Decide: 6 counters and a bias, mixed with set `sel`, no APM */
static int l_decide(samples_t *s, int bit, const uint32_t *hs, int sel)
{
    counter_t *cp[L_IN];
    int32_t x[8] = {0}, *w = s->w + sel * s->inputs;
    int32_t pr, p, err, i, r;
    for (i = 0; i < L_IN; i++) {
        cp[i] = &s->vt[hs[i] & s->vtMask];
        x[i] = T.stretch[cp[i]->p >> 4];
    }
    x[L_IN] = 256;
    pr = squash(dot(x, w, L_IN + 1));
    p = pr * 16;
    if (p < 1) p = 1; else if (p > 65535) p = 65535;
    r = l_bit(s, bit, p);
    err = ((r << 12) - pr) * s->rate;
    train(x, w, L_IN + 1, err);
    for (i = 0; i < L_IN; i++) counter_update(cp[i], r, V_LIMIT);
    return r;
}

/* CodeField with prev 0, for a code word above its levels */
static int l_field(samples_t *s, int v, int nbits)
{
    int i, b, node = 1, same = 1, ctx, r = 0;
    for (i = nbits - 1; i >= 0; i--) {
        ctx = node < 256 ? node : 256 + i;
        b = l_abit(s, (v >> i) & 1, &s->fieldsOdd[(ctx * 2 + 0) * 2 + same], LIMIT_STRUCT);
        r = r * 2 + b;
        if (node < 256) node = node * 2 + b;
        if (b != 0) same = 0;
    }
    return r;
}

static int slog(int32_t v)
{
    int b;
    if (v == 0) return 8;
    b = bitlen(iabs(v) - 1) + 1;
    if (b > 8) b = 8;
    return v > 0 ? 8 + b : 8 - b;
}

static int l_d(samples_t *s, const uint32_t *c, int id, int prefix, int b)
{
    uint32_t hs[L_IN], key = (uint32_t)(((uint64_t)(id * 256 + prefix + 1) * 0x9E3779B1u) & 0xFFFFFFFFu);
    int i;
    for (i = 0; i < 5; i++) hs[i] = c[i] ^ key;
    hs[5] = ((uint32_t)s->ci * 7919u) ^ key;
    if (id > 3) id = 3;
    return l_decide(s, b, hs, 32 + s->ci * 4 + id);
}

/* CodeSample: zero, sign, bit length, the bits below the top one */
static int l_sample(samples_t *s, int32_t x, const uint32_t *c)
{
    int a = iabs(x), L, maxL, bit, k, sg;
    if (l_d(s, c, 0, 0, a > 0) == 0) return 0;
    sg = l_d(s, c, 1, 0, x < 0);
    maxL = bitlen(s->top);
    L = 1;
    while (L < maxL && l_d(s, c, 2, L, bitlen(a) > L) == 1) L++;
    k = 1;
    for (bit = L - 2; bit >= 0; bit--) k = k * 2 + l_d(s, c, 3 + L, k & 255, (a >> bit) & 1);
    return sg ? -k : k;
}

static int32_t before(samples_t *s, int i, int k)
{
    if (i - k >= 0) return s->smp[i - k] < 0 ? 0 : s->smp[i - k] - s->mid;
    if (s->last) return s->last[s->n + i - k];
    return 0;
}

/* one channel and subband's samples; 1 if coded, 0 if a decoded one is
   out of range (a damaged stream) */
int32_t pmpac_samples(samples_t *s)
{
    int i = 0, x1, x2, xo, x, odd;
    uint32_t c[5];
    int grouped = s->layer == 2 && s->levels > 0;
    while (i < s->n) {
        if (grouped && i % 3 == 0) {
            odd = l_abit(s, s->smp[i + 1] < 0, s->oddCode, LIMIT_STRUCT);
            if (odd) {
                s->smp[i] = l_field(s, s->smp[i], s->bits);
                if (s->smp[i] < s->levels * s->levels * s->levels) return 0;
                s->smp[i + 1] = -1; s->smp[i + 2] = -1;
                i += 3;
                continue;
            }
        }
        x1 = before(s, i, 1); x2 = before(s, i, 2);
        xo = (s->other && s->other[i] >= 0) ? slog(s->other[i] - s->otherMid) : 99;
        c[0] = hash4(s->ci, slog(x1), slog(x2), 1);
        c[1] = hash4(s->ci, slog(2 * x1 - x2), s->sb >> 2, 2);
        c[2] = hash4(s->ci, s->sb, min7(iabs(x1)), min7(iabs(x2)));
        c[3] = hash4(s->ci, xo, slog(x1), 4);
        c[4] = hash4(s->ci, s->scf[i * 3 / s->n] >> 2, min7(iabs(x1)), 5);
        x = s->decoding ? 0 : s->smp[i] - s->mid;
        x = l_sample(s, x, c);
        if (x + s->mid < 0 || x + s->mid > 2 * s->mid + 1 || (grouped && x + s->mid >= s->levels)) return 0;
        s->smp[i] = x + s->mid;
        i++;
    }
    return 1;
}

/* the structs' layout, for pmpac.pas to compare with its records before it
   uses any of this: 0 sizeof(values_t), 1 its dg, 2 its vt, 3 its dec,
   4 sizeof(enc_t), 5 enc_t's buf, 6 sizeof(dec_t), 7 dec_t's live,
   8 sizeof(tables_t), 9 sizeof(counter_t), 10 sizeof(samples_t), 11 its
   vt, 12 its dec */
int32_t pmpac_layout(int32_t k)
{
    switch (k) {
        case 0: return (int32_t)sizeof(values_t);
        case 1: return (int32_t)offsetof(values_t, dg);
        case 2: return (int32_t)offsetof(values_t, vt);
        case 3: return (int32_t)offsetof(values_t, dec);
        case 4: return (int32_t)sizeof(enc_t);
        case 5: return (int32_t)offsetof(enc_t, buf);
        case 6: return (int32_t)sizeof(dec_t);
        case 7: return (int32_t)offsetof(dec_t, live);
        case 8: return (int32_t)sizeof(tables_t);
        case 9: return (int32_t)sizeof(counter_t);
        case 10: return (int32_t)sizeof(samples_t);
        case 11: return (int32_t)offsetof(samples_t, vt);
        case 12: return (int32_t)offsetof(samples_t, dec);
    }
    return -1;
}

/* ---------- the compiler, for pmpa --version and report ---------- */

#define PMPA_STR2(x) #x
#define PMPA_STR(x) PMPA_STR2(x)

const char *pmpac_compiler(void)
{
#if defined(__clang__)
  return "clang " PMPA_STR(__clang_major__) "." PMPA_STR(__clang_minor__) "." PMPA_STR(__clang_patchlevel__);
#elif defined(__GNUC__)
  return "gcc " PMPA_STR(__GNUC__) "." PMPA_STR(__GNUC_MINOR__) "." PMPA_STR(__GNUC_PATCHLEVEL__);
#else
  return "unknown";
#endif
}
