#include "ruby.h"
#include "ruby/ractor.h"
#include "ruby/thread.h"
#include <stdint.h>
#include <math.h>
#include <stdbool.h>

VALUE schemurai_generated_boolean_instance(VALUE self, VALUE instance);
void schemurai_generated_init(void);
uint8_t schemurai_generated_compile_type(VALUE schema);
int schemurai_generated_valid_type(uint8_t mask, VALUE instance);

#define SCHEMURAI_NODE_REF_SIBLINGS UINT8_C(1 << 0)
#define SCHEMURAI_NODE_FORMAT_ASSERTION UINT8_C(1 << 1)
#define SCHEMURAI_NODE_SUPPORTS_MIN_CONTAINS UINT8_C(1 << 2)

typedef struct {
    VALUE schema;
    VALUE dialect;
    VALUE dialect_uri;
    VALUE base_uri;
    VALUE schema_path;
    VALUE resource_path;
    VALUE format;
    VALUE children;
    VALUE references;
    uint32_t resource_root;
    uint8_t keyword_mask;
    uint8_t type_mask;
    uint8_t flags;
} schemurai_node_t;

typedef struct {
    schemurai_node_t *nodes;
    size_t node_count;
    size_t root;
    VALUE uri_registry;
    VALUE dynamic_anchors;
    bool dynamic_scope;
    bool shareable;
} schemurai_graph_t;

static VALUE mSchemurai;
static VALUE mSchemuraiNative;
static VALUE mSchemuraiNativeIntrinsics;
static VALUE cSchemuraiNativeGraph;
static VALUE sym_native;
static VALUE sym_root;
static VALUE sym_nodes;
static VALUE sym_uri_registry;
static VALUE sym_dynamic_anchors;
static VALUE sym_dynamic_scope;
static VALUE sym_schema;
static VALUE sym_dialect;
static VALUE sym_dialect_uri;
static VALUE sym_ref_siblings;
static VALUE sym_format_assertion;
static VALUE sym_supports_min_contains;
static VALUE sym_base_uri;
static VALUE sym_schema_path;
static VALUE sym_resource_path;
static VALUE sym_resource_root;
static VALUE sym_keyword_mask;
static VALUE sym_format;
static VALUE sym_children;
static VALUE sym_references;

/* These extension globals are initialized once and immutable afterwards. */

static void
schemurai_interrupt_checkpoint(size_t index)
{
    if (index != 0 && (index & 0x3ffUL) == 0) {
        rb_thread_schedule();
        rb_thread_check_ints();
    }
}

static VALUE
schemurai_hash_symbol(VALUE hash, VALUE key)
{
    return rb_hash_aref(hash, key);
}

static void
schemurai_graph_mark(void *pointer)
{
    schemurai_graph_t *graph = pointer;
    size_t index;

    for (index = 0; index < graph->node_count; index++) {
        schemurai_node_t *node = &graph->nodes[index];
        rb_gc_mark_movable(node->schema);
        rb_gc_mark_movable(node->dialect);
        rb_gc_mark_movable(node->dialect_uri);
        rb_gc_mark_movable(node->base_uri);
        rb_gc_mark_movable(node->schema_path);
        rb_gc_mark_movable(node->resource_path);
        rb_gc_mark_movable(node->format);
        rb_gc_mark_movable(node->children);
        rb_gc_mark_movable(node->references);
    }
    rb_gc_mark_movable(graph->uri_registry);
    rb_gc_mark_movable(graph->dynamic_anchors);
}

static void
schemurai_graph_compact(void *pointer)
{
    schemurai_graph_t *graph = pointer;
    size_t index;

    for (index = 0; index < graph->node_count; index++) {
        schemurai_node_t *node = &graph->nodes[index];
        node->schema = rb_gc_location(node->schema);
        node->dialect = rb_gc_location(node->dialect);
        node->dialect_uri = rb_gc_location(node->dialect_uri);
        node->base_uri = rb_gc_location(node->base_uri);
        node->schema_path = rb_gc_location(node->schema_path);
        node->resource_path = rb_gc_location(node->resource_path);
        node->format = rb_gc_location(node->format);
        node->children = rb_gc_location(node->children);
        node->references = rb_gc_location(node->references);
    }
    graph->uri_registry = rb_gc_location(graph->uri_registry);
    graph->dynamic_anchors = rb_gc_location(graph->dynamic_anchors);
}

static void
schemurai_graph_free(void *pointer)
{
    schemurai_graph_t *graph = pointer;
    xfree(graph->nodes);
    xfree(graph);
}

static size_t
schemurai_graph_size(const void *pointer)
{
    const schemurai_graph_t *graph = pointer;
    return graph == NULL ? 0 : sizeof(schemurai_graph_t) + (sizeof(schemurai_node_t) * graph->node_count);
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
    graph->nodes = NULL;
    graph->node_count = 0;
    graph->root = 0;
    graph->uri_registry = Qnil;
    graph->dynamic_anchors = Qnil;
    graph->dynamic_scope = false;
    graph->shareable = false;
    return wrapper;
}

static VALUE
schemurai_graph_make_shareable(VALUE self)
{
    schemurai_graph_t *graph;
    size_t index;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    if (graph->shareable) return self;

    for (index = 0; index < graph->node_count; index++) {
        schemurai_interrupt_checkpoint(index);
        schemurai_node_t *node = &graph->nodes[index];
        rb_ractor_make_shareable(node->schema);
        rb_ractor_make_shareable(node->dialect);
        rb_ractor_make_shareable(node->dialect_uri);
        rb_ractor_make_shareable(node->base_uri);
        rb_ractor_make_shareable(node->schema_path);
        rb_ractor_make_shareable(node->resource_path);
        rb_ractor_make_shareable(node->format);
        rb_ractor_make_shareable(node->children);
        rb_ractor_make_shareable(node->references);
    }
    rb_ractor_make_shareable(graph->uri_registry);
    rb_ractor_make_shareable(graph->dynamic_anchors);
    rb_obj_freeze(self);
    rb_ractor_make_shareable(self);
    graph->shareable = true;
    return self;
}

static VALUE
schemurai_graph_initialize(VALUE self, VALUE snapshot)
{
    schemurai_graph_t *graph;
    VALUE records;
    long count;
    long index;

    Check_Type(snapshot, T_HASH);
    records = schemurai_hash_symbol(snapshot, sym_nodes);
    Check_Type(records, T_ARRAY);
    Check_Type(schemurai_hash_symbol(snapshot, sym_uri_registry), T_HASH);
    Check_Type(schemurai_hash_symbol(snapshot, sym_dynamic_anchors), T_HASH);
    count = RARRAY_LEN(records);
    if (count == 0) rb_raise(rb_eArgError, "native graph snapshot has no nodes");
    if ((uint64_t)count > UINT32_MAX) rb_raise(rb_eArgError, "native graph snapshot has too many nodes");

    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    graph->root = NUM2SIZET(schemurai_hash_symbol(snapshot, sym_root));
    if (graph->root >= (size_t)count) rb_raise(rb_eArgError, "native graph root index is out of bounds");

    /* Validate all raising numeric conversions before acquiring native memory. */
    for (index = 0; index < count; index++) {
        schemurai_interrupt_checkpoint((size_t)index);
        VALUE record = rb_ary_entry(records, index);
        unsigned int keyword_mask;
        Check_Type(record, T_HASH);
        keyword_mask = NUM2UINT(schemurai_hash_symbol(record, sym_keyword_mask));
        if (keyword_mask > UINT8_MAX) rb_raise(rb_eArgError, "native keyword mask is out of bounds");
        (void)NUM2UINT(schemurai_hash_symbol(record, sym_resource_root));
        Check_Type(schemurai_hash_symbol(record, sym_children), T_ARRAY);
        Check_Type(schemurai_hash_symbol(record, sym_references), T_ARRAY);
    }

    graph->nodes = ALLOC_N(schemurai_node_t, (size_t)count);
    for (index = 0; index < count; index++) {
        schemurai_interrupt_checkpoint((size_t)index);
        VALUE record = rb_ary_entry(records, index);
        schemurai_node_t *node = &graph->nodes[index];
        node->schema = schemurai_hash_symbol(record, sym_schema);
        node->dialect = schemurai_hash_symbol(record, sym_dialect);
        node->dialect_uri = schemurai_hash_symbol(record, sym_dialect_uri);
        node->flags = 0;
        if (RTEST(schemurai_hash_symbol(record, sym_ref_siblings))) node->flags |= SCHEMURAI_NODE_REF_SIBLINGS;
        if (RTEST(schemurai_hash_symbol(record, sym_format_assertion))) node->flags |= SCHEMURAI_NODE_FORMAT_ASSERTION;
        if (RTEST(schemurai_hash_symbol(record, sym_supports_min_contains))) node->flags |= SCHEMURAI_NODE_SUPPORTS_MIN_CONTAINS;
        node->base_uri = schemurai_hash_symbol(record, sym_base_uri);
        node->schema_path = schemurai_hash_symbol(record, sym_schema_path);
        node->resource_path = schemurai_hash_symbol(record, sym_resource_path);
        node->resource_root = NUM2UINT(schemurai_hash_symbol(record, sym_resource_root));
        if (node->resource_root >= (size_t)count) rb_raise(rb_eArgError, "native graph resource root index is out of bounds");
        node->keyword_mask = (uint8_t)NUM2UINT(schemurai_hash_symbol(record, sym_keyword_mask));
        node->format = schemurai_hash_symbol(record, sym_format);
        node->children = schemurai_hash_symbol(record, sym_children);
        node->references = schemurai_hash_symbol(record, sym_references);
        /* Publish only fully initialized VALUE fields to the GC callbacks. */
        graph->node_count = (size_t)index + 1;
        node->type_mask = schemurai_generated_compile_type(node->schema);
    }
    graph->uri_registry = schemurai_hash_symbol(snapshot, sym_uri_registry);
    graph->dynamic_anchors = schemurai_hash_symbol(snapshot, sym_dynamic_anchors);
    graph->dynamic_scope = RTEST(schemurai_hash_symbol(snapshot, sym_dynamic_scope));
    return schemurai_graph_make_shareable(self);
}

static VALUE
schemurai_graph_for_shareability_test(VALUE klass, VALUE schema)
{
    schemurai_graph_t *graph;
    VALUE wrapper = schemurai_graph_allocate(klass);
    TypedData_Get_Struct(wrapper, schemurai_graph_t, &schemurai_graph_type, graph);
    graph->nodes = ALLOC_N(schemurai_node_t, 1);
    graph->node_count = 1;
    graph->root = 0;
    graph->nodes[0] = (schemurai_node_t){
        .schema = schema, .dialect = Qnil, .dialect_uri = Qnil, .base_uri = Qnil,
        .schema_path = Qnil, .resource_path = Qnil, .format = Qnil,
        .children = Qnil, .references = Qnil, .resource_root = 0, .keyword_mask = 0, .type_mask = 0,
        .flags = 0,
    };
    graph->uri_registry = Qnil;
    graph->dynamic_anchors = Qnil;
    return wrapper;
}

static VALUE
schemurai_graph_schema(VALUE self)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    if (graph->node_count == 0) rb_raise(rb_eRuntimeError, "native graph is not initialized");
    return graph->nodes[graph->root].schema;
}

static VALUE
schemurai_graph_node_count(VALUE self)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    return SIZET2NUM(graph->node_count);
}

static VALUE
schemurai_graph_root_index(VALUE self)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    return SIZET2NUM(graph->root);
}

static schemurai_node_t *
schemurai_graph_node_at(schemurai_graph_t *graph, VALUE index_value)
{
    size_t index = NUM2SIZET(index_value);
    if (index >= graph->node_count) rb_raise(rb_eIndexError, "native graph node index is out of bounds");
    return &graph->nodes[index];
}

static VALUE
schemurai_graph_node_metadata(VALUE self, VALUE index_value)
{
    schemurai_graph_t *graph;
    schemurai_node_t *node;
    VALUE result = rb_hash_new();
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    node = schemurai_graph_node_at(graph, index_value);
    rb_hash_aset(result, sym_schema, node->schema);
    rb_hash_aset(result, sym_dialect, node->dialect);
    rb_hash_aset(result, sym_dialect_uri, node->dialect_uri);
    rb_hash_aset(result, sym_ref_siblings, (node->flags & SCHEMURAI_NODE_REF_SIBLINGS) ? Qtrue : Qfalse);
    rb_hash_aset(result, sym_format_assertion, (node->flags & SCHEMURAI_NODE_FORMAT_ASSERTION) ? Qtrue : Qfalse);
    rb_hash_aset(result, sym_supports_min_contains, (node->flags & SCHEMURAI_NODE_SUPPORTS_MIN_CONTAINS) ? Qtrue : Qfalse);
    rb_hash_aset(result, sym_base_uri, node->base_uri);
    rb_hash_aset(result, sym_schema_path, node->schema_path);
    rb_hash_aset(result, sym_resource_path, node->resource_path);
    rb_hash_aset(result, sym_resource_root, UINT2NUM(node->resource_root));
    rb_hash_aset(result, sym_keyword_mask, UINT2NUM(node->keyword_mask));
    rb_hash_aset(result, sym_format, node->format);
    return result;
}

static VALUE
schemurai_graph_child(int argc, VALUE *argv, VALUE self)
{
    schemurai_graph_t *graph;
    schemurai_node_t *node;
    VALUE index_value, keyword, segment, entry;
    long index;
    rb_scan_args(argc, argv, "21", &index_value, &keyword, &segment);
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    node = schemurai_graph_node_at(graph, index_value);
    for (index = 0; index < RARRAY_LEN(node->children); index++) {
        schemurai_interrupt_checkpoint((size_t)index);
        entry = rb_ary_entry(node->children, index);
        if (RTEST(rb_equal(rb_ary_entry(entry, 0), keyword)) &&
            RTEST(rb_equal(rb_ary_entry(entry, 1), argc == 3 ? segment : Qnil))) {
            return rb_ary_entry(entry, 2);
        }
    }
    return Qnil;
}

static VALUE
schemurai_graph_resolve(VALUE self, VALUE index_value, VALUE reference)
{
    schemurai_graph_t *graph;
    schemurai_node_t *node;
    VALUE entry;
    long index;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    node = schemurai_graph_node_at(graph, index_value);
    for (index = 0; index < RARRAY_LEN(node->references); index++) {
        schemurai_interrupt_checkpoint((size_t)index);
        entry = rb_ary_entry(node->references, index);
        if (RTEST(rb_equal(rb_ary_entry(entry, 0), reference))) return rb_ary_entry(entry, 1);
    }
    return Qnil;
}

static VALUE
schemurai_graph_lookup(VALUE self, VALUE uri)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    return rb_hash_aref(graph->uri_registry, uri);
}

static VALUE
schemurai_graph_dynamic_anchor(VALUE self, VALUE resource_index, VALUE name)
{
    schemurai_graph_t *graph;
    VALUE anchors;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    anchors = rb_hash_aref(graph->dynamic_anchors, resource_index);
    return NIL_P(anchors) ? Qnil : rb_hash_aref(anchors, name);
}

static VALUE
schemurai_graph_dynamic_scope(VALUE self)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    return graph->dynamic_scope ? Qtrue : Qfalse;
}

static VALUE
schemurai_graph_valid(VALUE self, VALUE instance)
{
    schemurai_graph_t *graph;
    TypedData_Get_Struct(self, schemurai_graph_t, &schemurai_graph_type, graph);
    return schemurai_generated_valid_type(graph->nodes[graph->root].type_mask, instance) ? Qtrue : Qfalse;
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
        schemurai_interrupt_checkpoint((size_t)index);
        valid = schemurai_generated_valid_type(graph->nodes[graph->root].type_mask, instance);
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

    mSchemurai = rb_define_module("Schemurai");
    mSchemuraiNative = rb_define_module_under(mSchemurai, "Native");
    mSchemuraiNativeIntrinsics = rb_define_module_under(mSchemuraiNative, "Intrinsics");
    cSchemuraiNativeGraph = rb_define_class_under(mSchemuraiNative, "Graph", rb_cObject);

    sym_native = ID2SYM(rb_intern_const("native"));
    sym_root = ID2SYM(rb_intern_const("root"));
    sym_nodes = ID2SYM(rb_intern_const("nodes"));
    sym_uri_registry = ID2SYM(rb_intern_const("uri_registry"));
    sym_dynamic_anchors = ID2SYM(rb_intern_const("dynamic_anchors"));
    sym_dynamic_scope = ID2SYM(rb_intern_const("dynamic_scope"));
    sym_schema = ID2SYM(rb_intern_const("schema"));
    sym_dialect = ID2SYM(rb_intern_const("dialect"));
    sym_dialect_uri = ID2SYM(rb_intern_const("dialect_uri"));
    sym_ref_siblings = ID2SYM(rb_intern_const("ref_siblings"));
    sym_format_assertion = ID2SYM(rb_intern_const("format_assertion"));
    sym_supports_min_contains = ID2SYM(rb_intern_const("supports_min_contains"));
    sym_base_uri = ID2SYM(rb_intern_const("base_uri"));
    sym_schema_path = ID2SYM(rb_intern_const("schema_path"));
    sym_resource_path = ID2SYM(rb_intern_const("resource_path"));
    sym_resource_root = ID2SYM(rb_intern_const("resource_root"));
    sym_keyword_mask = ID2SYM(rb_intern_const("keyword_mask"));
    sym_format = ID2SYM(rb_intern_const("format"));
    sym_children = ID2SYM(rb_intern_const("children"));
    sym_references = ID2SYM(rb_intern_const("references"));

    schemurai_generated_init();
    rb_define_const(mSchemuraiNative, "BACKEND", sym_native);
    rb_define_singleton_method(mSchemuraiNativeIntrinsics, "boolean_instance?", schemurai_generated_boolean_instance, 1);
    rb_define_singleton_method(mSchemuraiNativeIntrinsics, "exact_builtin?", schemurai_exact_builtin, 2);
    rb_define_singleton_method(mSchemuraiNativeIntrinsics, "finite_float?", schemurai_finite_float, 1);
    rb_define_singleton_method(mSchemuraiNativeIntrinsics, "integral_float?", schemurai_integral_float, 1);
    rb_define_singleton_method(mSchemuraiNativeIntrinsics, "mask_intersects?", schemurai_mask_intersects, 2);
    rb_define_alloc_func(cSchemuraiNativeGraph, schemurai_graph_allocate);
    rb_define_singleton_method(cSchemuraiNativeGraph, "__for_shareability_test__", schemurai_graph_for_shareability_test, 1);
    rb_define_method(cSchemuraiNativeGraph, "initialize", schemurai_graph_initialize, 1);
    rb_define_method(cSchemuraiNativeGraph, "schema", schemurai_graph_schema, 0);
    rb_define_method(cSchemuraiNativeGraph, "node_count", schemurai_graph_node_count, 0);
    rb_define_method(cSchemuraiNativeGraph, "root_index", schemurai_graph_root_index, 0);
    rb_define_method(cSchemuraiNativeGraph, "node_metadata", schemurai_graph_node_metadata, 1);
    rb_define_method(cSchemuraiNativeGraph, "child", schemurai_graph_child, -1);
    rb_define_method(cSchemuraiNativeGraph, "resolve", schemurai_graph_resolve, 2);
    rb_define_method(cSchemuraiNativeGraph, "lookup", schemurai_graph_lookup, 1);
    rb_define_method(cSchemuraiNativeGraph, "dynamic_anchor", schemurai_graph_dynamic_anchor, 2);
    rb_define_method(cSchemuraiNativeGraph, "dynamic_scope?", schemurai_graph_dynamic_scope, 0);
    rb_define_method(cSchemuraiNativeGraph, "valid?", schemurai_graph_valid, 1);
    rb_define_method(cSchemuraiNativeGraph, "__make_shareable__", schemurai_graph_make_shareable, 0);
    rb_define_method(cSchemuraiNativeGraph, "shareable_state?", schemurai_graph_shareable_state, 0);
    rb_define_method(cSchemuraiNativeGraph, "__validate_repeated__", schemurai_graph_validate_repeated, 2);
}
