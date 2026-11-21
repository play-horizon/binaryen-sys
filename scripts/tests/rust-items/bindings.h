// The C header of the fixture of scripts/rust-items.awk's tests (scripts/test-scripts.sh): one
// declaration of each shape that reader must get right. bindings.rs is bindgen's output for it,
// which the tests check: `scripts/test-scripts.sh --regenerate` writes it again.
#include <stddef.h>
#include <stdint.h>

// A string constant whose literal holds spaces, brackets and something like a parameter.
#define GREETING "fn(a: b)  ( x , y )"
#define LIMIT 64

// Enumerators whose values bindgen computes, through casts and `sizeof`.
enum Flags { FLAG_ONE = 1u, FLAG_EIGHT = 1u << 3, FLAG_INT_SIZE = sizeof(int), FLAG_NEXT };

// An anonymous struct named by its typedef.
typedef struct { int32_t width; int64_t height; } Size;

// Bit-fields, whose widths only bindgen's accessors hold.
struct Bits { unsigned low : 3; unsigned high : 5; };

// Layouts set by attributes.
struct __attribute__((packed)) Packed { char tag; int32_t value; };
struct __attribute__((aligned(16))) Aligned { int32_t value; };

// Nested types, which C gives file scope.
struct Outer { struct Inner { int32_t depth; } inner; enum Mode { MODE_A, MODE_B } mode; };

// A union and a flexible array.
union Number { int32_t integer; float real; };
struct Buffer { size_t count; uint8_t bytes[]; };

// Callbacks: a type, a field, a parameter of a callback type followed by another one, and two
// callbacks written out in a parameter list before a third parameter.
typedef int32_t (*Visitor)(int32_t value, void* user_data);
struct Listener { void (*on_event)(int32_t event_kind, void* user_data); };
void SetVisitor(Visitor visitor, void* user_data);
void SetHandlers(void (*on_start)(int32_t code), int32_t (*on_end)(int32_t code, void* state), void* user_data);

// A function with several parameters, a variadic one, a constant array and a mutable variable.
int32_t Combine(int32_t first, int64_t second, const char* label);
int32_t Print(const char* format, ...);
extern const char* const names[4];
extern int32_t counter;
