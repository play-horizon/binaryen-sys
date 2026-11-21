//! The smoke test: a module that uses Wasm GC and exception handling, built through the C API,
//! validated, and written as text and as a binary.
//!
//! The module has a struct type `$point` with a mutable `i32` field, an array type of `i32`, a
//! tag `$fail` that carries an `i32`, and an exported function `run` that allocates a `$point`
//! and an array, throws the point's field with `$fail`, catches it with `catch_all_ref`, throws
//! the caught exception again with `throw_ref`, catches it with `catch $fail` and returns the
//! value.

#![expect(
    unsafe_code,
    reason = "the test calls the C API through the raw bindings"
)]

use std::ffi::{CStr, c_char};
use std::ptr;

use binaryen_sys_next::*;

const POINT_FIELD: i32 = 7;

#[test]
fn a_gc_and_exception_handling_module_validates_and_writes() {
    // SAFETY: every call follows binaryen-c.h's contract: the module and the type builder are
    // used on this thread only, every pointer passed is valid for the call, the arrays have the
    // lengths passed with them, and every string is a NUL-terminated literal.
    unsafe {
        let module = BinaryenModuleCreate();
        BinaryenModuleSetFeatures(
            module,
            BinaryenFeatureMVP()
                | BinaryenFeatureReferenceTypes()
                | BinaryenFeatureGC()
                | BinaryenFeatureExceptionHandling(),
        );

        let [point, numbers] = gc_types();
        let point_ref = BinaryenTypeFromHeapType(point, false);
        assert!(BinaryenHeapTypeIsStruct(point));
        assert_eq!(BinaryenStructTypeGetNumFields(point), 1);
        assert!(BinaryenStructTypeIsFieldMutable(point, 0));
        assert!(BinaryenHeapTypeIsArray(numbers));

        let fail = c"fail".as_ptr();
        BinaryenAddTag(module, fail, BinaryenTypeInt32(), BinaryenTypeNone());

        let body = run_body(module, point, numbers, point_ref, fail);
        let mut locals = [point_ref];
        let run = c"run".as_ptr();
        BinaryenAddFunction(
            module,
            run,
            BinaryenTypeNone(),
            BinaryenTypeInt32(),
            locals.as_mut_ptr(),
            1,
            body,
        );
        BinaryenAddFunctionExport(module, run, run);

        assert!(BinaryenModuleValidate(module));

        let text = BinaryenModuleAllocateAndWriteText(module);
        let printed = CStr::from_ptr(text).to_str().unwrap().to_owned();
        free(text.cast());
        assert!(printed.contains("struct.new"), "{printed}");
        assert!(printed.contains("try_table"), "{printed}");
        assert!(printed.contains("throw_ref"), "{printed}");

        let written = BinaryenModuleAllocateAndWrite(module, ptr::null());
        assert!(written.sourceMap.is_null());
        let binary =
            std::slice::from_raw_parts(written.binary.cast::<u8>(), written.binaryBytes).to_vec();
        free(written.binary);
        assert_eq!(binary[..8], *b"\0asm\x01\0\0\0");

        BinaryenModuleDispose(module);
    }
}

/// Builds `$point`, a struct with one mutable `i32` field, and an array of mutable `i32`, in one
/// recursion group, through a type builder.
///
/// # Safety
///
/// Called on one thread at a time, like every use of a type builder.
unsafe fn gc_types() -> [BinaryenHeapType; 2] {
    // SAFETY: the builder has two slots, both set before it is built; the field arrays have the
    // one field passed with them; the output arrays have the two entries the builder fills.
    unsafe {
        let builder = TypeBuilderCreate(2);
        let mut field_types = [BinaryenTypeInt32()];
        let mut packed = [BinaryenPackedTypeNotPacked()];
        let mut mutable = [true];
        TypeBuilderSetStructType(
            builder,
            0,
            field_types.as_mut_ptr(),
            packed.as_mut_ptr(),
            mutable.as_mut_ptr(),
            1,
        );
        TypeBuilderSetArrayType(
            builder,
            1,
            BinaryenTypeInt32(),
            BinaryenPackedTypeNotPacked(),
            1,
        );
        TypeBuilderCreateRecGroup(builder, 0, 2);
        let mut heap_types = [0; 2];
        let mut error_index = 0;
        let mut error_reason = 0;
        let built = TypeBuilderBuildAndDispose(
            builder,
            heap_types.as_mut_ptr(),
            &raw mut error_index,
            &raw mut error_reason,
        );
        assert!(
            built,
            "type {error_index} failed with reason {error_reason}"
        );
        heap_types
    }
}

/// The body of `run`, whose local 0 is a `$point`:
///
/// ```wat
/// (local.set $p (struct.new $point (i32.const 7)))
/// (drop (array.new_fixed $numbers 2 (i32.const 1) (i32.const 2)))
/// (block $caught (result i32)
///   (try_table (catch $fail $caught)
///     (throw_ref
///       (block $held (result exnref)
///         (try_table (catch_all_ref $held)
///           (throw $fail (struct.get $point 0 (local.get $p))))
///         (unreachable))))
///   (unreachable))
/// ```
///
/// # Safety
///
/// `module` is a live module with the tag `fail`, used on this thread only.
unsafe fn run_body(
    module: BinaryenModuleRef,
    point: BinaryenHeapType,
    numbers: BinaryenHeapType,
    point_ref: BinaryenType,
    fail: *const c_char,
) -> BinaryenExpressionRef {
    // SAFETY: every operand array has the length passed with it, every name is a live
    // NUL-terminated string or null where the C API allows it, and every expression belongs to
    // `module`.
    unsafe {
        let mut operands = [BinaryenConst(module, BinaryenLiteralInt32(POINT_FIELD))];
        let new_point = BinaryenStructNew(module, operands.as_mut_ptr(), 1, point);
        let set_point = BinaryenLocalSet(module, 0, new_point);

        let mut elements = [
            BinaryenConst(module, BinaryenLiteralInt32(1)),
            BinaryenConst(module, BinaryenLiteralInt32(2)),
        ];
        let new_numbers = BinaryenArrayNewFixed(module, numbers, elements.as_mut_ptr(), 2);
        let drop_numbers = BinaryenDrop(module, new_numbers);

        let field = BinaryenStructGet(
            module,
            0,
            BinaryenLocalGet(module, 0, point_ref),
            BinaryenTypeInt32(),
            false,
        );
        let mut thrown = [field];
        let throw = BinaryenThrow(module, fail, thrown.as_mut_ptr(), 1);

        let held = c"held".as_ptr();
        let mut catch_all = [ptr::null()];
        let mut to_held = [held];
        let with_reference = [true];
        let hold = BinaryenTryTable(
            module,
            throw,
            catch_all.as_mut_ptr(),
            to_held.as_mut_ptr(),
            with_reference.as_ptr(),
            1,
        );
        let mut held_children = [hold, BinaryenUnreachable(module)];
        let exception = BinaryenBlock(
            module,
            held,
            held_children.as_mut_ptr(),
            2,
            BinaryenTypeExnref(),
        );
        let rethrow = BinaryenThrowRef(module, exception);

        let caught = c"caught".as_ptr();
        let mut catch_fail = [fail];
        let mut to_caught = [caught];
        let without_reference = [false];
        let catch = BinaryenTryTable(
            module,
            rethrow,
            catch_fail.as_mut_ptr(),
            to_caught.as_mut_ptr(),
            without_reference.as_ptr(),
            1,
        );
        let mut caught_children = [catch, BinaryenUnreachable(module)];
        let handler = BinaryenBlock(
            module,
            caught,
            caught_children.as_mut_ptr(),
            2,
            BinaryenTypeInt32(),
        );

        let mut children = [set_point, drop_numbers, handler];
        BinaryenBlock(
            module,
            ptr::null(),
            children.as_mut_ptr(),
            3,
            BinaryenTypeInt32(),
        )
    }
}
