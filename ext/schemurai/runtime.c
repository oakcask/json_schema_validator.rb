#include "ruby.h"
#include <math.h>

VALUE schemurai_generated_boolean_instance(VALUE self, VALUE instance);

static VALUE
schemurai_exact_builtin(VALUE self, VALUE value, VALUE klass)
{
    (void)self;
    return rb_obj_is_instance_of(value, klass);
}

static VALUE
schemurai_finite_float(VALUE self, VALUE value)
{
    (void)self;
    Check_Type(value, T_FLOAT);
    return isfinite(RFLOAT_VALUE(value)) ? Qtrue : Qfalse;
}

static VALUE
schemurai_integral_float(VALUE self, VALUE value)
{
    double integral;

    (void)self;
    Check_Type(value, T_FLOAT);
    return modf(RFLOAT_VALUE(value), &integral) == 0.0 ? Qtrue : Qfalse;
}

static VALUE
schemurai_mask_intersects(VALUE self, VALUE left, VALUE right)
{
    (void)self;
    return (NUM2ULONG(left) & NUM2ULONG(right)) != 0 ? Qtrue : Qfalse;
}

void
Init_schemurai_native(void)
{
    rb_ext_ractor_safe(true);

    VALUE schemurai = rb_define_module("Schemurai");
    VALUE native = rb_define_module_under(schemurai, "Native");
    VALUE intrinsics = rb_define_module_under(native, "Intrinsics");

    rb_define_const(native, "BACKEND", ID2SYM(rb_intern("native")));
    rb_define_singleton_method(intrinsics, "boolean_instance?", schemurai_generated_boolean_instance, 1);
    rb_define_singleton_method(intrinsics, "exact_builtin?", schemurai_exact_builtin, 2);
    rb_define_singleton_method(intrinsics, "finite_float?", schemurai_finite_float, 1);
    rb_define_singleton_method(intrinsics, "integral_float?", schemurai_integral_float, 1);
    rb_define_singleton_method(intrinsics, "mask_intersects?", schemurai_mask_intersects, 2);
}
