// Host test of libSceJson2 (ps4_json2.c) through the guest ABI, on guest memory managed by the
// runtime's VM (recomp_runtime.c):
//  - Parser::parse of a document with nested objects and arrays, escapes, \u escapes (with a
//    surrogate pair), negative / large / real / exponent numbers, true / false / null; the
//    values read back with operator[], getType, getInteger, getReal (xmm0), getBoolean,
//    getString + c_str, getArray + size / back, getObject + empty;
//  - every reference returned is a guest address, inside guest memory;
//  - building a document with Object::operator[], Value::operator=, Array::push_back,
//    Value(Object), Value(Array), Value::set(Object) (from one of its own members), referArray,
//    and Value::serialize to compact JSON in insertion order (parse(serialize(x)) == x);
//  - copies are deep: Object(const Object&) and operator= leave the source untouched;
//  - malformed documents (trailing comma, unterminated string, bad escape, trailing text,
//    lone surrogate) fail and leave the value null; a text that ends at a NUL before `size`;
//  - 20000 parse / destroy rounds stay inside a 64 MiB VM (the heap reuses freed nodes).
#include "ps4_json2.h"

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "runtime_stubs.h"

// Direct-memory hooks of the VM code (ps4_direct_mem.c is not linked: the test maps no direct memory).
void ps4_direct_mem_destroy(void) {}
void ps4_direct_mem_configure(GuestContext *ctx, uint64_t proc_param_addr) {
  (void)ctx;
  (void)proc_param_addr;
}
void ps4_direct_mem_on_unmap(GuestContext *ctx, uint64_t addr, size_t size) {
  (void)ctx;
  (void)addr;
  (void)size;
}

static int g_failures;
#define CHECK(cond, ...)                                                       \
  do {                                                                         \
    if (!(cond)) {                                                             \
      printf("FAIL line %d: %s  ", __LINE__, #cond);                           \
      printf(__VA_ARGS__);                                                     \
      printf("\n");                                                            \
      g_failures++;                                                            \
    }                                                                          \
  } while (0)

#define MEM_SIZE (1ULL << 30)
#define VM_START 0x10000000ULL
#define VM_SIZE (64ULL << 20)

enum { T_NULL, T_BOOL, T_INT, T_UINT, T_REAL, T_STRING, T_ARRAY, T_OBJECT };

static GuestContext *g;
static uint64_t g_scratch = 0x100000; // guest objects of the test (below the VM range)

static GuestContext *new_ctx(void) {
  GuestContext *ctx = (GuestContext *)calloc(1, sizeof(GuestContext));
  void *mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
  if (mem == MAP_FAILED) {
    perror("mmap");
    exit(2);
  }
  ctx->mem_base = (uint8_t *)mem;
  ctx->mem_size = MEM_SIZE;
  ctx->process_ctx = ctx;
  pthread_mutex_init(&ctx->vm_mutex, NULL);
  GuestVMExtent *root = (GuestVMExtent *)calloc(1, sizeof(GuestVMExtent));
  root->addr = VM_START;
  root->size = VM_SIZE;
  root->is_free = true;
  ctx->vm_extents = root;
  return ctx;
}

// A guest object of the test: 64 bytes, as large as any real sce::Json object.
static uint64_t obj(void) {
  const uint64_t a = g_scratch;
  g_scratch += 64;
  memset(g->mem_base + a, 0xCC, 64);
  return a;
}
static uint64_t gstr(const char *s) {
  const uint64_t a = g_scratch;
  g_scratch += (strlen(s) + 16) & ~15ULL;
  strcpy((char *)g->mem_base + a, s);
  return a;
}

static uint64_t call(void (*fn)(GuestContext *), uint64_t a, uint64_t b, uint64_t c) {
  g->rdi = a;
  g->rsi = b;
  g->rdx = c;
  g->rax = 0xdeadbeefdeadbeefULL;
  g->rsp = 0x8000;
  fn(g);
  if (g->rsp != 0x8008) {
    printf("FAIL: shim did not return through SHIM_RETURN\n");
    exit(1);
  }
  return g->rax;
}

static bool in_guest(uint64_t a) { return a && a < MEM_SIZE; }

static int32_t parse(uint64_t val, const char *text) {
  const uint64_t t = gstr(text);
  return (int32_t)call(shim__ZN3sce4Json6Parser5parseERNS0_5ValueEPKcm, val, t, strlen(text));
}
static uint64_t member(uint64_t val, const char *key) {
  return call(shim__ZNK3sce4Json5ValueixEPKc, val, gstr(key), 0);
}
static uint64_t elem(uint64_t val, uint64_t i) { return call(shim__ZNK3sce4Json5ValueixEm, val, i, 0); }
static uint32_t type(uint64_t val) { return (uint32_t)call(shim__ZNK3sce4Json5Value7getTypeEv, val, 0, 0); }
static int64_t integer(uint64_t val) { return (int64_t)call(shim__ZNK3sce4Json5Value10getIntegerEv, val, 0, 0); }
static double real(uint64_t val) {
  call(shim__ZNK3sce4Json5Value7getRealEv, val, 0, 0);
  return g->xmm[0].f64[0];
}
static const char *text_of(uint64_t val) {
  const uint64_t s = call(shim__ZNK3sce4Json5Value9getStringEv, val, 0, 0);
  CHECK(in_guest(s), "getString address %#llx", (unsigned long long)s);
  const uint64_t c = call(shim__ZNK3sce4Json6String5c_strEv, s, 0, 0);
  CHECK(in_guest(c), "c_str address %#llx", (unsigned long long)c);
  return (const char *)g->mem_base + c;
}
static const char *serialize(uint64_t val) {
  const uint64_t s = obj();
  call(shim__ZN3sce4Json6StringC1Ev, s, 0, 0);
  CHECK(call(shim__ZN3sce4Json5Value9serializeERNS0_6StringE, val, s, 0) == 0, "serialize");
  return (const char *)g->mem_base + call(shim__ZNK3sce4Json6String5c_strEv, s, 0, 0);
}
static uint64_t value(void) {
  const uint64_t v = obj();
  call(shim__ZN3sce4Json5ValueC1Ev, v, 0, 0);
  return v;
}

static const char *kDoc =
    "{ \"name\": \"Sonic \\\"the\\\" Hedgehog\\n\", \"id\": -42, \"big\": 18446744073709551615,"
    " \"pi\": 3.25, \"exp\": 1e3, \"ok\": true, \"no\": false, \"nothing\": null,"
    " \"uni\": \"\\u00e9\\ud83d\\ude00\", \"list\": [1, [2, 3], {\"k\": \"v\"}, []], \"empty\": {} }";

static void test_parse_read(void) {
  const uint64_t v = value();
  CHECK(parse(v, kDoc) == 0, "parse");
  CHECK(type(v) == T_OBJECT, "root type %u", type(v));
  CHECK(strcmp(text_of(member(v, "name")), "Sonic \"the\" Hedgehog\n") == 0, "name '%s'", text_of(member(v, "name")));
  CHECK(type(member(v, "id")) == T_INT && integer(member(v, "id")) == -42, "id");
  CHECK(type(member(v, "big")) == T_UINT && (uint64_t)integer(member(v, "big")) == UINT64_MAX, "big");
  CHECK(type(member(v, "pi")) == T_REAL && real(member(v, "pi")) == 3.25, "pi");
  CHECK(type(member(v, "exp")) == T_REAL && real(member(v, "exp")) == 1000.0, "exp");
  CHECK(type(member(v, "ok")) == T_BOOL && call(shim__ZNK3sce4Json5Value10getBooleanEv, member(v, "ok"), 0, 0) == 1, "true");
  CHECK(type(member(v, "no")) == T_BOOL && call(shim__ZNK3sce4Json5Value10getBooleanEv, member(v, "no"), 0, 0) == 0, "false");
  CHECK(type(member(v, "nothing")) == T_NULL, "null");
  CHECK(strcmp(text_of(member(v, "uni")), "\xc3\xa9\xf0\x9f\x98\x80") == 0, "unicode");
  CHECK(type(member(v, "missing")) == T_NULL && in_guest(member(v, "missing")), "missing member");
  const uint64_t list = member(v, "list");
  CHECK(type(list) == T_ARRAY, "list");
  const uint64_t arr = call(shim__ZNK3sce4Json5Value8getArrayEv, list, 0, 0);
  CHECK(in_guest(arr) && call(shim__ZNK3sce4Json5Array4sizeEv, arr, 0, 0) == 4, "list size");
  CHECK(integer(elem(list, 0)) == 1 && integer(elem(elem(list, 1), 1)) == 3, "list elements");
  CHECK(strcmp(text_of(member(elem(list, 2), "k")), "v") == 0, "object in list");
  CHECK(type(call(shim__ZNK3sce4Json5Array4backEv, arr, 0, 0)) == T_ARRAY, "back");
  CHECK(type(elem(list, 9)) == T_NULL, "index past the end");
  const uint64_t empty = call(shim__ZNK3sce4Json5Value9getObjectEv, member(v, "empty"), 0, 0);
  CHECK(call(shim__ZNK3sce4Json6Object5emptyEv, empty, 0, 0) == 1, "empty object");
  CHECK(call(shim__ZNK3sce4Json6Object5emptyEv, call(shim__ZNK3sce4Json5Value9getObjectEv, v, 0, 0), 0, 0) == 0,
        "root not empty");
  // Round trip.
  const char *ser = serialize(v);
  const uint64_t v2 = value();
  CHECK(parse(v2, ser) == 0, "parse(serialize) '%s'", ser);
  CHECK(strcmp(serialize(v2), ser) == 0, "round trip");
  call(shim__ZN3sce4Json5ValueD1Ev, v, 0, 0);
  call(shim__ZN3sce4Json5ValueD1Ev, v2, 0, 0);
}

static void test_build_serialize(void) {
  const uint64_t o = obj();
  call(shim__ZN3sce4Json6ObjectC1Ev, o, 0, 0);
  const uint64_t key = obj();
  call(shim__ZN3sce4Json6StringC1EPKc, key, gstr("title"), 0);
  const uint64_t slot = call(shim__ZN3sce4Json6ObjectixERKNS0_6StringE, o, key, 0);
  CHECK(in_guest(slot), "operator[] slot");
  const uint64_t s = value();
  call(shim__ZN3sce4Json5ValueC1EPKc, s, gstr("Origins"), 0);
  call(shim__ZN3sce4Json5ValueaSERKS1_, slot, s, 0);
  CHECK(call(shim__ZN3sce4Json6ObjectixERKNS0_6StringE, o, key, 0) == slot, "same key, same slot");

  const uint64_t a = obj();
  call(shim__ZN3sce4Json5ArrayC1Ev, a, 0, 0);
  CHECK(call(shim__ZNK3sce4Json5Array5emptyEv, a, 0, 0) == 1, "new array empty");
  const uint64_t n = value(), b = value(), d = value();
  call(shim__ZN3sce4Json5ValueC1El, n, 7, 0);
  call(shim__ZN3sce4Json5ValueC1Eb, b, 1, 0);
  g->xmm[0].f64[0] = 0.5;
  call(shim__ZN3sce4Json5ValueC1Ed, d, 0, 0);
  call(shim__ZN3sce4Json5Array9push_backERKNS0_5ValueE, a, n, 0);
  call(shim__ZN3sce4Json5Array9push_backERKNS0_5ValueE, a, b, 0);
  call(shim__ZN3sce4Json5Array9push_backERKNS0_5ValueE, a, d, 0);
  // push_back of the array's own last element.
  call(shim__ZN3sce4Json5Array9push_backERKNS0_5ValueE, a, call(shim__ZNK3sce4Json5Array4backEv, a, 0, 0), 0);
  const uint64_t av = value();
  call(shim__ZN3sce4Json5ValueC1ERKNS0_5ArrayE, av, a, 0);
  const uint64_t key2 = obj();
  call(shim__ZN3sce4Json6StringC1EPKc, key2, gstr("nums"), 0);
  call(shim__ZN3sce4Json5ValueaSERKS1_, call(shim__ZN3sce4Json6ObjectixERKNS0_6StringE, o, key2, 0), av, 0);

  const uint64_t root = value();
  call(shim__ZN3sce4Json5ValueC1ERKNS0_6ObjectE, root, o, 0);
  CHECK(strcmp(serialize(root), "{\"title\":\"Origins\",\"nums\":[7,true,0.5,0.5]}") == 0, "serialize '%s'",
        serialize(root));

  // referArray on a string value turns it into an array; set(Object) from its own member.
  const uint64_t arr = call(shim__ZN3sce4Json5Value10referArrayEv, member(root, "title"), 0, 0);
  CHECK(in_guest(arr) && call(shim__ZNK3sce4Json5Array4sizeEv, arr, 0, 0) == 0, "referArray");
  const uint64_t inner = value();
  CHECK(parse(inner, "{\"a\":{\"b\":1}}") == 0, "parse inner");
  call(shim__ZN3sce4Json5Value3setERKNS0_6ObjectE, inner,
       call(shim__ZNK3sce4Json5Value9getObjectEv, member(inner, "a"), 0, 0), 0);
  CHECK(strcmp(serialize(inner), "{\"b\":1}") == 0, "set(own member) '%s'", serialize(inner));
  call(shim__ZN3sce4Json5Value3setENS0_9ValueTypeE, inner, T_INT, 0);
  CHECK(type(inner) == T_INT && integer(inner) == 0, "set(Integer)");

  // Deep copies.
  const uint64_t o2 = obj();
  call(shim__ZN3sce4Json6ObjectC1ERKS1_, o2, o, 0);
  call(shim__ZN3sce4Json6Object5clearEv, o, 0, 0);
  CHECK(call(shim__ZNK3sce4Json6Object5emptyEv, o, 0, 0) == 1 && call(shim__ZNK3sce4Json6Object5emptyEv, o2, 0, 0) == 0,
        "Object copy independent");
  const uint64_t r2 = value();
  call(shim__ZN3sce4Json5ValueaSERKS1_, r2, root, 0);
  call(shim__ZN3sce4Json5Value3setENS0_9ValueTypeE, root, T_NULL, 0);
  CHECK(strcmp(serialize(r2), "{\"title\":[],\"nums\":[7,true,0.5,0.5]}") == 0, "Value copy '%s'", serialize(r2));
  CHECK(strcmp(serialize(root), "null") == 0, "reset root");

  const uint64_t str = obj(), str2 = obj();
  call(shim__ZN3sce4Json6StringC1EPKc, str, gstr("abc"), 0);
  call(shim__ZN3sce4Json6StringC1Ev, str2, 0, 0);
  CHECK(call(shim__ZNK3sce4Json6String6lengthEv, str2, 0, 0) == 0 &&
            *(char *)(g->mem_base + call(shim__ZNK3sce4Json6String5c_strEv, str2, 0, 0)) == 0,
        "empty String");
  call(shim__ZN3sce4Json6StringaSERKS1_, str2, str, 0);
  call(shim__ZN3sce4Json6StringD1Ev, str, 0, 0);
  CHECK(strcmp((char *)g->mem_base + call(shim__ZNK3sce4Json6String5c_strEv, str2, 0, 0), "abc") == 0 &&
            call(shim__ZNK3sce4Json6String6lengthEv, str2, 0, 0) == 3,
        "String copy");
}

static void test_errors(void) {
  const char *bad[] = {"{\"a\":1,}", "[1,2", "\"abc", "\"\\x\"", "{} x", "\"\\ud800\"", "{\"a\" 1}", "01", "-", ""};
  for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
    const uint64_t v = value();
    call(shim__ZN3sce4Json5ValueC1El, v, 5, 0);
    CHECK(parse(v, bad[i]) < 0, "'%s' accepted", bad[i]);
    CHECK(type(v) == T_NULL, "'%s' left type %u", bad[i], type(v));
  }
  // The text ends at a NUL inside `size`.
  const uint64_t v = value();
  const uint64_t t = gstr("[true]");
  CHECK((int32_t)call(shim__ZN3sce4Json6Parser5parseERNS0_5ValueEPKcm, v, t, 64) == 0 && type(v) == T_ARRAY,
        "NUL-terminated text");
}

static void test_no_leak(void) {
  const uint64_t v = value(), text = gstr(kDoc);
  for (int i = 0; i < 20000; i++) {
    call(shim__ZN3sce4Json5ValueC1Ev, v, 0, 0);
    if ((int32_t)call(shim__ZN3sce4Json6Parser5parseERNS0_5ValueEPKcm, v, text, strlen(kDoc)) != 0) {
      CHECK(0, "round %d failed (VM exhausted?)", i);
      return;
    }
    call(shim__ZN3sce4Json5ValueD1Ev, v, 0, 0);
  }
}

int main(void) {
  g = new_ctx();
  test_parse_read();
  test_build_serialize();
  test_errors();
  test_no_leak();
  if (g_failures) {
    printf("json2_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("json2_test: PASS\n");
  return 0;
}
