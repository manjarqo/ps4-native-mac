// SPDX-License-Identifier: GPL-2.0-or-later
//
// libSceJson2 (sce::Json, used by libSceNpCppWebApi and Sonic Origins' eboot).
//
// Every sce::Json object the guest holds (String, Value, Array, Object, on its stack, in its
// structures or returned by reference) is only used here through its first 8 bytes: the guest
// address of a node in guest memory, or 0. Nodes live in a small heap this module keeps in guest
// memory (json_alloc), so every reference handed to the guest (Value&, const String&,
// const Array&, const Object&) is a guest address, stable for as long as its container lives:
// array elements and object members are list nodes that never move. The real objects are at
// least 8 bytes, so the guest's own size for them is respected whatever it is.
//
//   String  [0] -> StrNode   {u64 length; char text[length + 1]}         (0: empty string)
//   Value   [0] -> ValNode   {u32 type; u32 pad; u64 scalar; String str; Array arr;
//                             Object obj}                              (0: null value)
//   Array   [0] -> ListNode  {u64 count; u64 head; u64 tail}            (0: empty array)
//               elements     {u64 next; Value value}
//   Object  [0] -> ListNode  {u64 count; u64 head; u64 tail}            (0: empty object)
//               members      {u64 next; String key; Value value}        (insertion order)
//
// ValueType numbering follows the SDK headers (kValueTypeNull 0, Boolean 1, Integer 2,
// UInteger 3, Real 4, String 5, Array 6, Object 7); the games seen here only test it against 0.
// Parser::parse reads RFC 8259 JSON (integers that fit int64 are Integer, larger non-negative
// ones UInteger, others Real); Value::serialize writes compact JSON. The parse error codes are
// not known from a reference: a malformed document returns JSON_ERROR_PARSE (negative) and leaves
// the value null.
//
// Lifecycle calls (Initializer, InitParameter2, MemAllocator) have nothing to set up: the nodes
// come from json_alloc, not from the guest's allocator.
#include "ps4_json2.h"
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    JT_NULL = 0,
    JT_BOOL = 1,
    JT_INT = 2,
    JT_UINT = 3,
    JT_REAL = 4,
    JT_STRING = 5,
    JT_ARRAY = 6,
    JT_OBJECT = 7,
};

#define JSON_ERROR_PARSE ((int32_t)0x80920001)
#define JSON_ERROR_INVALID_ARGUMENT ((int32_t)0x80920002)

// ValNode field offsets.
#define VN_TYPE 0
#define VN_SCALAR 8
#define VN_STR 16
#define VN_ARR 24
#define VN_OBJ 32
#define VN_SIZE 40
// List nodes.
#define LN_COUNT 0
#define LN_HEAD 8
#define LN_TAIL 16
#define LN_SIZE 24
#define AE_VALUE 8  // array element: next, Value
#define AE_SIZE 16
#define OM_KEY 8    // object member: next, String key, Value
#define OM_VALUE 16
#define OM_SIZE 24

// ---------------------------------------------------------------------------------------------
// Guest memory access
// ---------------------------------------------------------------------------------------------

static inline uint8_t *gp(GuestContext *ctx, uint64_t a) { return ctx->mem_base + a; }
static inline uint64_t rd64(GuestContext *ctx, uint64_t a) {
    uint64_t v;
    memcpy(&v, gp(ctx, a), 8);
    return v;
}
static inline void wr64(GuestContext *ctx, uint64_t a, uint64_t v) { memcpy(gp(ctx, a), &v, 8); }
static inline uint32_t rd32(GuestContext *ctx, uint64_t a) {
    uint32_t v;
    memcpy(&v, gp(ctx, a), 4);
    return v;
}
static inline void wr32(GuestContext *ctx, uint64_t a, uint32_t v) { memcpy(gp(ctx, a), &v, 4); }

// ---------------------------------------------------------------------------------------------
// Heap in guest memory: power-of-two size classes from 32 to 4096 bytes carved from 1 MiB
// arenas, larger blocks straight from the VM. A 16-byte header in front of each block keeps
// its class (or, for a large block, its mapped size).
// ---------------------------------------------------------------------------------------------

#define HEAP_HDR 16
#define HEAP_MIN_SHIFT 5
#define HEAP_MAX_SHIFT 12
#define HEAP_ARENA (1u << 20)
#define HEAP_BIG_FLAG (1ULL << 63)

static pthread_mutex_t g_heap_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_free_list[HEAP_MAX_SHIFT + 1];
static uint64_t g_arena_cur, g_arena_end;

static uint64_t json_alloc(GuestContext *ctx, uint64_t size) {
    const uint64_t need = size + HEAP_HDR;
    unsigned shift = HEAP_MIN_SHIFT;
    while (shift <= HEAP_MAX_SHIFT && (1ULL << shift) < need) shift++;
    uint64_t block = 0;
    if (shift > HEAP_MAX_SHIFT) {
        const uint64_t mapped = (need + 0xFFF) & ~0xFFFULL;
        block = recomp_vm_alloc(ctx, mapped);
        if (!block) return 0;
        wr64(ctx, block, mapped | HEAP_BIG_FLAG);
    } else {
        pthread_mutex_lock(&g_heap_lock);
        block = g_free_list[shift];
        if (block) {
            g_free_list[shift] = rd64(ctx, block + HEAP_HDR);
        } else {
            if (g_arena_cur + (1ULL << shift) > g_arena_end) {
                const uint64_t arena = recomp_vm_alloc(ctx, HEAP_ARENA);
                if (!arena) {
                    pthread_mutex_unlock(&g_heap_lock);
                    return 0;
                }
                g_arena_cur = arena;
                g_arena_end = arena + HEAP_ARENA;
            }
            block = g_arena_cur;
            g_arena_cur += 1ULL << shift;
        }
        pthread_mutex_unlock(&g_heap_lock);
        wr64(ctx, block, shift);
    }
    memset(gp(ctx, block + HEAP_HDR), 0, size);
    return block + HEAP_HDR;
}

static void json_free(GuestContext *ctx, uint64_t addr) {
    if (!addr) return;
    const uint64_t block = addr - HEAP_HDR;
    const uint64_t hdr = rd64(ctx, block);
    if (hdr & HEAP_BIG_FLAG) {
        recomp_vm_free(ctx, block, (size_t)(hdr & ~HEAP_BIG_FLAG));
        return;
    }
    pthread_mutex_lock(&g_heap_lock);
    wr64(ctx, addr, g_free_list[hdr]);
    g_free_list[hdr] = block;
    pthread_mutex_unlock(&g_heap_lock);
}

// ---------------------------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------------------------

static uint64_t str_node_new(GuestContext *ctx, const char *text, uint64_t len) {
    if (len == 0) return 0;
    const uint64_t n = json_alloc(ctx, 8 + len + 1);
    if (!n) return 0;
    wr64(ctx, n, len);
    memcpy(gp(ctx, n + 8), text, len);
    gp(ctx, n + 8)[len] = 0;
    return n;
}

// Sets the String object at `obj` to `text` (len bytes), freeing what it held.
static void str_set(GuestContext *ctx, uint64_t obj, const char *text, uint64_t len) {
    const uint64_t old = rd64(ctx, obj);
    wr64(ctx, obj, str_node_new(ctx, text, len));
    json_free(ctx, old);
}

static uint64_t str_len(GuestContext *ctx, uint64_t obj) {
    const uint64_t n = rd64(ctx, obj);
    return n ? rd64(ctx, n) : 0;
}

static const char *str_text(GuestContext *ctx, uint64_t obj) {
    const uint64_t n = rd64(ctx, obj);
    return n ? (const char *)gp(ctx, n + 8) : "";
}

static void str_copy(GuestContext *ctx, uint64_t dst, uint64_t src) {
    if (dst == src) return;
    const uint64_t n = rd64(ctx, src);
    str_set(ctx, dst, n ? (const char *)gp(ctx, n + 8) : "", n ? rd64(ctx, n) : 0);
}

// ---------------------------------------------------------------------------------------------
// Values, arrays, objects
// ---------------------------------------------------------------------------------------------

static void value_clear(GuestContext *ctx, uint64_t val);
static void value_copy(GuestContext *ctx, uint64_t dst, uint64_t src);

static void list_clear_array(GuestContext *ctx, uint64_t arr) {
    const uint64_t ln = rd64(ctx, arr);
    if (!ln) return;
    for (uint64_t e = rd64(ctx, ln + LN_HEAD); e;) {
        const uint64_t next = rd64(ctx, e);
        value_clear(ctx, e + AE_VALUE);
        json_free(ctx, e);
        e = next;
    }
    json_free(ctx, ln);
    wr64(ctx, arr, 0);
}

static void list_clear_object(GuestContext *ctx, uint64_t obj) {
    const uint64_t ln = rd64(ctx, obj);
    if (!ln) return;
    for (uint64_t m = rd64(ctx, ln + LN_HEAD); m;) {
        const uint64_t next = rd64(ctx, m);
        str_set(ctx, m + OM_KEY, "", 0);
        value_clear(ctx, m + OM_VALUE);
        json_free(ctx, m);
        m = next;
    }
    json_free(ctx, ln);
    wr64(ctx, obj, 0);
}

static uint64_t list_node(GuestContext *ctx, uint64_t container) {
    uint64_t ln = rd64(ctx, container);
    if (!ln) {
        ln = json_alloc(ctx, LN_SIZE);
        wr64(ctx, container, ln);
    }
    return ln;
}

static void list_append(GuestContext *ctx, uint64_t ln, uint64_t elem) {
    const uint64_t tail = rd64(ctx, ln + LN_TAIL);
    if (tail) wr64(ctx, tail, elem);
    else wr64(ctx, ln + LN_HEAD, elem);
    wr64(ctx, ln + LN_TAIL, elem);
    wr64(ctx, ln + LN_COUNT, rd64(ctx, ln + LN_COUNT) + 1);
}

static uint64_t list_count(GuestContext *ctx, uint64_t container) {
    const uint64_t ln = rd64(ctx, container);
    return ln ? rd64(ctx, ln + LN_COUNT) : 0;
}

// Appends a null element to the Array object `arr`; returns its Value object.
static uint64_t array_append(GuestContext *ctx, uint64_t arr) {
    const uint64_t e = json_alloc(ctx, AE_SIZE);
    list_append(ctx, list_node(ctx, arr), e);
    return e + AE_VALUE;
}

static void array_copy(GuestContext *ctx, uint64_t dst, uint64_t src) {
    if (dst == src) return;
    list_clear_array(ctx, dst);
    const uint64_t ln = rd64(ctx, src);
    if (!ln) return;
    for (uint64_t e = rd64(ctx, ln + LN_HEAD); e; e = rd64(ctx, e))
        value_copy(ctx, array_append(ctx, dst), e + AE_VALUE);
}

static uint64_t object_find(GuestContext *ctx, uint64_t obj, const char *key, uint64_t len) {
    const uint64_t ln = rd64(ctx, obj);
    if (!ln) return 0;
    for (uint64_t m = rd64(ctx, ln + LN_HEAD); m; m = rd64(ctx, m))
        if (str_len(ctx, m + OM_KEY) == len && memcmp(str_text(ctx, m + OM_KEY), key, len) == 0) return m + OM_VALUE;
    return 0;
}

// The member `key` of the Object object `obj`, created null when missing; returns its Value.
static uint64_t object_at(GuestContext *ctx, uint64_t obj, const char *key, uint64_t len) {
    const uint64_t found = object_find(ctx, obj, key, len);
    if (found) return found;
    const uint64_t m = json_alloc(ctx, OM_SIZE);
    str_set(ctx, m + OM_KEY, key, len);
    list_append(ctx, list_node(ctx, obj), m);
    return m + OM_VALUE;
}

static void object_copy(GuestContext *ctx, uint64_t dst, uint64_t src) {
    if (dst == src) return;
    list_clear_object(ctx, dst);
    const uint64_t ln = rd64(ctx, src);
    if (!ln) return;
    for (uint64_t m = rd64(ctx, ln + LN_HEAD); m; m = rd64(ctx, m))
        value_copy(ctx, object_at(ctx, dst, str_text(ctx, m + OM_KEY), str_len(ctx, m + OM_KEY)), m + OM_VALUE);
}

static uint32_t value_type(GuestContext *ctx, uint64_t val) {
    const uint64_t n = rd64(ctx, val);
    return n ? rd32(ctx, n + VN_TYPE) : JT_NULL;
}

// The node of the Value object `val`, created null when missing.
static uint64_t value_node(GuestContext *ctx, uint64_t val) {
    uint64_t n = rd64(ctx, val);
    if (!n) {
        n = json_alloc(ctx, VN_SIZE);
        wr64(ctx, val, n);
    }
    return n;
}

// Drops the payload of a node and gives it type `t` with its default content.
static void node_reset(GuestContext *ctx, uint64_t n, uint32_t t) {
    str_set(ctx, n + VN_STR, "", 0);
    list_clear_array(ctx, n + VN_ARR);
    list_clear_object(ctx, n + VN_OBJ);
    wr64(ctx, n + VN_SCALAR, 0);
    wr32(ctx, n + VN_TYPE, t);
}

static void value_clear(GuestContext *ctx, uint64_t val) {
    const uint64_t n = rd64(ctx, val);
    if (!n) return;
    node_reset(ctx, n, JT_NULL);
    json_free(ctx, n);
    wr64(ctx, val, 0);
}

static void value_set_type(GuestContext *ctx, uint64_t val, uint32_t t) { node_reset(ctx, value_node(ctx, val), t); }

static void value_set_scalar(GuestContext *ctx, uint64_t val, uint32_t t, uint64_t bits) {
    const uint64_t n = value_node(ctx, val);
    node_reset(ctx, n, t);
    wr64(ctx, n + VN_SCALAR, bits);
}

static void value_copy(GuestContext *ctx, uint64_t dst, uint64_t src) {
    if (dst == src) return;
    const uint64_t s = rd64(ctx, src);
    if (!s) {
        value_clear(ctx, dst);
        return;
    }
    const uint32_t t = rd32(ctx, s + VN_TYPE);
    const uint64_t d = value_node(ctx, dst);
    node_reset(ctx, d, t);
    wr64(ctx, d + VN_SCALAR, rd64(ctx, s + VN_SCALAR));
    if (t == JT_STRING) str_copy(ctx, d + VN_STR, s + VN_STR);
    else if (t == JT_ARRAY) array_copy(ctx, d + VN_ARR, s + VN_ARR);
    else if (t == JT_OBJECT) object_copy(ctx, d + VN_OBJ, s + VN_OBJ);
}

// Read-only objects handed out for a missing member / element or a value of another type: a null
// Value, an empty String, Array and Object, each an 8-byte zero in guest memory.
static uint64_t g_empty_slots;
static pthread_once_t g_empty_once = PTHREAD_ONCE_INIT;
static GuestContext *g_empty_ctx;
static void make_empty_slots(void) { g_empty_slots = json_alloc(g_empty_ctx, 32); }
static uint64_t empty_slot(GuestContext *ctx, int i) {
    g_empty_ctx = ctx;
    pthread_once(&g_empty_once, make_empty_slots);
    wr64(ctx, g_empty_slots + 8 * (uint64_t)i, 0); // the guest has no business writing there
    return g_empty_slots + 8 * (uint64_t)i;
}
#define EMPTY_VALUE 0
#define EMPTY_STRING 1
#define EMPTY_ARRAY 2
#define EMPTY_OBJECT 3

// ---------------------------------------------------------------------------------------------
// Parser (RFC 8259)
// ---------------------------------------------------------------------------------------------

typedef struct Parser {
    GuestContext *ctx;
    const char *p, *end;
    int depth;
    char *buf; // scratch for string contents
    size_t buf_cap;
} Parser;

#define PARSE_MAX_DEPTH 512

static void skip_ws(Parser *ps) {
    while (ps->p < ps->end && (*ps->p == ' ' || *ps->p == '\t' || *ps->p == '\n' || *ps->p == '\r')) ps->p++;
}

static bool buf_put(Parser *ps, size_t *len, const char *s, size_t n) {
    if (*len + n + 1 > ps->buf_cap) {
        size_t cap = ps->buf_cap ? ps->buf_cap * 2 : 256;
        while (cap < *len + n + 1) cap *= 2;
        char *nb = (char *)realloc(ps->buf, cap);
        if (!nb) return false;
        ps->buf = nb;
        ps->buf_cap = cap;
    }
    memcpy(ps->buf + *len, s, n);
    *len += n;
    return true;
}

static int hex4(const char *p) {
    int v = 0;
    for (int i = 0; i < 4; i++) {
        const char c = p[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
        else return -1;
    }
    return v;
}

// Parses a string at ps->p (on the opening quote) into ps->buf; returns its length or -1.
static long parse_string(Parser *ps) {
    if (ps->p >= ps->end || *ps->p != '"') return -1;
    ps->p++;
    size_t len = 0;
    while (ps->p < ps->end) {
        const unsigned char c = (unsigned char)*ps->p++;
        if (c == '"') {
            if (!buf_put(ps, &len, "", 0)) return -1;
            ps->buf[len] = 0;
            return (long)len;
        }
        if (c < 0x20) return -1;
        if (c != '\\') {
            if (!buf_put(ps, &len, (const char *)&c, 1)) return -1;
            continue;
        }
        if (ps->p >= ps->end) return -1;
        const char e = *ps->p++;
        char out = 0;
        switch (e) {
        case '"': out = '"'; break;
        case '\\': out = '\\'; break;
        case '/': out = '/'; break;
        case 'b': out = '\b'; break;
        case 'f': out = '\f'; break;
        case 'n': out = '\n'; break;
        case 'r': out = '\r'; break;
        case 't': out = '\t'; break;
        case 'u': {
            if (ps->end - ps->p < 4) return -1;
            int cp = hex4(ps->p);
            if (cp < 0) return -1;
            ps->p += 4;
            if (cp >= 0xD800 && cp <= 0xDBFF) { // surrogate pair
                if (ps->end - ps->p < 6 || ps->p[0] != '\\' || ps->p[1] != 'u') return -1;
                const int lo = hex4(ps->p + 2);
                if (lo < 0xDC00 || lo > 0xDFFF) return -1;
                ps->p += 6;
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                return -1;
            }
            char u[4];
            size_t n;
            if (cp < 0x80) {
                u[0] = (char)cp;
                n = 1;
            } else if (cp < 0x800) {
                u[0] = (char)(0xC0 | (cp >> 6));
                u[1] = (char)(0x80 | (cp & 0x3F));
                n = 2;
            } else if (cp < 0x10000) {
                u[0] = (char)(0xE0 | (cp >> 12));
                u[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
                u[2] = (char)(0x80 | (cp & 0x3F));
                n = 3;
            } else {
                u[0] = (char)(0xF0 | (cp >> 18));
                u[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
                u[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
                u[3] = (char)(0x80 | (cp & 0x3F));
                n = 4;
            }
            if (!buf_put(ps, &len, u, n)) return -1;
            continue;
        }
        default: return -1;
        }
        if (!buf_put(ps, &len, &out, 1)) return -1;
    }
    return -1;
}

static bool parse_value(Parser *ps, uint64_t val);

static bool parse_number(Parser *ps, uint64_t val) {
    const char *s = ps->p;
    const char *q = s;
    if (q < ps->end && *q == '-') q++;
    if (q >= ps->end) return false;
    if (*q == '0') {
        q++;
    } else if (*q >= '1' && *q <= '9') {
        while (q < ps->end && *q >= '0' && *q <= '9') q++;
    } else {
        return false;
    }
    bool real = false;
    if (q < ps->end && *q == '.') {
        real = true;
        q++;
        if (q >= ps->end || *q < '0' || *q > '9') return false;
        while (q < ps->end && *q >= '0' && *q <= '9') q++;
    }
    if (q < ps->end && (*q == 'e' || *q == 'E')) {
        real = true;
        q++;
        if (q < ps->end && (*q == '+' || *q == '-')) q++;
        if (q >= ps->end || *q < '0' || *q > '9') return false;
        while (q < ps->end && *q >= '0' && *q <= '9') q++;
    }
    char tmp[64];
    const size_t n = (size_t)(q - s);
    if (n >= sizeof(tmp)) real = true; // more digits than any integer type holds
    char *num = n < sizeof(tmp) ? tmp : (char *)malloc(n + 1);
    if (!num) return false;
    memcpy(num, s, n);
    num[n] = 0;
    ps->p = q;
    bool done = false;
    if (!real) {
        char *endp;
        errno = 0;
        if (num[0] == '-') {
            const long long v = strtoll(num, &endp, 10);
            if (!errno) {
                value_set_scalar(ps->ctx, val, JT_INT, (uint64_t)v);
                done = true;
            }
        } else {
            const unsigned long long v = strtoull(num, &endp, 10);
            if (!errno) {
                value_set_scalar(ps->ctx, val, v <= (unsigned long long)INT64_MAX ? JT_INT : JT_UINT, (uint64_t)v);
                done = true;
            }
        }
    }
    if (!done) {
        const double d = strtod(num, NULL);
        uint64_t bits;
        memcpy(&bits, &d, 8);
        value_set_scalar(ps->ctx, val, JT_REAL, bits);
    }
    if (num != tmp) free(num);
    return true;
}

static bool parse_literal(Parser *ps, const char *lit) {
    const size_t n = strlen(lit);
    if ((size_t)(ps->end - ps->p) < n || memcmp(ps->p, lit, n) != 0) return false;
    ps->p += n;
    return true;
}

static bool parse_value(Parser *ps, uint64_t val) {
    GuestContext *ctx = ps->ctx;
    skip_ws(ps);
    if (ps->p >= ps->end) return false;
    switch (*ps->p) {
    case '{': {
        if (++ps->depth > PARSE_MAX_DEPTH) return false;
        ps->p++;
        value_set_type(ctx, val, JT_OBJECT);
        const uint64_t obj = value_node(ctx, val) + VN_OBJ;
        skip_ws(ps);
        if (ps->p < ps->end && *ps->p == '}') {
            ps->p++;
            ps->depth--;
            return true;
        }
        for (;;) {
            skip_ws(ps);
            const long klen = parse_string(ps);
            if (klen < 0) return false;
            // The key is in ps->buf, which parsing the member's value reuses: store it first.
            const uint64_t member = object_at(ctx, obj, ps->buf, (uint64_t)klen);
            skip_ws(ps);
            if (ps->p >= ps->end || *ps->p != ':') return false;
            ps->p++;
            if (!parse_value(ps, member)) return false;
            skip_ws(ps);
            if (ps->p < ps->end && *ps->p == ',') {
                ps->p++;
                continue;
            }
            if (ps->p < ps->end && *ps->p == '}') {
                ps->p++;
                ps->depth--;
                return true;
            }
            return false;
        }
    }
    case '[': {
        if (++ps->depth > PARSE_MAX_DEPTH) return false;
        ps->p++;
        value_set_type(ctx, val, JT_ARRAY);
        const uint64_t arr = value_node(ctx, val) + VN_ARR;
        skip_ws(ps);
        if (ps->p < ps->end && *ps->p == ']') {
            ps->p++;
            ps->depth--;
            return true;
        }
        for (;;) {
            if (!parse_value(ps, array_append(ctx, arr))) return false;
            skip_ws(ps);
            if (ps->p < ps->end && *ps->p == ',') {
                ps->p++;
                continue;
            }
            if (ps->p < ps->end && *ps->p == ']') {
                ps->p++;
                ps->depth--;
                return true;
            }
            return false;
        }
    }
    case '"': {
        const long len = parse_string(ps);
        if (len < 0) return false;
        value_set_type(ctx, val, JT_STRING);
        str_set(ctx, value_node(ctx, val) + VN_STR, ps->buf, (uint64_t)len);
        return true;
    }
    case 't':
        if (!parse_literal(ps, "true")) return false;
        value_set_scalar(ctx, val, JT_BOOL, 1);
        return true;
    case 'f':
        if (!parse_literal(ps, "false")) return false;
        value_set_scalar(ctx, val, JT_BOOL, 0);
        return true;
    case 'n':
        if (!parse_literal(ps, "null")) return false;
        value_set_type(ctx, val, JT_NULL);
        return true;
    default: return parse_number(ps, val);
    }
}

// ---------------------------------------------------------------------------------------------
// Serializer (compact JSON)
// ---------------------------------------------------------------------------------------------

typedef struct Out {
    char *buf;
    size_t len, cap;
    bool oom;
} Out;

static void out_put(Out *o, const char *s, size_t n) {
    if (o->oom) return;
    if (o->len + n + 1 > o->cap) {
        size_t cap = o->cap ? o->cap * 2 : 256;
        while (cap < o->len + n + 1) cap *= 2;
        char *nb = (char *)realloc(o->buf, cap);
        if (!nb) {
            o->oom = true;
            return;
        }
        o->buf = nb;
        o->cap = cap;
    }
    memcpy(o->buf + o->len, s, n);
    o->len += n;
}

static void out_string(Out *o, const char *s, uint64_t n) {
    out_put(o, "\"", 1);
    for (uint64_t i = 0; i < n; i++) {
        const unsigned char c = (unsigned char)s[i];
        const char *esc = NULL;
        switch (c) {
        case '"': esc = "\\\""; break;
        case '\\': esc = "\\\\"; break;
        case '\b': esc = "\\b"; break;
        case '\f': esc = "\\f"; break;
        case '\n': esc = "\\n"; break;
        case '\r': esc = "\\r"; break;
        case '\t': esc = "\\t"; break;
        }
        if (esc) {
            out_put(o, esc, strlen(esc));
        } else if (c < 0x20) {
            char u[8];
            snprintf(u, sizeof(u), "\\u%04x", c);
            out_put(o, u, 6);
        } else {
            out_put(o, (const char *)&c, 1);
        }
    }
    out_put(o, "\"", 1);
}

static void out_value(GuestContext *ctx, Out *o, uint64_t val) {
    const uint64_t n = rd64(ctx, val);
    const uint32_t t = n ? rd32(ctx, n + VN_TYPE) : JT_NULL;
    char tmp[40];
    switch (t) {
    case JT_BOOL: out_put(o, rd64(ctx, n + VN_SCALAR) ? "true" : "false", rd64(ctx, n + VN_SCALAR) ? 4 : 5); break;
    case JT_INT: out_put(o, tmp, (size_t)snprintf(tmp, sizeof(tmp), "%lld", (long long)rd64(ctx, n + VN_SCALAR))); break;
    case JT_UINT:
        out_put(o, tmp, (size_t)snprintf(tmp, sizeof(tmp), "%llu", (unsigned long long)rd64(ctx, n + VN_SCALAR)));
        break;
    case JT_REAL: {
        const uint64_t bits = rd64(ctx, n + VN_SCALAR);
        double d;
        memcpy(&d, &bits, 8);
        if (!isfinite(d)) out_put(o, "null", 4); // JSON has no NaN / infinity
        else out_put(o, tmp, (size_t)snprintf(tmp, sizeof(tmp), "%.17g", d));
        break;
    }
    case JT_STRING: out_string(o, str_text(ctx, n + VN_STR), str_len(ctx, n + VN_STR)); break;
    case JT_ARRAY: {
        out_put(o, "[", 1);
        const uint64_t ln = rd64(ctx, n + VN_ARR);
        bool first = true;
        for (uint64_t e = ln ? rd64(ctx, ln + LN_HEAD) : 0; e; e = rd64(ctx, e)) {
            if (!first) out_put(o, ",", 1);
            first = false;
            out_value(ctx, o, e + AE_VALUE);
        }
        out_put(o, "]", 1);
        break;
    }
    case JT_OBJECT: {
        out_put(o, "{", 1);
        const uint64_t ln = rd64(ctx, n + VN_OBJ);
        bool first = true;
        for (uint64_t m = ln ? rd64(ctx, ln + LN_HEAD) : 0; m; m = rd64(ctx, m)) {
            if (!first) out_put(o, ",", 1);
            first = false;
            out_string(o, str_text(ctx, m + OM_KEY), str_len(ctx, m + OM_KEY));
            out_put(o, ":", 1);
            out_value(ctx, o, m + OM_VALUE);
        }
        out_put(o, "}", 1);
        break;
    }
    default: out_put(o, "null", 4); break;
    }
}

// ---------------------------------------------------------------------------------------------
// Guest ABI
// ---------------------------------------------------------------------------------------------

#define RET(v)                                                                                 \
    do {                                                                                       \
        ctx->rax = (uint64_t)(v);                                                              \
        SHIM_RETURN();                                                                         \
    } while (0)

// Lifecycle: nothing to set up (see the top of the file).
void shim__ZN3sce4Json12MemAllocatorC2Ev(GuestContext *ctx) { RET(0); }
void shim__ZN3sce4Json12MemAllocatorD2Ev(GuestContext *ctx) { RET(0); }
void shim__ZN3sce4Json14InitParameter2C1Ev(GuestContext *ctx) { RET(0); }
void shim__ZN3sce4Json14InitParameter212setAllocatorEPNS0_12MemAllocatorEPv(GuestContext *ctx) { RET(0); }
void shim__ZN3sce4Json14InitParameter217setFileBufferSizeEm(GuestContext *ctx) { RET(0); }
void shim__ZN3sce4Json11InitializerC1Ev(GuestContext *ctx) { RET(0); }
void shim__ZN3sce4Json11InitializerD1Ev(GuestContext *ctx) { RET(0); }
void shim__ZN3sce4Json11Initializer10initializeEPKNS0_14InitParameter2E(GuestContext *ctx) { RET(0); }
void shim__ZN3sce4Json11Initializer9terminateEv(GuestContext *ctx) { RET(0); }

// String
void shim__ZN3sce4Json6StringC1Ev(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    RET(0);
}
void shim__ZN3sce4Json6StringC1EPKc(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    if (ctx->rsi) {
        const char *s = (const char *)gp(ctx, ctx->rsi);
        str_set(ctx, ctx->rdi, s, strlen(s));
    }
    RET(0);
}
void shim__ZN3sce4Json6StringD1Ev(GuestContext *ctx) {
    str_set(ctx, ctx->rdi, "", 0);
    RET(0);
}
void shim__ZN3sce4Json6StringaSERKS1_(GuestContext *ctx) {
    str_copy(ctx, ctx->rdi, ctx->rsi);
    RET(ctx->rdi);
}
void shim__ZNK3sce4Json6String5c_strEv(GuestContext *ctx) {
    const uint64_t n = rd64(ctx, ctx->rdi);
    // An empty string's text: the zero 8 bytes of the empty-string slot.
    RET(n ? n + 8 : empty_slot(ctx, EMPTY_STRING));
}
void shim__ZNK3sce4Json6String6lengthEv(GuestContext *ctx) { RET(str_len(ctx, ctx->rdi)); }

// Value: constructors, destructor, assignment
void shim__ZN3sce4Json5ValueC1Ev(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    RET(0);
}
void shim__ZN3sce4Json5ValueD1Ev(GuestContext *ctx) {
    value_clear(ctx, ctx->rdi);
    RET(0);
}
void shim__ZN3sce4Json5ValueC1Eb(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    value_set_scalar(ctx, ctx->rdi, JT_BOOL, (ctx->rsi & 0xFF) ? 1 : 0);
    RET(0);
}
void shim__ZN3sce4Json5ValueC1El(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    value_set_scalar(ctx, ctx->rdi, JT_INT, ctx->rsi);
    RET(0);
}
void shim__ZN3sce4Json5ValueC1Ed(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    uint64_t bits;
    memcpy(&bits, &ctx->xmm[0].f64[0], 8);
    value_set_scalar(ctx, ctx->rdi, JT_REAL, bits);
    RET(0);
}
void shim__ZN3sce4Json5ValueC1EPKc(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    value_set_type(ctx, ctx->rdi, JT_STRING);
    if (ctx->rsi) {
        const char *s = (const char *)gp(ctx, ctx->rsi);
        str_set(ctx, rd64(ctx, ctx->rdi) + VN_STR, s, strlen(s));
    }
    RET(0);
}
void shim__ZN3sce4Json5ValueC1ERKNS0_6StringE(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    value_set_type(ctx, ctx->rdi, JT_STRING);
    str_copy(ctx, rd64(ctx, ctx->rdi) + VN_STR, ctx->rsi);
    RET(0);
}
void shim__ZN3sce4Json5ValueC1ERKNS0_6ObjectE(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    value_set_type(ctx, ctx->rdi, JT_OBJECT);
    object_copy(ctx, rd64(ctx, ctx->rdi) + VN_OBJ, ctx->rsi);
    RET(0);
}
void shim__ZN3sce4Json5ValueC1ERKNS0_5ArrayE(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    value_set_type(ctx, ctx->rdi, JT_ARRAY);
    array_copy(ctx, rd64(ctx, ctx->rdi) + VN_ARR, ctx->rsi);
    RET(0);
}
void shim__ZN3sce4Json5ValueaSERKS1_(GuestContext *ctx) {
    value_copy(ctx, ctx->rdi, ctx->rsi);
    RET(ctx->rdi);
}
void shim__ZN3sce4Json5Value3setENS0_9ValueTypeE(GuestContext *ctx) {
    const uint32_t t = (uint32_t)ctx->rsi;
    value_set_type(ctx, ctx->rdi, t <= JT_OBJECT ? t : JT_NULL);
    RET(0);
}
void shim__ZN3sce4Json5Value3setERKNS0_6ObjectE(GuestContext *ctx) {
    // Copy first: the Object may be a member of this value.
    const uint64_t tmp = json_alloc(ctx, 8);
    object_copy(ctx, tmp, ctx->rsi);
    value_set_type(ctx, ctx->rdi, JT_OBJECT);
    wr64(ctx, rd64(ctx, ctx->rdi) + VN_OBJ, rd64(ctx, tmp));
    json_free(ctx, tmp);
    RET(0);
}

// Value: accessors
void shim__ZNK3sce4Json5Value7getTypeEv(GuestContext *ctx) { RET(value_type(ctx, ctx->rdi)); }
void shim__ZNK3sce4Json5Value10getBooleanEv(GuestContext *ctx) {
    const uint64_t n = rd64(ctx, ctx->rdi);
    RET(n && rd32(ctx, n + VN_TYPE) == JT_BOOL && rd64(ctx, n + VN_SCALAR) ? 1 : 0);
}
void shim__ZNK3sce4Json5Value10getIntegerEv(GuestContext *ctx) {
    const uint64_t n = rd64(ctx, ctx->rdi);
    int64_t v = 0;
    if (n) {
        const uint64_t bits = rd64(ctx, n + VN_SCALAR);
        switch (rd32(ctx, n + VN_TYPE)) {
        case JT_BOOL:
        case JT_INT:
        case JT_UINT: v = (int64_t)bits; break;
        case JT_REAL: {
            double d;
            memcpy(&d, &bits, 8);
            v = (int64_t)d;
            break;
        }
        }
    }
    RET(v);
}
void shim__ZNK3sce4Json5Value7getRealEv(GuestContext *ctx) {
    const uint64_t n = rd64(ctx, ctx->rdi);
    double d = 0;
    if (n) {
        const uint64_t bits = rd64(ctx, n + VN_SCALAR);
        switch (rd32(ctx, n + VN_TYPE)) {
        case JT_REAL: memcpy(&d, &bits, 8); break;
        case JT_INT: d = (double)(int64_t)bits; break;
        case JT_UINT: d = (double)bits; break;
        }
    }
    ctx->xmm[0].f64[0] = d;
    RET(0);
}
void shim__ZNK3sce4Json5Value9getStringEv(GuestContext *ctx) {
    const uint64_t n = rd64(ctx, ctx->rdi);
    RET(n && rd32(ctx, n + VN_TYPE) == JT_STRING ? n + VN_STR : empty_slot(ctx, EMPTY_STRING));
}
void shim__ZNK3sce4Json5Value8getArrayEv(GuestContext *ctx) {
    const uint64_t n = rd64(ctx, ctx->rdi);
    RET(n && rd32(ctx, n + VN_TYPE) == JT_ARRAY ? n + VN_ARR : empty_slot(ctx, EMPTY_ARRAY));
}
void shim__ZNK3sce4Json5Value9getObjectEv(GuestContext *ctx) {
    const uint64_t n = rd64(ctx, ctx->rdi);
    RET(n && rd32(ctx, n + VN_TYPE) == JT_OBJECT ? n + VN_OBJ : empty_slot(ctx, EMPTY_OBJECT));
}
// refer*: the value's Array / Object to modify; a value of another type becomes an empty one.
void shim__ZN3sce4Json5Value10referArrayEv(GuestContext *ctx) {
    if (value_type(ctx, ctx->rdi) != JT_ARRAY) value_set_type(ctx, ctx->rdi, JT_ARRAY);
    RET(rd64(ctx, ctx->rdi) + VN_ARR);
}
void shim__ZN3sce4Json5Value11referObjectEv(GuestContext *ctx) {
    if (value_type(ctx, ctx->rdi) != JT_OBJECT) value_set_type(ctx, ctx->rdi, JT_OBJECT);
    RET(rd64(ctx, ctx->rdi) + VN_OBJ);
}
void shim__ZNK3sce4Json5ValueixEPKc(GuestContext *ctx) {
    const uint64_t n = rd64(ctx, ctx->rdi);
    uint64_t found = 0;
    if (n && rd32(ctx, n + VN_TYPE) == JT_OBJECT && ctx->rsi) {
        const char *key = (const char *)gp(ctx, ctx->rsi);
        found = object_find(ctx, n + VN_OBJ, key, strlen(key));
    }
    RET(found ? found : empty_slot(ctx, EMPTY_VALUE));
}
void shim__ZNK3sce4Json5ValueixEm(GuestContext *ctx) {
    const uint64_t n = rd64(ctx, ctx->rdi);
    uint64_t found = 0;
    if (n && rd32(ctx, n + VN_TYPE) == JT_ARRAY) {
        const uint64_t ln = rd64(ctx, n + VN_ARR);
        uint64_t i = 0;
        for (uint64_t e = ln ? rd64(ctx, ln + LN_HEAD) : 0; e; e = rd64(ctx, e), i++)
            if (i == ctx->rsi) {
                found = e + AE_VALUE;
                break;
            }
    }
    RET(found ? found : empty_slot(ctx, EMPTY_VALUE));
}
void shim__ZN3sce4Json5Value9serializeERNS0_6StringE(GuestContext *ctx) {
    Out o = {0};
    out_value(ctx, &o, ctx->rdi);
    if (o.oom) {
        free(o.buf);
        RET((uint64_t)(int64_t)JSON_ERROR_INVALID_ARGUMENT);
    }
    str_set(ctx, ctx->rsi, o.buf ? o.buf : "", o.len);
    free(o.buf);
    RET(0);
}

// Array
void shim__ZN3sce4Json5ArrayC1Ev(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    RET(0);
}
void shim__ZN3sce4Json5ArrayD1Ev(GuestContext *ctx) {
    list_clear_array(ctx, ctx->rdi);
    RET(0);
}
void shim__ZNK3sce4Json5Array4sizeEv(GuestContext *ctx) { RET(list_count(ctx, ctx->rdi)); }
void shim__ZNK3sce4Json5Array5emptyEv(GuestContext *ctx) { RET(list_count(ctx, ctx->rdi) == 0 ? 1 : 0); }
void shim__ZNK3sce4Json5Array4backEv(GuestContext *ctx) {
    const uint64_t ln = rd64(ctx, ctx->rdi);
    const uint64_t tail = ln ? rd64(ctx, ln + LN_TAIL) : 0;
    RET(tail ? tail + AE_VALUE : empty_slot(ctx, EMPTY_VALUE));
}
void shim__ZN3sce4Json5Array9push_backERKNS0_5ValueE(GuestContext *ctx) {
    // Copy into a fresh element first: the source may be an element of this array.
    const uint64_t tmp = json_alloc(ctx, 8);
    value_copy(ctx, tmp, ctx->rsi);
    const uint64_t slot = array_append(ctx, ctx->rdi);
    wr64(ctx, slot, rd64(ctx, tmp));
    json_free(ctx, tmp);
    RET(0);
}

// Object
void shim__ZN3sce4Json6ObjectC1Ev(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    RET(0);
}
void shim__ZN3sce4Json6ObjectC1ERKS1_(GuestContext *ctx) {
    wr64(ctx, ctx->rdi, 0);
    object_copy(ctx, ctx->rdi, ctx->rsi);
    RET(0);
}
void shim__ZN3sce4Json6ObjectD1Ev(GuestContext *ctx) {
    list_clear_object(ctx, ctx->rdi);
    RET(0);
}
void shim__ZN3sce4Json6Object5clearEv(GuestContext *ctx) {
    list_clear_object(ctx, ctx->rdi);
    RET(0);
}
void shim__ZNK3sce4Json6Object5emptyEv(GuestContext *ctx) { RET(list_count(ctx, ctx->rdi) == 0 ? 1 : 0); }
void shim__ZN3sce4Json6ObjectaSERKS1_(GuestContext *ctx) {
    object_copy(ctx, ctx->rdi, ctx->rsi);
    RET(ctx->rdi);
}
void shim__ZN3sce4Json6ObjectixERKNS0_6StringE(GuestContext *ctx) {
    RET(object_at(ctx, ctx->rdi, str_text(ctx, ctx->rsi), str_len(ctx, ctx->rsi)));
}

// int Parser::parse(Value &out, const char *buf, size_t size)
void shim__ZN3sce4Json6Parser5parseERNS0_5ValueEPKcm(GuestContext *ctx) {
    const uint64_t val = ctx->rdi;
    if (!val || (!ctx->rsi && ctx->rdx)) RET((uint64_t)(int64_t)JSON_ERROR_INVALID_ARGUMENT);
    Parser ps = {ctx, (const char *)gp(ctx, ctx->rsi), (const char *)gp(ctx, ctx->rsi) + ctx->rdx, 0, NULL, 0};
    // The text may end at a NUL before `size`.
    const void *nul = memchr(ps.p, 0, (size_t)ctx->rdx);
    if (nul) ps.end = (const char *)nul;
    value_clear(ctx, val);
    bool ok = parse_value(&ps, val);
    if (ok) {
        skip_ws(&ps);
        ok = ps.p == ps.end;
    }
    free(ps.buf);
    if (!ok) {
        value_clear(ctx, val);
        RET((uint64_t)(int64_t)JSON_ERROR_PARSE);
    }
    RET(0);
}
