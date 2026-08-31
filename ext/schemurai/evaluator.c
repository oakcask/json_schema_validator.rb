#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/ractor.h"
#include "ruby/st.h"
#include <stdbool.h>
#include <limits.h>

typedef struct {
    VALUE self;
    VALUE graph;
    VALUE root;
    VALUE regexps;
    VALUE active;
    VALUE dynamic_scope;
    VALUE errors;
    VALUE instance_path;
    VALUE schema_path;
    VALUE resolution_error;
    bool validate_content;
    bool validate_format;
} schemurai_evaluator_t;

static const rb_data_type_t evaluator_type;

static VALUE cEvaluator;
static VALUE mNative;
static VALUE cached_string_roots;
static st_table *cached_strings;
static ID id_schema, id_child, id_resolve, id_dialect, id_resource, id_root;
static ID id_keyword_mask, id_dynamic_scope_p, id_dynamic_anchor;
static ID id_ref_siblings_p, id_format_assertion_p, id_format, id_call, id_keywords;
static ID id_finite_p, id_to_i, id_remainder, id_zero_p, id_positive_p;
static ID id_match_p, id_length, id_object_id;
static ID id_key_p, id_keys, id_rational, id_to_s, id_compare, id_include_p;
static ID id_gsub, id_new, id_message, id_end_with_p, id_split, id_strict_decode64;
static ID id_parse, id_each, id_name, id_content;
static ID id_resolution_error, id_base64, id_json, id_parser_error;
static ID id_validation_error, id_result, id_regexp_error;
static VALUE sym_number, sym_boolean, sym_native;
static VALUE sym_keyword, sym_instance_path, sym_schema_path, sym_message;
static VALUE cResolutionError;
static VALUE mBase64, mJSON, cJSONParserError;
static VALUE cValidationError, cResult;
static VALUE cRegexpError;

typedef struct {
    const char *bytes;
    long length;
} cached_string_spec_t;

#define CACHED_STRING(value) {value, (long)(sizeof(value) - 1)}
static const cached_string_spec_t cached_string_specs[] = {
    CACHED_STRING(" or "), CACHED_STRING("#"), CACHED_STRING("$dynamicAnchor"),
    CACHED_STRING("$dynamicRef"), CACHED_STRING("$recursiveAnchor"), CACHED_STRING("$recursiveRef"),
    CACHED_STRING("$ref"), CACHED_STRING("/"), CACHED_STRING("additionalItems"),
    CACHED_STRING("additionalProperties"), CACHED_STRING("allOf"), CACHED_STRING("anyOf"),
    CACHED_STRING("application/json"), CACHED_STRING("array items are not unique"), CACHED_STRING("base64"),
    CACHED_STRING("boolean schema is false"), CACHED_STRING("const"), CACHED_STRING("contains"),
    CACHED_STRING("contentEncoding"), CACHED_STRING("contentMediaType"), CACHED_STRING("dependencies"),
    CACHED_STRING("dependentRequired"), CACHED_STRING("dependentSchemas"), CACHED_STRING("else"),
    CACHED_STRING("enum"), CACHED_STRING("exclusiveMaximum"), CACHED_STRING("exclusiveMinimum"),
    CACHED_STRING("falseSchema"), CACHED_STRING("format"), CACHED_STRING("if"),
    CACHED_STRING("invalid regular expression"), CACHED_STRING("items"), CACHED_STRING("maxContains"),
    CACHED_STRING("maxItems"), CACHED_STRING("maxLength"), CACHED_STRING("maxProperties"),
    CACHED_STRING("maximum"), CACHED_STRING("minContains"), CACHED_STRING("minItems"),
    CACHED_STRING("minLength"), CACHED_STRING("minProperties"), CACHED_STRING("minimum"),
    CACHED_STRING("multipleOf"), CACHED_STRING("no subschema matched"), CACHED_STRING("not"),
    CACHED_STRING("number is not a multiple"), CACHED_STRING("numeric limit was exceeded"), CACHED_STRING("oneOf"),
    CACHED_STRING("pattern"), CACHED_STRING("patternProperties"), CACHED_STRING("prefixItems"),
    CACHED_STRING("properties"), CACHED_STRING("propertyNames"), CACHED_STRING("required"),
    CACHED_STRING("size limit was exceeded"), CACHED_STRING("string content is invalid"),
    CACHED_STRING("string does not match pattern"), CACHED_STRING("subschema matched"), CACHED_STRING("then"),
    CACHED_STRING("type"), CACHED_STRING("unevaluatedItems"), CACHED_STRING("unevaluatedProperties"),
    CACHED_STRING("uniqueItems"), CACHED_STRING("value does not equal const"),
    CACHED_STRING("value is not in enum"), CACHED_STRING("~"), CACHED_STRING("~0"), CACHED_STRING("~1")
};
#undef CACHED_STRING

static VALUE
key(const char *name)
{
    st_data_t value;
    if (!st_lookup(cached_strings, (st_data_t)name, &value)) {
        rb_raise(rb_eRuntimeError, "uncached native evaluator string: %s", name);
    }
    return (VALUE)value;
}

static bool
hash_has(VALUE hash, const char *name)
{
    return RTEST(rb_funcall(hash, id_key_p, 1, key(name)));
}

static VALUE
hash_get(VALUE hash, const char *name)
{
    return rb_hash_aref(hash, key(name));
}

static VALUE
node_child(VALUE node, const char *keyword, VALUE segment)
{
    if (NIL_P(segment)) return rb_funcall(node, id_child, 1, key(keyword));
    return rb_funcall(node, id_child, 2, key(keyword), segment);
}

static bool
number_p(VALUE value)
{
    return rb_obj_is_kind_of(value, rb_cNumeric) && !rb_obj_is_kind_of(value, rb_cComplex);
}

static bool
type_p(VALUE value, VALUE type)
{
    const char *name = StringValueCStr(type);
    if (!strcmp(name, "null")) return NIL_P(value);
    if (!strcmp(name, "boolean")) return value == Qtrue || value == Qfalse;
    if (!strcmp(name, "object")) return rb_obj_is_kind_of(value, rb_cHash);
    if (!strcmp(name, "array")) return rb_obj_is_kind_of(value, rb_cArray);
    if (!strcmp(name, "number")) return number_p(value);
    if (!strcmp(name, "string")) return rb_obj_is_kind_of(value, rb_cString);
    if (!strcmp(name, "integer")) {
        if (!number_p(value) || !RTEST(rb_funcall(value, id_finite_p, 0))) return false;
        return RTEST(rb_equal(rb_funcall(value, id_to_i, 0), value));
    }
    return false;
}

static bool
valid_type(VALUE schema, VALUE value)
{
    VALUE types = hash_get(schema, "type");
    if (RB_TYPE_P(types, T_ARRAY)) {
        long i;
        for (i = 0; i < RARRAY_LEN(types); i++) {
            if (type_p(value, rb_ary_entry(types, i))) return true;
        }
        return false;
    }
    return type_p(value, types);
}

static VALUE
json_kind(VALUE value)
{
    if (number_p(value)) return sym_number;
    if (value == Qtrue || value == Qfalse) return sym_boolean;
    return rb_obj_class(value);
}

static bool json_equal(VALUE left, VALUE right);

static bool
json_hash_equal(VALUE left, VALUE right)
{
    VALUE keys;
    long i;
    if (RHASH_SIZE(left) != RHASH_SIZE(right)) return false;
    keys = rb_funcall(left, id_keys, 0);
    for (i = 0; i < RARRAY_LEN(keys); i++) {
        VALUE item_key = rb_ary_entry(keys, i);
        if (!RTEST(rb_funcall(right, id_key_p, 1, item_key))) return false;
        if (!json_equal(rb_hash_aref(left, item_key), rb_hash_aref(right, item_key))) return false;
    }
    return true;
}

static bool
json_equal(VALUE left, VALUE right)
{
    long i;
    if (!RTEST(rb_equal(json_kind(left), json_kind(right)))) return false;
    if (rb_obj_is_kind_of(left, rb_cHash)) return json_hash_equal(left, right);
    if (rb_obj_is_kind_of(left, rb_cArray)) {
        if (RARRAY_LEN(left) != RARRAY_LEN(right)) return false;
        for (i = 0; i < RARRAY_LEN(left); i++) {
            if (!json_equal(rb_ary_entry(left, i), rb_ary_entry(right, i))) return false;
        }
        return true;
    }
    return RTEST(rb_equal(left, right));
}

static bool
valid_enum(VALUE schema, VALUE value)
{
    long i;
    if (hash_has(schema, "enum")) {
        VALUE values = hash_get(schema, "enum");
        for (i = 0; i < RARRAY_LEN(values); i++) {
            if (json_equal(rb_ary_entry(values, i), value)) break;
        }
        if (i == RARRAY_LEN(values)) return false;
    }
    return !hash_has(schema, "const") || json_equal(hash_get(schema, "const"), value);
}

static VALUE
decimal(VALUE value)
{
    if (RB_INTEGER_TYPE_P(value) || rb_obj_is_kind_of(value, rb_cRational)) return value;
    return rb_funcall(rb_mKernel, id_rational, 1, rb_funcall(value, id_to_s, 0));
}

static int
compare(VALUE left, VALUE right)
{
    return rb_cmpint(rb_funcall(left, id_compare, 1, right), left, right);
}

static bool
valid_number(VALUE schema, VALUE value)
{
    VALUE actual = decimal(value);
    if (hash_has(schema, "maximum") && compare(actual, decimal(hash_get(schema, "maximum"))) > 0) return false;
    if (hash_has(schema, "minimum") && compare(actual, decimal(hash_get(schema, "minimum"))) < 0) return false;
    if (hash_has(schema, "exclusiveMaximum") && compare(actual, decimal(hash_get(schema, "exclusiveMaximum"))) >= 0) return false;
    if (hash_has(schema, "exclusiveMinimum") && compare(actual, decimal(hash_get(schema, "exclusiveMinimum"))) <= 0) return false;
    if (hash_has(schema, "multipleOf")) {
        VALUE divisor = decimal(hash_get(schema, "multipleOf"));
        if (!RTEST(rb_funcall(divisor, id_positive_p, 0))) return false;
        if (!RTEST(rb_funcall(rb_funcall(actual, id_remainder, 1, divisor), id_zero_p, 0))) return false;
    }
    return true;
}

typedef struct {
    bool valid;
    VALUE properties;
    VALUE items;
} evaluation_t;

static bool evaluate_valid(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance);
static bool evaluate_valid_raw(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance);
static evaluation_t evaluate_tracking(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance);
static evaluation_t evaluate_tracking_mode(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance, bool apply_unevaluated);
static evaluation_t evaluate_detailed(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance);

static evaluation_t
evaluation_new(bool valid)
{
    evaluation_t result = {valid, rb_ary_new(), rb_ary_new()};
    return result;
}

static bool
array_includes(VALUE array, VALUE value)
{
    return RTEST(rb_funcall(array, id_include_p, 1, value));
}

static void
array_add(VALUE array, VALUE value)
{
    if (!array_includes(array, value)) rb_ary_push(array, value);
}

static void
evaluation_merge(evaluation_t *left, evaluation_t right)
{
    long i;
    if (!right.valid) left->valid = false;
    if (!left->valid) return;
    for (i = 0; i < RARRAY_LEN(right.properties); i++) array_add(left->properties, rb_ary_entry(right.properties, i));
    for (i = 0; i < RARRAY_LEN(right.items); i++) array_add(left->items, rb_ary_entry(right.items, i));
}

static void
append_pointer_segment(VALUE pointer, VALUE segment)
{
    VALUE string = rb_funcall(segment, id_to_s, 0);
    string = rb_funcall(string, id_gsub, 2, key("~"), key("~0"));
    string = rb_funcall(string, id_gsub, 2, key("/"), key("~1"));
    rb_str_cat_cstr(pointer, "/");
    rb_str_append(pointer, string);
}

static VALUE
pointer_for(VALUE path, VALUE final_segment)
{
    VALUE pointer = rb_str_buf_new(0);
    long i;
    for (i = 0; i < RARRAY_LEN(path); i++) append_pointer_segment(pointer, rb_ary_entry(path, i));
    if (final_segment != Qundef) append_pointer_segment(pointer, final_segment);
    return pointer;
}

static void
add_error(schemurai_evaluator_t *evaluator, const char *keyword, VALUE message, bool append_keyword)
{
    VALUE arguments[1];
    VALUE options = rb_hash_new();
    rb_hash_aset(options, sym_keyword, key(keyword));
    rb_hash_aset(options, sym_instance_path, pointer_for(evaluator->instance_path, Qundef));
    rb_hash_aset(options, sym_schema_path, pointer_for(evaluator->schema_path, append_keyword ? key(keyword) : Qundef));
    rb_hash_aset(options, sym_message, message);
    arguments[0] = options;
    rb_ary_push(evaluator->errors, rb_funcallv_kw(cValidationError, id_new, 1, arguments, RB_PASS_KEYWORDS));
}

static evaluation_t
evaluate_detailed_at(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance,
    VALUE instance_segment, VALUE schema_segment, VALUE schema_child_segment)
{
    evaluation_t result;
    if (instance_segment != Qundef) rb_ary_push(evaluator->instance_path, instance_segment);
    rb_ary_push(evaluator->schema_path, schema_segment);
    if (schema_child_segment != Qundef) rb_ary_push(evaluator->schema_path, schema_child_segment);
    result = evaluate_detailed(evaluator, node, instance);
    if (schema_child_segment != Qundef) rb_ary_pop(evaluator->schema_path);
    rb_ary_pop(evaluator->schema_path);
    if (instance_segment != Qundef) rb_ary_pop(evaluator->instance_path);
    return result;
}

static evaluation_t
evaluate_detailed_reference(schemurai_evaluator_t *evaluator, VALUE source, VALUE target, VALUE instance, const char *keyword)
{
    VALUE source_id = rb_funcall(source, id_object_id, 0), instance_id = rb_funcall(instance, id_object_id, 0);
    VALUE instances = rb_hash_lookup2(evaluator->active, source_id, Qundef);
    evaluation_t result;
    if (instances == Qundef) { instances = rb_hash_new(); rb_hash_aset(evaluator->active, source_id, instances); }
    if (RTEST(rb_hash_lookup2(instances, instance_id, Qfalse))) return evaluation_new(true);
    rb_hash_aset(instances, instance_id, Qtrue);
    result = evaluate_detailed_at(evaluator, target, instance, Qundef, key(keyword), Qundef);
    rb_hash_delete(instances, instance_id);
    return result;
}

static VALUE
resolve_call(VALUE arguments)
{
    return rb_funcall(rb_ary_entry(arguments, 0), id_resolve, 2,
        rb_ary_entry(arguments, 1), rb_ary_entry(arguments, 2));
}

static VALUE
resolve_target(schemurai_evaluator_t *evaluator, VALUE node, VALUE reference, bool *failed)
{
    int state = 0;
    VALUE arguments = rb_ary_new_from_args(3, evaluator->graph, node, reference);
    VALUE target = rb_protect(resolve_call, arguments, &state);
    *failed = false;
    if (!state) return target;
    if (!rb_obj_is_kind_of(rb_errinfo(), cResolutionError)) rb_jump_tag(state);
    evaluator->resolution_error = rb_funcall(rb_errinfo(), id_message, 0);
    rb_set_errinfo(Qnil);
    *failed = true;
    return Qnil;
}

static bool
valid_reference(schemurai_evaluator_t *evaluator, VALUE source, VALUE target, VALUE instance)
{
    VALUE source_id = rb_funcall(source, id_object_id, 0);
    VALUE instance_id = rb_funcall(instance, id_object_id, 0);
    VALUE instances = rb_hash_lookup2(evaluator->active, source_id, Qundef);
    bool result;
    if (instances == Qundef) {
        instances = rb_hash_new();
        rb_hash_aset(evaluator->active, source_id, instances);
    }
    if (RTEST(rb_hash_lookup2(instances, instance_id, Qfalse))) return true;
    rb_hash_aset(instances, instance_id, Qtrue);
    result = evaluate_valid(evaluator, target, instance);
    rb_hash_delete(instances, instance_id);
    return result;
}

static VALUE
recursive_target(schemurai_evaluator_t *evaluator, VALUE node, VALUE reference, bool *failed)
{
    VALUE target = resolve_target(evaluator, node, reference, failed);
    VALUE schema;
    long i;
    if (*failed || !RTEST(rb_funcall(rb_funcall(reference, id_to_s, 0), id_end_with_p, 1, key("#")))) return target;
    schema = rb_funcall(target, id_schema, 0);
    if (!RB_TYPE_P(schema, T_HASH) || hash_get(schema, "$recursiveAnchor") != Qtrue) return target;
    for (i = 0; i < RARRAY_LEN(evaluator->dynamic_scope); i++) {
        VALUE root = rb_funcall(rb_ary_entry(evaluator->dynamic_scope, i), id_root, 0);
        VALUE root_schema = rb_funcall(root, id_schema, 0);
        if (RB_TYPE_P(root_schema, T_HASH) && hash_get(root_schema, "$recursiveAnchor") == Qtrue) return root;
    }
    return target;
}

static VALUE
dynamic_target(schemurai_evaluator_t *evaluator, VALUE node, VALUE reference, bool *failed)
{
    VALUE target = resolve_target(evaluator, node, reference, failed);
    VALUE string, parts, fragment, schema;
    long i;
    if (*failed) return target;
    string = rb_funcall(reference, id_to_s, 0);
    parts = rb_funcall(string, id_split, 2, key("#"), INT2NUM(2));
    if (RARRAY_LEN(parts) < 2) return target;
    fragment = rb_ary_entry(parts, 1);
    if (RSTRING_LEN(fragment) == 0 || RSTRING_PTR(fragment)[0] == '/') return target;
    schema = rb_funcall(target, id_schema, 0);
    if (!RB_TYPE_P(schema, T_HASH) || !RTEST(rb_equal(hash_get(schema, "$dynamicAnchor"), fragment))) return target;
    for (i = 0; i < RARRAY_LEN(evaluator->dynamic_scope); i++) {
        VALUE dynamic = rb_funcall(evaluator->graph, id_dynamic_anchor, 2, rb_ary_entry(evaluator->dynamic_scope, i), fragment);
        if (!NIL_P(dynamic)) return dynamic;
    }
    return target;
}

static bool
valid_combiners(schemurai_evaluator_t *evaluator, VALUE node, VALUE schema, VALUE value)
{
    long i, matches;
    VALUE list;
    if (hash_has(schema, "allOf")) {
        list = hash_get(schema, "allOf");
        for (i = 0; i < RARRAY_LEN(list); i++) if (!evaluate_valid(evaluator, node_child(node, "allOf", LONG2NUM(i)), value)) return false;
    }
    if (hash_has(schema, "anyOf")) {
        list = hash_get(schema, "anyOf");
        for (i = 0; i < RARRAY_LEN(list); i++) if (evaluate_valid(evaluator, node_child(node, "anyOf", LONG2NUM(i)), value)) break;
        if (i == RARRAY_LEN(list)) return false;
    }
    if (hash_has(schema, "oneOf")) {
        list = hash_get(schema, "oneOf"); matches = 0;
        for (i = 0; i < RARRAY_LEN(list); i++) if (evaluate_valid(evaluator, node_child(node, "oneOf", LONG2NUM(i)), value) && ++matches > 1) return false;
        if (matches != 1) return false;
    }
    if (hash_has(schema, "not") && evaluate_valid(evaluator, node_child(node, "not", Qnil), value)) return false;
    if (hash_has(schema, "if")) {
        const char *branch = evaluate_valid(evaluator, node_child(node, "if", Qnil), value) ? "then" : "else";
        if (hash_has(schema, branch) && !evaluate_valid(evaluator, node_child(node, branch, Qnil), value)) return false;
    }
    return true;
}

static bool
format_asserted(schemurai_evaluator_t *evaluator, VALUE node)
{
    VALUE dialect = rb_funcall(node, id_dialect, 0);
    VALUE format = rb_funcall(node, id_format, 0);
    return !NIL_P(format) && (evaluator->validate_format || RTEST(rb_funcall(dialect, id_format_assertion_p, 0)));
}

static VALUE
ecma_regexp(schemurai_evaluator_t *evaluator, VALUE pattern)
{
    static const char whitespace[] = "\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF";
    VALUE cached = rb_hash_lookup2(evaluator->regexps, pattern, Qundef);
    VALUE translated;
    const char *bytes;
    long index, length;
    bool escaped = false, in_class = false;
    if (cached != Qundef) return cached;
    translated = rb_str_buf_new(RSTRING_LEN(pattern) + 16);
    rb_enc_copy(translated, pattern);
    bytes = RSTRING_PTR(pattern); length = RSTRING_LEN(pattern);
    for (index = 0; index < length; index++) {
        char character = bytes[index];
        if (escaped) {
            switch (character) {
              case 'd': rb_str_cat_cstr(translated, in_class ? "0-9" : "[0-9]"); break;
              case 'D': rb_str_cat_cstr(translated, in_class ? "^0-9" : "[^0-9]"); break;
              case 'w': rb_str_cat_cstr(translated, in_class ? "A-Za-z0-9_" : "[A-Za-z0-9_]"); break;
              case 'W': rb_str_cat_cstr(translated, in_class ? "^A-Za-z0-9_" : "[^A-Za-z0-9_]"); break;
              case 's':
                if (!in_class) rb_str_cat_cstr(translated, "[");
                rb_str_cat_cstr(translated, whitespace);
                if (!in_class) rb_str_cat_cstr(translated, "]");
                break;
              case 'S':
                if (!in_class) rb_str_cat_cstr(translated, "[");
                rb_str_cat_cstr(translated, "^"); rb_str_cat_cstr(translated, whitespace);
                if (!in_class) rb_str_cat_cstr(translated, "]");
                break;
              default: rb_str_cat_cstr(translated, "\\"); rb_str_cat(translated, &character, 1); break;
            }
            escaped = false;
        } else if (character == '\\') {
            escaped = true;
        } else if (character == '[') {
            in_class = true; rb_str_cat(translated, &character, 1);
        } else if (character == ']') {
            in_class = false; rb_str_cat(translated, &character, 1);
        } else if (character == '^' && !in_class) {
            rb_str_cat_cstr(translated, "\\A");
        } else if (character == '$' && !in_class) {
            rb_str_cat_cstr(translated, "\\z");
        } else {
            rb_str_cat(translated, &character, 1);
        }
    }
    if (escaped) rb_str_cat_cstr(translated, "\\");
    cached = rb_reg_new_str(translated, 0);
    rb_hash_aset(evaluator->regexps, pattern, cached);
    return cached;
}

static VALUE
regexp_match_call(VALUE arguments)
{
    schemurai_evaluator_t *evaluator;
    TypedData_Get_Struct(rb_ary_entry(arguments, 0), schemurai_evaluator_t, &evaluator_type, evaluator);
    return rb_funcall(ecma_regexp(evaluator, rb_ary_entry(arguments, 1)), id_match_p, 1, rb_ary_entry(arguments, 2));
}

static bool
regexp_matches(schemurai_evaluator_t *evaluator, VALUE pattern, VALUE value, bool *invalid)
{
    int state = 0;
    VALUE result = rb_protect(regexp_match_call, rb_ary_new_from_args(3, evaluator->self, pattern, value), &state);
    *invalid = false;
    if (!state) return RTEST(result);
    if (!rb_obj_is_kind_of(rb_errinfo(), cRegexpError)) rb_jump_tag(state);
    rb_set_errinfo(Qnil); *invalid = true; return false;
}

static VALUE
content_call(VALUE arguments)
{
    VALUE schema = rb_ary_entry(arguments, 0);
    VALUE decoded = rb_ary_entry(arguments, 1);
    if (RTEST(rb_equal(hash_get(schema, "contentEncoding"), key("base64")))) {
        decoded = rb_funcall(mBase64, id_strict_decode64, 1, decoded);
    }
    if (RTEST(rb_equal(hash_get(schema, "contentMediaType"), key("application/json")))) {
        rb_funcall(mJSON, id_parse, 1, decoded);
    }
    return Qtrue;
}

static bool
valid_content(VALUE schema, VALUE value)
{
    int state = 0;
    rb_protect(content_call, rb_ary_new_from_args(2, schema, value), &state);
    if (!state) return true;
    if (!rb_obj_is_kind_of(rb_errinfo(), rb_eArgError) && !rb_obj_is_kind_of(rb_errinfo(), cJSONParserError)) rb_jump_tag(state);
    rb_set_errinfo(Qnil);
    return false;
}

static bool
valid_string(schemurai_evaluator_t *evaluator, VALUE node, VALUE schema, VALUE value)
{
    long length = NUM2LONG(rb_funcall(value, id_length, 0));
    if (hash_has(schema, "maxLength") && length > NUM2LONG(hash_get(schema, "maxLength"))) return false;
    if (hash_has(schema, "minLength") && length < NUM2LONG(hash_get(schema, "minLength"))) return false;
    if (hash_has(schema, "pattern")) {
        bool invalid;
        if (!regexp_matches(evaluator, hash_get(schema, "pattern"), value, &invalid)) return false;
    }
    if (format_asserted(evaluator, node) && !RTEST(rb_funcall(rb_funcall(node, id_format, 0), id_call, 1, value))) return false;
    if (evaluator->validate_content && !valid_content(schema, value)) return false;
    return true;
}

static bool
valid_array(schemurai_evaluator_t *evaluator, VALUE node, VALUE schema, VALUE value)
{
    long i, j, length = RARRAY_LEN(value), start = 0;
    VALUE items, prefix, child;
    if (hash_has(schema, "maxItems") && length > NUM2LONG(hash_get(schema, "maxItems"))) return false;
    if (hash_has(schema, "minItems") && length < NUM2LONG(hash_get(schema, "minItems"))) return false;
    if (RTEST(hash_get(schema, "uniqueItems"))) {
        for (i = 0; i < length; i++) for (j = 0; j < i; j++) if (json_equal(rb_ary_entry(value, j), rb_ary_entry(value, i))) return false;
    }
    prefix = hash_get(schema, "prefixItems");
    if (RB_TYPE_P(prefix, T_ARRAY)) {
        for (i = 0; i < RARRAY_LEN(prefix) && i < length; i++) if (!evaluate_valid(evaluator, node_child(node, "prefixItems", LONG2NUM(i)), rb_ary_entry(value, i))) return false;
        start = RARRAY_LEN(prefix);
    }
    items = hash_get(schema, "items");
    if (RB_TYPE_P(items, T_ARRAY)) {
        for (i = 0; i < RARRAY_LEN(items) && i < length; i++) if (!evaluate_valid(evaluator, node_child(node, "items", LONG2NUM(i)), rb_ary_entry(value, i))) return false;
        if (length > RARRAY_LEN(items) && hash_has(schema, "additionalItems")) {
            child = node_child(node, "additionalItems", Qnil);
            for (i = RARRAY_LEN(items); i < length; i++) if (!evaluate_valid(evaluator, child, rb_ary_entry(value, i))) return false;
        }
    } else if (!NIL_P(items)) {
        child = node_child(node, "items", Qnil);
        for (i = start; i < length; i++) if (!evaluate_valid(evaluator, child, rb_ary_entry(value, i))) return false;
    }
    if (hash_has(schema, "contains")) {
        long matches = 0;
        child = node_child(node, "contains", Qnil);
        for (i = 0; i < length; i++) if (evaluate_valid(evaluator, child, rb_ary_entry(value, i))) matches++;
        if (matches < (hash_has(schema, "minContains") ? NUM2LONG(hash_get(schema, "minContains")) : 1)) return false;
        if (hash_has(schema, "maxContains") && matches > NUM2LONG(hash_get(schema, "maxContains"))) return false;
    }
    return true;
}

static bool
valid_object_property(schemurai_evaluator_t *evaluator, VALUE node, VALUE schema, VALUE name, VALUE item)
{
    VALUE properties = hash_get(schema, "properties"), patterns = hash_get(schema, "patternProperties");
    bool matched = false;
    long index;
    if (RB_TYPE_P(properties, T_HASH) && RTEST(rb_funcall(properties, id_key_p, 1, name))) {
        matched = true;
        if (!evaluate_valid(evaluator, node_child(node, "properties", name), item)) return false;
    }
    if (RB_TYPE_P(patterns, T_HASH)) {
        VALUE pattern_names = rb_funcall(patterns, id_keys, 0);
        for (index = 0; index < RARRAY_LEN(pattern_names); index++) {
            VALUE pattern = rb_ary_entry(pattern_names, index);
            if (!RTEST(rb_funcall(ecma_regexp(evaluator, pattern), id_match_p, 1, name))) continue;
            matched = true;
            if (!evaluate_valid(evaluator, node_child(node, "patternProperties", pattern), item)) return false;
        }
    }
    return matched || !hash_has(schema, "additionalProperties") ||
        evaluate_valid(evaluator, node_child(node, "additionalProperties", Qnil), item);
}

static VALUE
valid_object_each(RB_BLOCK_CALL_FUNC_ARGLIST(yielded, callback_argument))
{
    VALUE context = callback_argument;
    VALUE name = argc >= 2 ? argv[0] : rb_ary_entry(yielded, 0);
    VALUE item = argc >= 2 ? argv[1] : rb_ary_entry(yielded, 1);
    schemurai_evaluator_t *evaluator;
    (void)blockarg;
    TypedData_Get_Struct(rb_ary_entry(context, 0), schemurai_evaluator_t, &evaluator_type, evaluator);
    if (!valid_object_property(evaluator, rb_ary_entry(context, 1), rb_ary_entry(context, 2),
        name, item)) rb_iter_break_value(Qfalse);
    return Qtrue;
}

static bool
valid_object(schemurai_evaluator_t *evaluator, VALUE node, VALUE schema, VALUE value)
{
    VALUE names = rb_funcall(value, id_keys, 0);
    long i, j, length = RARRAY_LEN(names);
    if (hash_has(schema, "maxProperties") && length > NUM2LONG(hash_get(schema, "maxProperties"))) return false;
    if (hash_has(schema, "minProperties") && length < NUM2LONG(hash_get(schema, "minProperties"))) return false;
    if (hash_has(schema, "required")) {
        VALUE required = hash_get(schema, "required");
        for (i = 0; i < RARRAY_LEN(required); i++) if (!RTEST(rb_funcall(value, id_key_p, 1, rb_ary_entry(required, i)))) return false;
    }
    if (rb_obj_class(value) != rb_cHash) {
        VALUE context = rb_ary_new_from_args(3, evaluator->self, node, schema);
        if (rb_block_call(value, id_each, 0, NULL, valid_object_each, context) == Qfalse) return false;
        names = rb_funcall(value, id_keys, 0);
        length = RARRAY_LEN(names);
    } else {
        for (i = 0; i < length; i++) {
            VALUE name = rb_ary_entry(names, i);
            if (!valid_object_property(evaluator, node, schema, name, rb_hash_aref(value, name))) return false;
        }
    }
    if (hash_has(schema, "propertyNames")) {
        VALUE child = node_child(node, "propertyNames", Qnil);
        for (i = 0; i < length; i++) if (!evaluate_valid(evaluator, child, rb_ary_entry(names, i))) return false;
    }
    if (hash_has(schema, "dependencies")) {
        VALUE dependencies = hash_get(schema, "dependencies");
        VALUE dependency_names = rb_funcall(dependencies, id_keys, 0);
        for (i = 0; i < RARRAY_LEN(dependency_names); i++) {
            VALUE name = rb_ary_entry(dependency_names, i), dependency;
            if (!RTEST(rb_funcall(value, id_key_p, 1, name))) continue;
            dependency = rb_hash_aref(dependencies, name);
            if (RB_TYPE_P(dependency, T_ARRAY)) {
                for (j = 0; j < RARRAY_LEN(dependency); j++) {
                    if (!RTEST(rb_funcall(value, id_key_p, 1, rb_ary_entry(dependency, j)))) return false;
                }
            } else if (!evaluate_valid(evaluator, node_child(node, "dependencies", name), value)) return false;
        }
    }
    if (hash_has(schema, "dependentRequired")) {
        VALUE dependencies = hash_get(schema, "dependentRequired");
        VALUE dependency_names = rb_funcall(dependencies, id_keys, 0);
        for (i = 0; i < RARRAY_LEN(dependency_names); i++) {
            VALUE name = rb_ary_entry(dependency_names, i), required;
            if (!RTEST(rb_funcall(value, id_key_p, 1, name))) continue;
            required = rb_hash_aref(dependencies, name);
            for (j = 0; j < RARRAY_LEN(required); j++) {
                if (!RTEST(rb_funcall(value, id_key_p, 1, rb_ary_entry(required, j)))) return false;
            }
        }
    }
    if (hash_has(schema, "dependentSchemas")) {
        VALUE dependencies = hash_get(schema, "dependentSchemas");
        VALUE dependency_names = rb_funcall(dependencies, id_keys, 0);
        for (i = 0; i < RARRAY_LEN(dependency_names); i++) {
            VALUE name = rb_ary_entry(dependency_names, i);
            if (RTEST(rb_funcall(value, id_key_p, 1, name)) &&
                !evaluate_valid(evaluator, node_child(node, "dependentSchemas", name), value)) return false;
        }
    }
    return true;
}

static bool
evaluate_valid_raw(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance)
{
    VALUE schema = rb_funcall(node, id_schema, 0);
    VALUE resource = Qnil, target;
    unsigned long mask;
    bool entered_scope = false, failed = false, result = true;
    if (schema == Qtrue || schema == Qfalse) return schema == Qtrue;
    if (!RB_TYPE_P(schema, T_HASH)) return true;
    if (RTEST(rb_funcall(evaluator->graph, id_dynamic_scope_p, 0))) {
        resource = rb_funcall(node, id_resource, 0);
        entered_scope = RARRAY_LEN(evaluator->dynamic_scope) == 0 || rb_ary_entry(evaluator->dynamic_scope, -1) != resource;
        if (entered_scope) rb_ary_push(evaluator->dynamic_scope, resource);
    }
    if (hash_has(schema, "$ref")) {
        target = resolve_target(evaluator, node, hash_get(schema, "$ref"), &failed);
        if (failed || !valid_reference(evaluator, node, target, instance)) { result = false; goto done; }
        if (!RTEST(rb_funcall(rb_funcall(node, id_dialect, 0), id_ref_siblings_p, 0))) goto done;
    }
    if (hash_has(schema, "$recursiveRef")) {
        target = recursive_target(evaluator, node, hash_get(schema, "$recursiveRef"), &failed);
        if (failed || !valid_reference(evaluator, node, target, instance)) { result = false; goto done; }
    }
    if (hash_has(schema, "$dynamicRef")) {
        target = dynamic_target(evaluator, node, hash_get(schema, "$dynamicRef"), &failed);
        if (failed || !valid_reference(evaluator, node, target, instance)) { result = false; goto done; }
    }
    mask = NUM2ULONG(rb_funcall(node, id_keyword_mask, 0));
    if ((mask & 1UL) && !valid_type(schema, instance)) { result = false; goto done; }
    if ((mask & 2UL) && !valid_enum(schema, instance)) { result = false; goto done; }
    if ((mask & 4UL) && !valid_combiners(evaluator, node, schema, instance)) { result = false; goto done; }
    if (rb_obj_is_kind_of(instance, rb_cHash)) { result = !(mask & 64UL) || valid_object(evaluator, node, schema, instance); goto done; }
    if (rb_obj_is_kind_of(instance, rb_cArray)) { result = !(mask & 32UL) || valid_array(evaluator, node, schema, instance); goto done; }
    if (rb_obj_is_kind_of(instance, rb_cString)) {
        result = (mask & 16UL) ? valid_string(evaluator, node, schema, instance) :
            (!format_asserted(evaluator, node) || RTEST(rb_funcall(rb_funcall(node, id_format, 0), id_call, 1, instance)));
        goto done;
    }
    if (number_p(instance) && !rb_obj_is_kind_of(instance, rb_cComplex)) result = !(mask & 8UL) || valid_number(schema, instance);
done:
    if (entered_scope) rb_ary_pop(evaluator->dynamic_scope);
    return result;
}

static evaluation_t
tracking_reference(schemurai_evaluator_t *evaluator, VALUE source, VALUE target, VALUE instance)
{
    VALUE source_id = rb_funcall(source, id_object_id, 0);
    VALUE instance_id = rb_funcall(instance, id_object_id, 0);
    VALUE instances = rb_hash_lookup2(evaluator->active, source_id, Qundef);
    evaluation_t result;
    if (instances == Qundef) {
        instances = rb_hash_new();
        rb_hash_aset(evaluator->active, source_id, instances);
    }
    if (RTEST(rb_hash_lookup2(instances, instance_id, Qfalse))) return evaluation_new(true);
    rb_hash_aset(instances, instance_id, Qtrue);
    result = evaluate_tracking(evaluator, target, instance);
    rb_hash_delete(instances, instance_id);
    return result;
}

static evaluation_t
evaluate_tracking_mode(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance, bool apply_unevaluated)
{
    VALUE schema = rb_funcall(node, id_schema, 0);
    VALUE resource = Qnil, target, list, names;
    evaluation_t result = evaluation_new(true), child_result;
    bool entered_scope = false, failed = false;
    long i, j;
    if (schema == Qfalse) { result.valid = false; return result; }
    if (schema == Qtrue || !RB_TYPE_P(schema, T_HASH)) return result;
    if (!evaluate_valid_raw(evaluator, node, instance)) {
        result.valid = false;
        if (apply_unevaluated) return result;
    }

    if (RTEST(rb_funcall(evaluator->graph, id_dynamic_scope_p, 0))) {
        resource = rb_funcall(node, id_resource, 0);
        entered_scope = RARRAY_LEN(evaluator->dynamic_scope) == 0 || rb_ary_entry(evaluator->dynamic_scope, -1) != resource;
        if (entered_scope) rb_ary_push(evaluator->dynamic_scope, resource);
    }
    if (hash_has(schema, "$ref")) {
        target = resolve_target(evaluator, node, hash_get(schema, "$ref"), &failed);
        if (failed) { result.valid = false; goto done; }
        evaluation_merge(&result, tracking_reference(evaluator, node, target, instance));
        if (!RTEST(rb_funcall(rb_funcall(node, id_dialect, 0), id_ref_siblings_p, 0))) goto unevaluated;
    }
    if (hash_has(schema, "$recursiveRef")) {
        target = recursive_target(evaluator, node, hash_get(schema, "$recursiveRef"), &failed);
        if (failed) { result.valid = false; goto done; }
        evaluation_merge(&result, tracking_reference(evaluator, node, target, instance));
    }
    if (hash_has(schema, "$dynamicRef")) {
        target = dynamic_target(evaluator, node, hash_get(schema, "$dynamicRef"), &failed);
        if (failed) { result.valid = false; goto done; }
        evaluation_merge(&result, tracking_reference(evaluator, node, target, instance));
    }
    if (hash_has(schema, "allOf")) {
        list = hash_get(schema, "allOf");
        for (i = 0; i < RARRAY_LEN(list); i++) evaluation_merge(&result, evaluate_tracking(evaluator, node_child(node, "allOf", LONG2NUM(i)), instance));
    }
    if (hash_has(schema, "anyOf")) {
        list = hash_get(schema, "anyOf");
        for (i = 0; i < RARRAY_LEN(list); i++) {
            child_result = evaluate_tracking(evaluator, node_child(node, "anyOf", LONG2NUM(i)), instance);
            if (child_result.valid) evaluation_merge(&result, child_result);
        }
    }
    if (hash_has(schema, "oneOf")) {
        evaluation_t match = evaluation_new(true); long matches = 0;
        list = hash_get(schema, "oneOf");
        for (i = 0; i < RARRAY_LEN(list); i++) {
            child_result = evaluate_tracking(evaluator, node_child(node, "oneOf", LONG2NUM(i)), instance);
            if (child_result.valid) { match = child_result; matches++; }
        }
        if (matches == 1) evaluation_merge(&result, match);
    }
    if (hash_has(schema, "if")) {
        child_result = evaluate_tracking(evaluator, node_child(node, "if", Qnil), instance);
        if (child_result.valid) evaluation_merge(&result, child_result);
        const char *branch = child_result.valid ? "then" : "else";
        if (hash_has(schema, branch)) evaluation_merge(&result, evaluate_tracking(evaluator, node_child(node, branch, Qnil), instance));
    }

    if (rb_obj_is_kind_of(instance, rb_cArray)) {
        long length = RARRAY_LEN(instance), start = 0;
        VALUE prefix = hash_get(schema, "prefixItems"), items = hash_get(schema, "items");
        if (RB_TYPE_P(prefix, T_ARRAY)) {
            for (i = 0; i < RARRAY_LEN(prefix) && i < length; i++) array_add(result.items, LONG2NUM(i));
            start = RARRAY_LEN(prefix);
        }
        if (RB_TYPE_P(items, T_ARRAY)) {
            for (i = 0; i < RARRAY_LEN(items) && i < length; i++) array_add(result.items, LONG2NUM(i));
            if (length > RARRAY_LEN(items) && hash_has(schema, "additionalItems")) {
                for (i = RARRAY_LEN(items); i < length; i++) array_add(result.items, LONG2NUM(i));
            }
        } else if (!NIL_P(items)) {
            for (i = start; i < length; i++) array_add(result.items, LONG2NUM(i));
        }
        if (hash_has(schema, "contains")) {
            VALUE contains = node_child(node, "contains", Qnil);
            for (i = 0; i < length; i++) if (evaluate_valid(evaluator, contains, rb_ary_entry(instance, i))) array_add(result.items, LONG2NUM(i));
        }
    }

    if (rb_obj_is_kind_of(instance, rb_cHash)) {
        VALUE properties = hash_get(schema, "properties"), patterns = hash_get(schema, "patternProperties");
        names = rb_funcall(instance, id_keys, 0);
        for (i = 0; i < RARRAY_LEN(names); i++) {
            VALUE name = rb_ary_entry(names, i); bool matched = false;
            if (RB_TYPE_P(properties, T_HASH) && RTEST(rb_funcall(properties, id_key_p, 1, name))) matched = true;
            if (RB_TYPE_P(patterns, T_HASH)) {
                VALUE pattern_names = rb_funcall(patterns, id_keys, 0);
                for (j = 0; j < RARRAY_LEN(pattern_names); j++) {
                    if (RTEST(rb_funcall(ecma_regexp(evaluator, rb_ary_entry(pattern_names, j)), id_match_p, 1, name))) matched = true;
                }
            }
            if (!matched && hash_has(schema, "additionalProperties")) matched = true;
            if (matched) array_add(result.properties, name);
        }
        if (hash_has(schema, "dependencies")) {
            VALUE dependencies = hash_get(schema, "dependencies"); names = rb_funcall(dependencies, id_keys, 0);
            for (i = 0; i < RARRAY_LEN(names); i++) {
                VALUE name = rb_ary_entry(names, i), dependency = rb_hash_aref(dependencies, name);
                if (!RB_TYPE_P(dependency, T_ARRAY) && RTEST(rb_funcall(instance, id_key_p, 1, name))) {
                    child_result = evaluate_tracking(evaluator, node_child(node, "dependencies", name), instance);
                    if (child_result.valid) evaluation_merge(&result, child_result);
                }
            }
        }
        if (hash_has(schema, "dependentSchemas")) {
            VALUE dependencies = hash_get(schema, "dependentSchemas"); names = rb_funcall(dependencies, id_keys, 0);
            for (i = 0; i < RARRAY_LEN(names); i++) {
                VALUE name = rb_ary_entry(names, i);
                if (RTEST(rb_funcall(instance, id_key_p, 1, name))) {
                    child_result = evaluate_tracking(evaluator, node_child(node, "dependentSchemas", name), instance);
                    if (child_result.valid) evaluation_merge(&result, child_result);
                }
            }
        }
    }

unevaluated:
    if (apply_unevaluated && result.valid && rb_obj_is_kind_of(instance, rb_cArray) && hash_has(schema, "unevaluatedItems")) {
        VALUE child = node_child(node, "unevaluatedItems", Qnil);
        for (i = 0; i < RARRAY_LEN(instance); i++) {
            VALUE index = LONG2NUM(i);
            if (!array_includes(result.items, index)) {
                if (!evaluate_valid(evaluator, child, rb_ary_entry(instance, i))) result.valid = false;
                array_add(result.items, index);
            }
        }
    }
    if (apply_unevaluated && result.valid && rb_obj_is_kind_of(instance, rb_cHash) && hash_has(schema, "unevaluatedProperties")) {
        VALUE child = node_child(node, "unevaluatedProperties", Qnil); names = rb_funcall(instance, id_keys, 0);
        for (i = 0; i < RARRAY_LEN(names); i++) {
            VALUE name = rb_ary_entry(names, i);
            if (!array_includes(result.properties, name)) {
                if (!evaluate_valid(evaluator, child, rb_hash_aref(instance, name))) result.valid = false;
                array_add(result.properties, name);
            }
        }
    }
done:
    if (entered_scope) rb_ary_pop(evaluator->dynamic_scope);
    return result;
}

static evaluation_t
evaluate_tracking(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance)
{
    return evaluate_tracking_mode(evaluator, node, instance, true);
}

static bool
evaluate_valid(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance)
{
    VALUE schema = rb_funcall(node, id_schema, 0);
    if (RB_TYPE_P(schema, T_HASH) && (hash_has(schema, "unevaluatedProperties") || hash_has(schema, "unevaluatedItems"))) {
        return evaluate_tracking(evaluator, node, instance).valid;
    }
    return evaluate_valid_raw(evaluator, node, instance);
}

static evaluation_t
evaluate_detailed(schemurai_evaluator_t *evaluator, VALUE node, VALUE instance)
{
    VALUE schema = rb_funcall(node, id_schema, 0), target, list;
    VALUE resource = Qnil;
    evaluation_t annotations;
    long before = RARRAY_LEN(evaluator->errors), i, matches;
    unsigned long mask;
    bool failed = false, entered_scope = false;
    if (schema == Qtrue) return evaluation_new(true);
    if (schema == Qfalse) {
        add_error(evaluator, "falseSchema", key("boolean schema is false"), false);
        return evaluation_new(false);
    }
    if (!RB_TYPE_P(schema, T_HASH)) return evaluation_new(true);
    mask = NUM2ULONG(rb_funcall(node, id_keyword_mask, 0));
    if (RTEST(rb_funcall(evaluator->graph, id_dynamic_scope_p, 0))) {
        resource = rb_funcall(node, id_resource, 0);
        entered_scope = RARRAY_LEN(evaluator->dynamic_scope) == 0 || rb_ary_entry(evaluator->dynamic_scope, -1) != resource;
        if (entered_scope) rb_ary_push(evaluator->dynamic_scope, resource);
    }

    if (hash_has(schema, "$ref")) {
        target = resolve_target(evaluator, node, hash_get(schema, "$ref"), &failed);
        if (failed) add_error(evaluator, "$ref", evaluator->resolution_error, false);
        else evaluate_detailed_reference(evaluator, node, target, instance, "$ref");
        if (!RTEST(rb_funcall(rb_funcall(node, id_dialect, 0), id_ref_siblings_p, 0))) goto finish;
    }
    if (hash_has(schema, "$recursiveRef")) {
        target = recursive_target(evaluator, node, hash_get(schema, "$recursiveRef"), &failed);
        if (!failed) evaluate_detailed_reference(evaluator, node, target, instance, "$recursiveRef");
    }
    if (hash_has(schema, "$dynamicRef")) {
        target = dynamic_target(evaluator, node, hash_get(schema, "$dynamicRef"), &failed);
        if (!failed) evaluate_detailed_reference(evaluator, node, target, instance, "$dynamicRef");
    }

    if ((mask & 1UL) && hash_has(schema, "type") && !valid_type(schema, instance)) {
        VALUE types = hash_get(schema, "type");
        VALUE array = RB_TYPE_P(types, T_ARRAY) ? types : rb_ary_new_from_args(1, types);
        add_error(evaluator, "type", rb_sprintf("expected %"PRIsVALUE, rb_ary_join(array, key(" or "))), true);
    }
    if ((mask & 2UL) && hash_has(schema, "enum")) {
        VALUE values = hash_get(schema, "enum"); bool found = false;
        for (i = 0; i < RARRAY_LEN(values); i++) if (json_equal(rb_ary_entry(values, i), instance)) { found = true; break; }
        if (!found) add_error(evaluator, "enum", key("value is not in enum"), true);
    }
    if ((mask & 2UL) && hash_has(schema, "const") && !json_equal(hash_get(schema, "const"), instance)) add_error(evaluator, "const", key("value does not equal const"), true);

    if ((mask & 4UL) && hash_has(schema, "allOf")) {
        list = hash_get(schema, "allOf");
        for (i = 0; i < RARRAY_LEN(list); i++) evaluate_detailed_at(evaluator, node_child(node, "allOf", LONG2NUM(i)), instance, Qundef, key("allOf"), LONG2NUM(i));
    }
    if ((mask & 4UL) && hash_has(schema, "anyOf")) {
        list = hash_get(schema, "anyOf"); matches = 0;
        for (i = 0; i < RARRAY_LEN(list); i++) if (evaluate_tracking(evaluator, node_child(node, "anyOf", LONG2NUM(i)), instance).valid) matches++;
        if (matches == 0) add_error(evaluator, "anyOf", key("no subschema matched"), true);
    }
    if ((mask & 4UL) && hash_has(schema, "oneOf")) {
        list = hash_get(schema, "oneOf"); matches = 0;
        for (i = 0; i < RARRAY_LEN(list); i++) if (evaluate_tracking(evaluator, node_child(node, "oneOf", LONG2NUM(i)), instance).valid) matches++;
        if (matches != 1) add_error(evaluator, "oneOf", rb_sprintf("expected exactly one match, got %ld", matches), true);
    }
    if ((mask & 4UL) && hash_has(schema, "not") && evaluate_tracking(evaluator, node_child(node, "not", Qnil), instance).valid) add_error(evaluator, "not", key("subschema matched"), true);
    if ((mask & 4UL) && hash_has(schema, "if")) {
        bool condition = evaluate_tracking(evaluator, node_child(node, "if", Qnil), instance).valid;
        const char *branch = condition ? "then" : "else";
        if (hash_has(schema, branch)) evaluate_detailed_at(evaluator, node_child(node, branch, Qnil), instance, Qundef, key(branch), Qundef);
    }

    if ((mask & 8UL) && number_p(instance) && !rb_obj_is_kind_of(instance, rb_cComplex)) {
        VALUE actual = decimal(instance), expected;
#define NUMERIC_LIMIT(keyword, invalid) do { \
        if (hash_has(schema, keyword)) { expected = decimal(hash_get(schema, keyword)); \
            if (invalid) add_error(evaluator, keyword, key("numeric limit was exceeded"), true); } \
        } while (0)
        NUMERIC_LIMIT("maximum", compare(actual, expected) > 0);
        NUMERIC_LIMIT("minimum", compare(actual, expected) < 0);
        NUMERIC_LIMIT("exclusiveMaximum", compare(actual, expected) >= 0);
        NUMERIC_LIMIT("exclusiveMinimum", compare(actual, expected) <= 0);
#undef NUMERIC_LIMIT
        if (hash_has(schema, "multipleOf")) {
            VALUE divisor = decimal(hash_get(schema, "multipleOf"));
            if (!RTEST(rb_funcall(divisor, id_positive_p, 0)) || !RTEST(rb_funcall(rb_funcall(actual, id_remainder, 1, divisor), id_zero_p, 0)))
                add_error(evaluator, "multipleOf", key("number is not a multiple"), true);
        }
    }
    if (rb_obj_is_kind_of(instance, rb_cString) && ((mask & 16UL) || format_asserted(evaluator, node))) {
        long length = NUM2LONG(rb_funcall(instance, id_length, 0));
        if (hash_has(schema, "maxLength") && length > NUM2LONG(hash_get(schema, "maxLength"))) add_error(evaluator, "maxLength", key("size limit was exceeded"), true);
        if (hash_has(schema, "minLength") && length < NUM2LONG(hash_get(schema, "minLength"))) add_error(evaluator, "minLength", key("size limit was exceeded"), true);
        if (hash_has(schema, "pattern")) {
            bool invalid;
            bool matched = regexp_matches(evaluator, hash_get(schema, "pattern"), instance, &invalid);
            if (invalid) add_error(evaluator, "pattern", key("invalid regular expression"), true);
            else if (!matched) add_error(evaluator, "pattern", key("string does not match pattern"), true);
        }
        if (format_asserted(evaluator, node) && !RTEST(rb_funcall(rb_funcall(node, id_format, 0), id_call, 1, instance))) {
            VALUE name = rb_funcall(rb_funcall(node, id_format, 0), id_name, 0);
            add_error(evaluator, "format", rb_sprintf("string is not a valid %"PRIsVALUE, name), true);
        }
        if (evaluator->validate_content && !valid_content(schema, instance)) {
            const char *keyword = RTEST(rb_equal(hash_get(schema, "contentEncoding"), key("base64"))) ? "contentEncoding" : "contentMediaType";
            add_error(evaluator, keyword, key("string content is invalid"), true);
        }
    }
    if ((mask & 32UL) && rb_obj_is_kind_of(instance, rb_cArray)) {
        long length = RARRAY_LEN(instance), j, start = 0;
        VALUE prefix, items, child;
        if (hash_has(schema, "maxItems") && length > NUM2LONG(hash_get(schema, "maxItems"))) add_error(evaluator, "maxItems", key("size limit was exceeded"), true);
        if (hash_has(schema, "minItems") && length < NUM2LONG(hash_get(schema, "minItems"))) add_error(evaluator, "minItems", key("size limit was exceeded"), true);
        if (RTEST(hash_get(schema, "uniqueItems"))) {
            bool duplicate = false;
            for (i = 0; i < length && !duplicate; i++) for (j = 0; j < i; j++) if (json_equal(rb_ary_entry(instance, j), rb_ary_entry(instance, i))) { duplicate = true; break; }
            if (duplicate) add_error(evaluator, "uniqueItems", key("array items are not unique"), true);
        }
        prefix = hash_get(schema, "prefixItems");
        if (RB_TYPE_P(prefix, T_ARRAY)) {
            for (i = 0; i < RARRAY_LEN(prefix) && i < length; i++) evaluate_detailed_at(evaluator, node_child(node, "prefixItems", LONG2NUM(i)), rb_ary_entry(instance, i), LONG2NUM(i), key("prefixItems"), LONG2NUM(i));
            start = RARRAY_LEN(prefix);
        }
        items = hash_get(schema, "items");
        if (RB_TYPE_P(items, T_ARRAY)) {
            for (i = 0; i < RARRAY_LEN(items) && i < length; i++) evaluate_detailed_at(evaluator, node_child(node, "items", LONG2NUM(i)), rb_ary_entry(instance, i), LONG2NUM(i), key("items"), LONG2NUM(i));
            if (length > RARRAY_LEN(items) && hash_has(schema, "additionalItems")) {
                child = node_child(node, "additionalItems", Qnil);
                for (i = RARRAY_LEN(items); i < length; i++) evaluate_detailed_at(evaluator, child, rb_ary_entry(instance, i), LONG2NUM(i), key("additionalItems"), Qundef);
            }
        } else if (!NIL_P(items)) {
            child = node_child(node, "items", Qnil);
            for (i = start; i < length; i++) evaluate_detailed_at(evaluator, child, rb_ary_entry(instance, i), LONG2NUM(i), key("items"), Qundef);
        }
        if (hash_has(schema, "contains")) {
            child = node_child(node, "contains", Qnil); matches = 0;
            for (i = 0; i < length; i++) if (evaluate_tracking(evaluator, child, rb_ary_entry(instance, i)).valid) matches++;
            long minimum = hash_has(schema, "minContains") ? NUM2LONG(hash_get(schema, "minContains")) : 1;
            long maximum = hash_has(schema, "maxContains") ? NUM2LONG(hash_get(schema, "maxContains")) : LONG_MAX;
            if (matches < minimum || matches > maximum) add_error(evaluator, "contains", rb_sprintf("matched %ld array items", matches), true);
        }
    }
    if ((mask & 64UL) && rb_obj_is_kind_of(instance, rb_cHash)) {
        VALUE names = rb_funcall(instance, id_keys, 0);
        VALUE required = hash_get(schema, "required");
        VALUE properties = hash_get(schema, "properties"), patterns = hash_get(schema, "patternProperties");
        long length = RARRAY_LEN(names), j;
        if (hash_has(schema, "maxProperties") && length > NUM2LONG(hash_get(schema, "maxProperties"))) add_error(evaluator, "maxProperties", key("size limit was exceeded"), true);
        if (hash_has(schema, "minProperties") && length < NUM2LONG(hash_get(schema, "minProperties"))) add_error(evaluator, "minProperties", key("size limit was exceeded"), true);
        if (!NIL_P(required)) for (i = 0; i < RARRAY_LEN(required); i++) {
            VALUE name = rb_ary_entry(required, i);
            if (!RTEST(rb_funcall(instance, id_key_p, 1, name))) add_error(evaluator, "required", rb_sprintf("required property %"PRIsVALUE" is missing", rb_inspect(name)), true);
        }
        for (i = 0; i < length; i++) {
            VALUE name = rb_ary_entry(names, i), item = rb_hash_aref(instance, name); bool matched = false;
            if (RB_TYPE_P(properties, T_HASH) && RTEST(rb_funcall(properties, id_key_p, 1, name))) {
                matched = true; evaluate_detailed_at(evaluator, node_child(node, "properties", name), item, name, key("properties"), name);
            }
            if (RB_TYPE_P(patterns, T_HASH)) {
                VALUE pattern_names = rb_funcall(patterns, id_keys, 0);
                for (j = 0; j < RARRAY_LEN(pattern_names); j++) {
                    VALUE pattern = rb_ary_entry(pattern_names, j);
                    if (RTEST(rb_funcall(ecma_regexp(evaluator, pattern), id_match_p, 1, name))) {
                        matched = true; evaluate_detailed_at(evaluator, node_child(node, "patternProperties", pattern), item, name, key("patternProperties"), pattern);
                    }
                }
            }
            if (!matched && hash_has(schema, "additionalProperties")) evaluate_detailed_at(evaluator, node_child(node, "additionalProperties", Qnil), item, name, key("additionalProperties"), Qundef);
        }
        if (hash_has(schema, "propertyNames")) for (i = 0; i < length; i++) {
            VALUE name = rb_ary_entry(names, i); evaluate_detailed_at(evaluator, node_child(node, "propertyNames", Qnil), name, name, key("propertyNames"), Qundef);
        }
        if (hash_has(schema, "dependencies")) {
            VALUE dependencies = hash_get(schema, "dependencies"), dependency_names = rb_funcall(dependencies, id_keys, 0);
            for (i = 0; i < RARRAY_LEN(dependency_names); i++) {
                VALUE name = rb_ary_entry(dependency_names, i), dependency;
                if (!RTEST(rb_funcall(instance, id_key_p, 1, name))) continue;
                dependency = rb_hash_aref(dependencies, name);
                if (RB_TYPE_P(dependency, T_ARRAY)) for (j = 0; j < RARRAY_LEN(dependency); j++) {
                    VALUE needed = rb_ary_entry(dependency, j);
                    if (!RTEST(rb_funcall(instance, id_key_p, 1, needed))) add_error(evaluator, "dependencies", rb_sprintf("property %"PRIsVALUE" is required by %"PRIsVALUE, rb_inspect(needed), rb_inspect(name)), true);
                }
                else evaluate_detailed_at(evaluator, node_child(node, "dependencies", name), instance, Qundef, key("dependencies"), name);
            }
        }
        if (hash_has(schema, "dependentRequired")) {
            VALUE dependencies = hash_get(schema, "dependentRequired"), dependency_names = rb_funcall(dependencies, id_keys, 0);
            for (i = 0; i < RARRAY_LEN(dependency_names); i++) {
                VALUE name = rb_ary_entry(dependency_names, i), dependency;
                if (!RTEST(rb_funcall(instance, id_key_p, 1, name))) continue;
                dependency = rb_hash_aref(dependencies, name);
                for (j = 0; j < RARRAY_LEN(dependency); j++) {
                    VALUE needed = rb_ary_entry(dependency, j);
                    if (!RTEST(rb_funcall(instance, id_key_p, 1, needed))) add_error(evaluator, "dependentRequired", rb_sprintf("property %"PRIsVALUE" is required by %"PRIsVALUE, rb_inspect(needed), rb_inspect(name)), true);
                }
            }
        }
        if (hash_has(schema, "dependentSchemas")) {
            VALUE dependencies = hash_get(schema, "dependentSchemas"), dependency_names = rb_funcall(dependencies, id_keys, 0);
            for (i = 0; i < RARRAY_LEN(dependency_names); i++) {
                VALUE name = rb_ary_entry(dependency_names, i);
                if (RTEST(rb_funcall(instance, id_key_p, 1, name))) evaluate_detailed_at(evaluator, node_child(node, "dependentSchemas", name), instance, Qundef, key("dependentSchemas"), name);
            }
        }
    }
    if (rb_obj_is_kind_of(instance, rb_cArray) && hash_has(schema, "unevaluatedItems")) {
        evaluation_t prior = evaluate_tracking_mode(evaluator, node, instance, false);
        VALUE child = node_child(node, "unevaluatedItems", Qnil);
        for (i = 0; i < RARRAY_LEN(instance); i++) {
            VALUE index = LONG2NUM(i);
            if (!array_includes(prior.items, index)) evaluate_detailed_at(evaluator, child, rb_ary_entry(instance, i), index, key("unevaluatedItems"), Qundef);
        }
    }
    if (rb_obj_is_kind_of(instance, rb_cHash) && hash_has(schema, "unevaluatedProperties")) {
        evaluation_t prior = evaluate_tracking_mode(evaluator, node, instance, false);
        VALUE child = node_child(node, "unevaluatedProperties", Qnil), names = rb_funcall(instance, id_keys, 0);
        for (i = 0; i < RARRAY_LEN(names); i++) {
            VALUE name = rb_ary_entry(names, i);
            if (!array_includes(prior.properties, name)) evaluate_detailed_at(evaluator, child, rb_hash_aref(instance, name), name, key("unevaluatedProperties"), Qundef);
        }
    }
finish:
    if (entered_scope) rb_ary_pop(evaluator->dynamic_scope);
    if (RARRAY_LEN(evaluator->errors) != before) return evaluation_new(false);
    annotations = evaluate_tracking(evaluator, node, instance);
    return annotations;
}

static void
evaluator_mark(void *pointer)
{
    schemurai_evaluator_t *evaluator = pointer;
    rb_gc_mark_movable(evaluator->self);
    rb_gc_mark_movable(evaluator->graph);
    rb_gc_mark_movable(evaluator->root);
    rb_gc_mark_movable(evaluator->regexps);
    rb_gc_mark_movable(evaluator->active);
    rb_gc_mark_movable(evaluator->dynamic_scope);
    rb_gc_mark_movable(evaluator->errors);
    rb_gc_mark_movable(evaluator->instance_path);
    rb_gc_mark_movable(evaluator->schema_path);
    rb_gc_mark_movable(evaluator->resolution_error);
}

static void
evaluator_compact(void *pointer)
{
    schemurai_evaluator_t *evaluator = pointer;
    evaluator->self = rb_gc_location(evaluator->self);
    evaluator->graph = rb_gc_location(evaluator->graph);
    evaluator->root = rb_gc_location(evaluator->root);
    evaluator->regexps = rb_gc_location(evaluator->regexps);
    evaluator->active = rb_gc_location(evaluator->active);
    evaluator->dynamic_scope = rb_gc_location(evaluator->dynamic_scope);
    evaluator->errors = rb_gc_location(evaluator->errors);
    evaluator->instance_path = rb_gc_location(evaluator->instance_path);
    evaluator->schema_path = rb_gc_location(evaluator->schema_path);
    evaluator->resolution_error = rb_gc_location(evaluator->resolution_error);
}

static size_t
evaluator_size(const void *pointer)
{
    return pointer == NULL ? 0 : sizeof(schemurai_evaluator_t);
}

static const rb_data_type_t evaluator_type = {
    .wrap_struct_name = "Schemurai::Native::Evaluator",
    .function = {.dmark = evaluator_mark, .dfree = RUBY_TYPED_DEFAULT_FREE, .dsize = evaluator_size, .dcompact = evaluator_compact},
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE
evaluator_allocate(VALUE klass)
{
    schemurai_evaluator_t *evaluator;
    VALUE object = TypedData_Make_Struct(klass, schemurai_evaluator_t, &evaluator_type, evaluator);
    evaluator->self = object;
    evaluator->graph = evaluator->root = evaluator->regexps = evaluator->active = evaluator->dynamic_scope = Qnil;
    evaluator->errors = evaluator->instance_path = evaluator->schema_path = Qnil;
    evaluator->resolution_error = Qnil;
    evaluator->validate_content = evaluator->validate_format = false;
    return object;
}

static VALUE
evaluator_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE graph, root, options;
    schemurai_evaluator_t *evaluator;
    ID keywords[] = {id_content, id_format};
    VALUE values[2] = {Qfalse, Qfalse};
    rb_scan_args(argc, argv, "2:", &graph, &root, &options);
    if (!NIL_P(options)) rb_get_kwargs(options, keywords, 0, 2, values);
    TypedData_Get_Struct(self, schemurai_evaluator_t, &evaluator_type, evaluator);
    evaluator->graph = graph;
    evaluator->root = root;
    evaluator->validate_content = values[0] != Qundef && RTEST(values[0]);
    evaluator->validate_format = values[1] != Qundef && RTEST(values[1]);
    return self;
}

static VALUE
evaluator_valid(VALUE self, VALUE instance)
{
    schemurai_evaluator_t *evaluator;
    TypedData_Get_Struct(self, schemurai_evaluator_t, &evaluator_type, evaluator);
    evaluator->active = rb_hash_new();
    evaluator->dynamic_scope = rb_ary_new();
    evaluator->regexps = rb_hash_new();
    return evaluate_valid(evaluator, evaluator->root, instance) ? Qtrue : Qfalse;
}

static VALUE
evaluator_validate(VALUE self, VALUE instance)
{
    VALUE arguments[1];
    schemurai_evaluator_t *evaluator;
    TypedData_Get_Struct(self, schemurai_evaluator_t, &evaluator_type, evaluator);
    evaluator->active = rb_hash_new();
    evaluator->dynamic_scope = rb_ary_new();
    evaluator->regexps = rb_hash_new();
    evaluator->errors = rb_ary_new();
    evaluator->instance_path = rb_ary_new();
    evaluator->schema_path = rb_ary_new();
    evaluate_detailed(evaluator, evaluator->root, instance);
    arguments[0] = evaluator->errors;
    return rb_class_new_instance(1, arguments, cResult);
}

static void
initialize_cached_strings(void)
{
    size_t i;
    cached_strings = st_init_strtable();
    cached_string_roots = rb_ary_new_capa((long)(sizeof(cached_string_specs) / sizeof(cached_string_specs[0])));
    for (i = 0; i < sizeof(cached_string_specs) / sizeof(cached_string_specs[0]); i++) {
        const cached_string_spec_t *spec = &cached_string_specs[i];
        VALUE string = rb_str_new_static(spec->bytes, spec->length);
        rb_obj_freeze(string);
        rb_ary_push(cached_string_roots, string);
        st_insert(cached_strings, (st_data_t)spec->bytes, (st_data_t)string);
    }
    rb_obj_freeze(cached_string_roots);
    rb_global_variable(&cached_string_roots);
}

void
Init_schemurai_native(void)
{
    rb_ext_ractor_safe(true);
    id_schema = rb_intern_const("schema"); id_child = rb_intern_const("child"); id_resolve = rb_intern_const("resolve");
    id_dialect = rb_intern_const("dialect"); id_resource = rb_intern_const("resource"); id_root = rb_intern_const("root");
    id_keyword_mask = rb_intern_const("keyword_mask"); id_dynamic_scope_p = rb_intern_const("dynamic_scope?"); id_dynamic_anchor = rb_intern_const("dynamic_anchor");
    id_ref_siblings_p = rb_intern_const("ref_siblings?"); id_format_assertion_p = rb_intern_const("format_assertion?");
    id_format = rb_intern_const("format"); id_call = rb_intern_const("call"); id_keywords = rb_intern_const("keywords");
    id_finite_p = rb_intern_const("finite?"); id_to_i = rb_intern_const("to_i"); id_remainder = rb_intern_const("remainder");
    id_zero_p = rb_intern_const("zero?"); id_positive_p = rb_intern_const("positive?"); id_match_p = rb_intern_const("match?");
    id_length = rb_intern_const("length"); id_object_id = rb_intern_const("object_id");
    id_key_p = rb_intern_const("key?"); id_keys = rb_intern_const("keys"); id_rational = rb_intern_const("Rational");
    id_to_s = rb_intern_const("to_s"); id_compare = rb_intern_const("<=>"); id_include_p = rb_intern_const("include?");
    id_gsub = rb_intern_const("gsub"); id_new = rb_intern_const("new"); id_message = rb_intern_const("message");
    id_end_with_p = rb_intern_const("end_with?"); id_split = rb_intern_const("split");
    id_strict_decode64 = rb_intern_const("strict_decode64"); id_parse = rb_intern_const("parse");
    id_each = rb_intern_const("each"); id_name = rb_intern_const("name"); id_content = rb_intern_const("content");
    id_resolution_error = rb_intern_const("ResolutionError"); id_base64 = rb_intern_const("Base64");
    id_json = rb_intern_const("JSON"); id_parser_error = rb_intern_const("ParserError");
    id_validation_error = rb_intern_const("ValidationError"); id_result = rb_intern_const("Result");
    id_regexp_error = rb_intern_const("RegexpError");
    sym_number = ID2SYM(rb_intern_const("number")); sym_boolean = ID2SYM(rb_intern_const("boolean"));
    sym_native = ID2SYM(rb_intern_const("native")); sym_keyword = ID2SYM(rb_intern_const("keyword"));
    sym_instance_path = ID2SYM(rb_intern_const("instance_path")); sym_schema_path = ID2SYM(rb_intern_const("schema_path"));
    sym_message = ID2SYM(id_message);
    initialize_cached_strings();
    VALUE schemurai = rb_define_module("Schemurai");
    mNative = rb_define_module_under(schemurai, "Native");
    cEvaluator = rb_define_class_under(mNative, "Evaluator", rb_cObject);
    rb_define_const(mNative, "BACKEND", sym_native);
    rb_define_alloc_func(cEvaluator, evaluator_allocate);
    rb_define_method(cEvaluator, "initialize", evaluator_initialize, -1);
    rb_define_method(cEvaluator, "valid?", evaluator_valid, 1);
    rb_define_method(cEvaluator, "validate", evaluator_validate, 1);
    cResolutionError = rb_const_get(schemurai, id_resolution_error);
    mBase64 = rb_const_get(rb_cObject, id_base64);
    mJSON = rb_const_get(rb_cObject, id_json);
    cJSONParserError = rb_const_get(mJSON, id_parser_error);
    cValidationError = rb_const_get(schemurai, id_validation_error);
    cResult = rb_const_get(schemurai, id_result);
    cRegexpError = rb_const_get(rb_cObject, id_regexp_error);
    rb_global_variable(&mNative);
    rb_global_variable(&cEvaluator);
    rb_global_variable(&cResolutionError);
    rb_global_variable(&mBase64);
    rb_global_variable(&mJSON);
    rb_global_variable(&cJSONParserError);
    rb_global_variable(&cValidationError);
    rb_global_variable(&cResult);
    rb_global_variable(&cRegexpError);
}
