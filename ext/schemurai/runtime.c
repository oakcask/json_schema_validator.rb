#include "ruby.h"
#include "ruby/ractor.h"
#include "ruby/thread.h"
#include <math.h>
#include <stdbool.h>

VALUE schemurai_generated_boolean_instance(VALUE self, VALUE instance);
unsigned long schemurai_generated_compile_type(VALUE schema);
int schemurai_generated_valid_type(unsigned long mask, VALUE instance);

typedef struct {
    VALUE schema;
    unsigned long type_mask;
    bool shareable;
} schemurai_graph_t;

static void
schemurai_graph_mark(void *pointer)
{
    schemurai_graph_t *graph = pointer;
    rb_gc_mark_movable(graph->schema);
}

static void
schemurai_graph_compact(void *pointer)
{
    schemurai_graph_t *graph = pointer;
    graph->schema = rb_gc_location(graph->schema);
}

static void
schemurai_graph_free(void *pointer)
{
    xfree(pointer);
}

static size_t
schemurai_graph_size(const void *pointer)
{
    return pointer == NULL ? 0 : sizeof(schemurai_graph_t);
}

static const rb_data_type_t schemurai_graph_type = {
    .wrap_struct_name = "Schemurai::Native::Graph",
    .function = {
        .dmark = schemurai_graph_mark,
        .dfree = schemurai_graph_free,
        .dsize = schemurai_graph_size,
        .dcompact = schemurai_graph_compact,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
schemurai_graph_allocate(VALUE klass)
{
    schemurai_graph_t *graph;
    VALUE wrapper = TypedData_Make_Struct(klass, schemurai_graph_t, &schemurai_graph_type, graph);
    graph->schema = Qnil;
    graph->type_mask = 0;
    graph->shareable = false;
    return wrapper;
}

static VALUE
schemurai_graph_make_shareable(VALUE self)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    if (graph->shareable) return self;

    rb_obj_freeze(self);
    rb_ractor_make_shareable(self);
    graph->shareable = true;
    return self;
}

static VALUE
schemurai_graph_initialize(VALUE self, VALUE schema)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    graph->schema = schema;
    graph->type_mask = schemurai_generated_compile_type(schema);
    return schemurai_graph_make_shareable(self);
}

static VALUE
schemurai_graph_for_shareability_test(VALUE klass, VALUE schema)
{
    schemurai_graph_t *graph;
    VALUE wrapper = schemurai_graph_allocate(klass);
    TypedData_Get_Struct(wrapper, schemurai_graph_t, &schemurai_graph_type, graph);
    graph->schema = schema;
    return wrapper;
}

static VALUE
schemurai_graph_schema(VALUE self)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    return graph->schema;
}

static VALUE
schemurai_graph_valid(VALUE self, VALUE instance)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    return schemurai_generated_valid_type(graph->type_mask, instance) ? Qtrue : Qfalse;
}

static VALUE
schemurai_graph_shareable_state(VALUE self)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    return graph->shareable ? Qtrue : Qfalse;
}

static VALUE
schemurai_graph_validate_repeated(VALUE self, VALUE instance, VALUE iterations_value)
{
    schemurai_graph_t *graph;
    unsigned long iterations = NUM2ULONG(iterations_value);
    unsigned long index;
    int valid = 0;

    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    for (index = 0; index < iterations; index++) {
        rb_thread_check_ints();
        valid = schemurai_generated_valid_type(graph->type_mask, instance);
    }
    return valid ? Qtrue : Qfalse;
}

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
    VALUE graph = rb_define_class_under(native, "Graph", rb_cObject);

    rb_define_const(native, "BACKEND", ID2SYM(rb_intern("native")));
    rb_define_singleton_method(intrinsics, "boolean_instance?", schemurai_generated_boolean_instance, 1);
    rb_define_singleton_method(intrinsics, "exact_builtin?", schemurai_exact_builtin, 2);
    rb_define_singleton_method(intrinsics, "finite_float?", schemurai_finite_float, 1);
    rb_define_singleton_method(intrinsics, "integral_float?", schemurai_integral_float, 1);
    rb_define_singleton_method(intrinsics, "mask_intersects?", schemurai_mask_intersects, 2);
    rb_define_alloc_func(graph, schemurai_graph_allocate);
    rb_define_singleton_method(graph, "__for_shareability_test__", schemurai_graph_for_shareability_test, 1);
    rb_define_method(graph, "initialize", schemurai_graph_initialize, 1);
    rb_define_method(graph, "schema", schemurai_graph_schema, 0);
    rb_define_method(graph, "valid?", schemurai_graph_valid, 1);
    rb_define_method(graph, "__make_shareable__", schemurai_graph_make_shareable, 0);
    rb_define_method(graph, "shareable_state?", schemurai_graph_shareable_state, 0);
    rb_define_method(graph, "__validate_repeated__", schemurai_graph_validate_repeated, 2);
}
