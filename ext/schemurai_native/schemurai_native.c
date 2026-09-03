#include "ruby.h"
#include <math.h>
#include <stdint.h>
#include <string.h>

enum opcode {
  OP_BOOLEAN, OP_REF, OP_RECURSIVE_REF, OP_DYNAMIC_REF,
  OP_TYPE_NULL, OP_TYPE_BOOLEAN, OP_TYPE_OBJECT, OP_TYPE_ARRAY,
  OP_TYPE_NUMBER, OP_TYPE_INTEGER, OP_TYPE_STRING, OP_TYPES,
  OP_ENUM, OP_CONST, OP_ALL_OF, OP_ANY_OF, OP_ONE_OF, OP_NOT,
  OP_CONDITIONAL, OP_NUMBER, OP_STRING, OP_ARRAY, OP_OBJECT,
  OP_TYPED_NUMBER, OP_TYPED_INTEGER, OP_TYPED_STRING, OP_TYPED_ARRAY,
  OP_TYPED_OBJECT
};

/* Immutable compiler output. Programs own a native instruction vector and
 * each operand uses the rule layout appropriate for its opcode. */
enum rule_kind { RULE_REFERENCE, RULE_TYPES, RULE_CONDITIONAL, RULE_NUMBER, RULE_STRING, RULE_ARRAY, RULE_OBJECT };

enum {
  FLAG_EVALUATION = 1,
  FLAG_DYNAMIC_SCOPE = 2,
  TYPE_NULL = 1, TYPE_BOOLEAN = 2, TYPE_OBJECT = 4, TYPE_ARRAY = 8,
  TYPE_NUMBER = 16, TYPE_INTEGER = 32, TYPE_STRING = 64,
  NUM_MAXIMUM = 1, NUM_MINIMUM = 2, NUM_EXCLUSIVE_MAXIMUM = 4,
  NUM_EXCLUSIVE_MINIMUM = 8, NUM_MULTIPLE_OF = 16
};

typedef struct { uint8_t opcode; VALUE operand; } instruction_t;

typedef struct {
  VALUE node;
  VALUE dynamic_anchor;
  instruction_t *instructions;
  size_t length;
  size_t capacity;
  uint8_t flags;
  bool recursive_anchor;
} program_t;

typedef struct {
  uint8_t kind;
  uint32_t mask;
  union {
    struct { VALUE value, fragment; } reference;
    struct { VALUE names; } types;
    struct { VALUE condition, then_branch, else_branch; } conditional;
    struct { VALUE maximum, minimum, exclusive_maximum, exclusive_minimum, multiple_of; } number;
    struct {
      VALUE max_length, min_length, pattern, format;
      bool format_assertion, decode_base64, parse_json;
    } string;
    struct {
      VALUE max_items, min_items, prefix_items, items;
      VALUE additional, contains, min_contains, max_contains, unevaluated;
      bool unique, items_list;
    } array;
    struct {
      VALUE max_properties, min_properties, required, properties, patterns;
      VALUE additional, property_names, dependencies, dependent_required;
      VALUE dependent_schemas, unevaluated;
    } object;
  } as;
} rule_t;
typedef struct { VALUE graph; VALUE programs; } compiler_t;
typedef struct {
  VALUE graph, compiler, root;
  VALUE regexps, resolved, active, dynamic_scope;
  VALUE instance_path, schema_path, errors;
  bool content, format;
  long error_count;
} evaluator_t;

static VALUE mSchemurai, mVM, mInternal, mErrorMessage, mNativeSupport;
static VALUE cProgram, cCompiler, cEvaluator, cRule, cResult, cValidationError, cRubyEvaluator;
static VALUE eResolutionError;
static VALUE sym_content, sym_format, sym_vm;
static VALUE sym_keyword, sym_instance_path, sym_schema_path, sym_message;
static ID id_schema, id_dialect, id_keyword_mask, id_format, id_child, id_resource;
static ID id_nodes, id_resolve, id_dynamic_anchor, id_root, id_ref_siblings_p;
static ID id_format_assertion_p, id_key_p, id_call, id_finite_p;
static ID id_to_i, id_to_s, id_remainder, id_zero_p, id_positive_p, id_name;
static ID id_regexp, id_valid_content_p, id_valid_p;
static ID id_keys, id_include_p, id_compare_by_identity, id_compare, id_length;
static ID id_match_p, id_gsub, id_message, id_validate;
static ID id_complex, id_rational;
static ID id_error_any_of, id_error_const, id_error_contains, id_error_content_encoding;
static ID id_error_content_media_type, id_error_dependent_required, id_error_enum;
static ID id_error_false_schema, id_error_format, id_error_invalid_pattern;
static ID id_error_multiple_of, id_error_not, id_error_numeric_limit;
static ID id_error_one_of, id_error_pattern, id_error_required, id_error_size;
static ID id_error_type, id_error_unique_items;

#define STATIC_STRING_LIST(X) \
  X(REF, "$ref") \
  X(RECURSIVE_REF, "$recursiveRef") \
  X(DYNAMIC_REF, "$dynamicRef") \
  X(RECURSIVE_ANCHOR, "$recursiveAnchor") \
  X(DYNAMIC_ANCHOR, "$dynamicAnchor") \
  X(TYPE, "type") \
  X(NULL_TYPE, "null") \
  X(BOOLEAN_TYPE, "boolean") \
  X(OBJECT_TYPE, "object") \
  X(ARRAY_TYPE, "array") \
  X(NUMBER_TYPE, "number") \
  X(INTEGER_TYPE, "integer") \
  X(STRING_TYPE, "string") \
  X(ENUM, "enum") \
  X(CONST, "const") \
  X(ALL_OF, "allOf") \
  X(ANY_OF, "anyOf") \
  X(ONE_OF, "oneOf") \
  X(NOT, "not") \
  X(IF, "if") \
  X(THEN, "then") \
  X(ELSE, "else") \
  X(MAXIMUM, "maximum") \
  X(MINIMUM, "minimum") \
  X(EXCLUSIVE_MAXIMUM, "exclusiveMaximum") \
  X(EXCLUSIVE_MINIMUM, "exclusiveMinimum") \
  X(MULTIPLE_OF, "multipleOf") \
  X(MAX_LENGTH, "maxLength") \
  X(MIN_LENGTH, "minLength") \
  X(PATTERN, "pattern") \
  X(FORMAT, "format") \
  X(CONTENT_ENCODING, "contentEncoding") \
  X(CONTENT_MEDIA_TYPE, "contentMediaType") \
  X(BASE64, "base64") \
  X(APPLICATION_JSON, "application/json") \
  X(MAX_ITEMS, "maxItems") \
  X(MIN_ITEMS, "minItems") \
  X(UNIQUE_ITEMS, "uniqueItems") \
  X(PREFIX_ITEMS, "prefixItems") \
  X(ITEMS, "items") \
  X(ADDITIONAL_ITEMS, "additionalItems") \
  X(CONTAINS, "contains") \
  X(MIN_CONTAINS, "minContains") \
  X(MAX_CONTAINS, "maxContains") \
  X(UNEVALUATED_ITEMS, "unevaluatedItems") \
  X(MAX_PROPERTIES, "maxProperties") \
  X(MIN_PROPERTIES, "minProperties") \
  X(REQUIRED, "required") \
  X(PROPERTIES, "properties") \
  X(PATTERN_PROPERTIES, "patternProperties") \
  X(ADDITIONAL_PROPERTIES, "additionalProperties") \
  X(PROPERTY_NAMES, "propertyNames") \
  X(DEPENDENCIES, "dependencies") \
  X(DEPENDENT_REQUIRED, "dependentRequired") \
  X(DEPENDENT_SCHEMAS, "dependentSchemas") \
  X(UNEVALUATED_PROPERTIES, "unevaluatedProperties") \
  X(FALSE_SCHEMA, "falseSchema") \
  X(TILDE, "~") \
  X(ESCAPED_TILDE, "~0") \
  X(SLASH, "/") \
  X(ESCAPED_SLASH, "~1")

enum static_string_index {
#define ENUM_STATIC_STRING(name, value) STATIC_STRING_##name,
  STATIC_STRING_LIST(ENUM_STATIC_STRING)
#undef ENUM_STATIC_STRING
  STATIC_STRING_COUNT
};

static VALUE static_strings[STATIC_STRING_COUNT];
#define STATIC_STRING(name) static_strings[STATIC_STRING_##name]

static void program_mark(void *ptr) {
  program_t *p = ptr;
  rb_gc_mark_movable(p->node);
  rb_gc_mark_movable(p->dynamic_anchor);
  for (size_t i = 0; i < p->length; i++) rb_gc_mark_movable(p->instructions[i].operand);
}
static void program_compact(void *ptr) {
  program_t *p = ptr;
  p->node = rb_gc_location(p->node);
  p->dynamic_anchor = rb_gc_location(p->dynamic_anchor);
  for (size_t i = 0; i < p->length; i++) p->instructions[i].operand = rb_gc_location(p->instructions[i].operand);
}
static void program_free(void *ptr) { program_t *p = ptr; xfree(p->instructions); xfree(p); }
static size_t program_size(const void *ptr) { const program_t *p = ptr; return sizeof(*p) + p->capacity * sizeof(instruction_t); }
static const rb_data_type_t program_type = {
  "Schemurai::VM::Program", {program_mark, program_free, program_size, program_compact}, 0, 0,
  RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED | RUBY_TYPED_FROZEN_SHAREABLE
};

#define MARK_RULE_VALUE(field) rb_gc_mark_movable(r->as.field)
#define COMPACT_RULE_VALUE(field) r->as.field = rb_gc_location(r->as.field)
static void rule_each_value(rule_t *r, bool compact) {
#define VISIT(field) do { if (compact) { COMPACT_RULE_VALUE(field); } else { MARK_RULE_VALUE(field); } } while (0)
  switch (r->kind) {
    case RULE_REFERENCE: VISIT(reference.value); VISIT(reference.fragment); break;
    case RULE_TYPES: VISIT(types.names); break;
    case RULE_CONDITIONAL: VISIT(conditional.condition); VISIT(conditional.then_branch); VISIT(conditional.else_branch); break;
    case RULE_NUMBER: VISIT(number.maximum); VISIT(number.minimum); VISIT(number.exclusive_maximum); VISIT(number.exclusive_minimum); VISIT(number.multiple_of); break;
    case RULE_STRING: VISIT(string.max_length); VISIT(string.min_length); VISIT(string.pattern); VISIT(string.format); break;
    case RULE_ARRAY:
      VISIT(array.max_items); VISIT(array.min_items); VISIT(array.prefix_items); VISIT(array.items); VISIT(array.additional);
      VISIT(array.contains); VISIT(array.min_contains); VISIT(array.max_contains); VISIT(array.unevaluated); break;
    case RULE_OBJECT:
      VISIT(object.max_properties); VISIT(object.min_properties); VISIT(object.required); VISIT(object.properties); VISIT(object.patterns);
      VISIT(object.additional); VISIT(object.property_names); VISIT(object.dependencies); VISIT(object.dependent_required);
      VISIT(object.dependent_schemas); VISIT(object.unevaluated); break;
  }
#undef VISIT
}
static void rule_mark(void *ptr) { rule_each_value(ptr, false); }
static void rule_compact(void *ptr) { rule_each_value(ptr, true); }
#undef MARK_RULE_VALUE
#undef COMPACT_RULE_VALUE
static size_t rule_size(const void *ptr) { return sizeof(rule_t); }
static const rb_data_type_t rule_type = {
  "Schemurai::VM::Rule", {rule_mark, RUBY_TYPED_DEFAULT_FREE, rule_size, rule_compact}, 0, 0,
  RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED | RUBY_TYPED_FROZEN_SHAREABLE
};

static void compiler_mark(void *ptr) { compiler_t *c = ptr; rb_gc_mark_movable(c->graph); rb_gc_mark_movable(c->programs); }
static void compiler_compact(void *ptr) { compiler_t *c = ptr; c->graph = rb_gc_location(c->graph); c->programs = rb_gc_location(c->programs); }
static size_t compiler_size(const void *ptr) { return sizeof(compiler_t); }
static const rb_data_type_t compiler_type = {
  "Schemurai::VM::Compiler", {compiler_mark, RUBY_TYPED_DEFAULT_FREE, compiler_size, compiler_compact}, 0, 0,
  RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED | RUBY_TYPED_FROZEN_SHAREABLE
};

static void evaluator_mark(void *ptr) {
  evaluator_t *e = ptr;
  VALUE *values = &e->graph;
  for (int i = 0; i < 10; i++) rb_gc_mark_movable(values[i]);
}
static void evaluator_compact(void *ptr) {
  evaluator_t *e = ptr;
  VALUE *values = &e->graph;
  for (int i = 0; i < 10; i++) values[i] = rb_gc_location(values[i]);
}
static size_t evaluator_size(const void *ptr) { return sizeof(evaluator_t); }
static const rb_data_type_t evaluator_type = {
  "Schemurai::VM::Evaluator", {evaluator_mark, RUBY_TYPED_DEFAULT_FREE, evaluator_size, evaluator_compact},
  0, 0, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED
};

static VALUE program_alloc(VALUE klass) { program_t *p; return TypedData_Make_Struct(klass, program_t, &program_type, p); }
static VALUE compiler_alloc(VALUE klass) { compiler_t *c; return TypedData_Make_Struct(klass, compiler_t, &compiler_type, c); }
static VALUE evaluator_alloc(VALUE klass) { evaluator_t *e; return TypedData_Make_Struct(klass, evaluator_t, &evaluator_type, e); }

static VALUE rule_new(uint8_t kind) {
  rule_t *r;
  VALUE obj = TypedData_Make_Struct(cRule, rule_t, &rule_type, r);
  r->kind = kind;
  VALUE *slot = (VALUE *)&r->as;
  for (size_t i = 0; i < sizeof(r->as) / sizeof(VALUE); i++) slot[i] = Qnil;
  return obj;
}

static void emit(VALUE program, uint8_t opcode, VALUE operand) {
  program_t *p; TypedData_Get_Struct(program, program_t, &program_type, p);
  if (p->length == p->capacity) {
    p->capacity = p->capacity ? p->capacity * 2 : 8;
    REALLOC_N(p->instructions, instruction_t, p->capacity);
  }
  RB_OBJ_WRITE(program, &p->instructions[p->length].operand, operand);
  p->instructions[p->length].opcode = opcode;
  p->length++;
}

static VALUE hget(VALUE hash, VALUE key) { return rb_hash_aref(hash, key); }
static bool hkey(VALUE hash, VALUE key) { return RTEST(rb_funcall(hash, id_key_p, 1, key)); }
static VALUE node_child(VALUE node, VALUE keyword, VALUE segment, bool has_segment) {
  return has_segment ? rb_funcall(node, id_child, 2, keyword, segment) : rb_funcall(node, id_child, 1, keyword);
}

/* Compiler: Ruby schema nodes are consumed at this boundary. The resulting
 * programs snapshot operands and retain only compiled child programs. */
static VALUE snapshot(VALUE value) {
  if (RB_TYPE_P(value, T_STRING)) return rb_str_new_frozen(value);
  if (RB_TYPE_P(value, T_ARRAY)) {
    long n = RARRAY_LEN(value); VALUE copy = rb_ary_new_capa(n);
    for (long i = 0; i < n; i++) rb_ary_push(copy, snapshot(rb_ary_entry(value, i)));
    return rb_obj_freeze(copy);
  }
  if (RB_TYPE_P(value, T_HASH)) {
    VALUE keys = rb_funcall(value, id_keys, 0), copy = rb_hash_new();
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
      VALUE key = rb_ary_entry(keys, i);
      rb_hash_aset(copy, snapshot(key), snapshot(rb_hash_aref(value, key)));
    }
    return rb_obj_freeze(copy);
  }
  return value;
}

static VALUE compiler_compile(VALUE self, VALUE node);

static VALUE compile_child(VALUE self, VALUE node, VALUE parent) {
  VALUE child = compiler_compile(self, node);
  program_t *c, *p;
  TypedData_Get_Struct(child, program_t, &program_type, c);
  TypedData_Get_Struct(parent, program_t, &program_type, p);
  if (c->flags & FLAG_DYNAMIC_SCOPE) p->flags |= FLAG_DYNAMIC_SCOPE;
  return child;
}

static VALUE compile_reference(VALUE reference) {
  VALUE rule = rule_new(RULE_REFERENCE); rule_t *r; TypedData_Get_Struct(rule, rule_t, &rule_type, r);
  r->as.reference.value = snapshot(reference);
  const char *ptr = StringValueCStr(reference), *hash = strchr(ptr, '#');
  r->as.reference.fragment = hash ? rb_str_new_cstr(hash + 1) : Qnil;
  RB_OBJ_WRITTEN(rule, Qundef, r->as.reference.value);
  RB_OBJ_WRITTEN(rule, Qundef, r->as.reference.fragment);
  return rb_obj_freeze(rule);
}

static VALUE compile_map(VALUE self, VALUE node, VALUE parent, VALUE schema, VALUE keyword) {
  VALUE source = hget(schema, keyword), result = rb_hash_new();
  if (NIL_P(source)) return rb_obj_freeze(result);
  VALUE keys = rb_funcall(source, id_keys, 0);
  for (long i = 0; i < RARRAY_LEN(keys); i++) {
    VALUE key = rb_ary_entry(keys, i);
    rb_hash_aset(result, snapshot(key), compile_child(self, node_child(node, keyword, key, true), parent));
  }
  return rb_obj_freeze(result);
}

static VALUE compile_number(VALUE schema) {
  VALUE obj = rule_new(RULE_NUMBER); rule_t *r; TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  VALUE keys[] = {STATIC_STRING(MAXIMUM), STATIC_STRING(MINIMUM), STATIC_STRING(EXCLUSIVE_MAXIMUM), STATIC_STRING(EXCLUSIVE_MINIMUM), STATIC_STRING(MULTIPLE_OF)};
  VALUE *limits[] = {&r->as.number.maximum, &r->as.number.minimum, &r->as.number.exclusive_maximum, &r->as.number.exclusive_minimum, &r->as.number.multiple_of};
  for (int i = 0; i < 5; i++) if (hkey(schema, keys[i])) { r->mask |= 1u << i; RB_OBJ_WRITE(obj, limits[i], hget(schema, keys[i])); }
  return rb_obj_freeze(obj);
}

static VALUE compile_string(VALUE node, VALUE schema) {
  VALUE obj = rule_new(RULE_STRING); rule_t *r; TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  r->as.string.max_length = hget(schema, STATIC_STRING(MAX_LENGTH));
  r->as.string.min_length = hget(schema, STATIC_STRING(MIN_LENGTH));
  r->as.string.pattern = snapshot(hget(schema, STATIC_STRING(PATTERN)));
  r->as.string.format = rb_funcall(node, id_format, 0);
  VALUE dialect = rb_funcall(node, id_dialect, 0);
  r->as.string.format_assertion = RTEST(rb_funcall(dialect, id_format_assertion_p, 0));
  VALUE encoding = hget(schema, STATIC_STRING(CONTENT_ENCODING));
  VALUE media_type = hget(schema, STATIC_STRING(CONTENT_MEDIA_TYPE));
  r->as.string.decode_base64 = RB_TYPE_P(encoding, T_STRING) && rb_str_equal(encoding, STATIC_STRING(BASE64));
  r->as.string.parse_json = RB_TYPE_P(media_type, T_STRING) && rb_str_equal(media_type, STATIC_STRING(APPLICATION_JSON));
  RB_OBJ_WRITTEN(obj, Qundef, r->as.string.max_length); RB_OBJ_WRITTEN(obj, Qundef, r->as.string.min_length);
  RB_OBJ_WRITTEN(obj, Qundef, r->as.string.pattern); RB_OBJ_WRITTEN(obj, Qundef, r->as.string.format);
  return rb_obj_freeze(obj);
}

static VALUE compile_program_list(VALUE self, VALUE node, VALUE parent, VALUE source, VALUE keyword) {
  long n = RARRAY_LEN(source); VALUE list = rb_ary_new_capa(n);
  for (long i = 0; i < n; i++) rb_ary_push(list, compile_child(self, node_child(node, keyword, LONG2NUM(i), true), parent));
  return rb_obj_freeze(list);
}

static VALUE compile_array(VALUE self, VALUE node, VALUE parent, VALUE schema) {
  VALUE obj = rule_new(RULE_ARRAY); rule_t *r; TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  r->as.array.items_list = false;
  r->as.array.max_items = hget(schema, STATIC_STRING(MAX_ITEMS));
  r->as.array.min_items = hget(schema, STATIC_STRING(MIN_ITEMS));
  r->as.array.unique = RTEST(hget(schema, STATIC_STRING(UNIQUE_ITEMS)));
  VALUE prefix = hget(schema, STATIC_STRING(PREFIX_ITEMS));
  if (RB_TYPE_P(prefix, T_ARRAY)) r->as.array.prefix_items = compile_program_list(self, node, parent, prefix, STATIC_STRING(PREFIX_ITEMS));
  VALUE items = hget(schema, STATIC_STRING(ITEMS));
  if (RB_TYPE_P(items, T_ARRAY)) { r->as.array.items = compile_program_list(self, node, parent, items, STATIC_STRING(ITEMS)); r->as.array.items_list = true; }
  else if (!NIL_P(items)) r->as.array.items = compile_child(self, node_child(node, STATIC_STRING(ITEMS), Qnil, false), parent);
  if (hkey(schema, STATIC_STRING(ADDITIONAL_ITEMS))) r->as.array.additional = compile_child(self, node_child(node, STATIC_STRING(ADDITIONAL_ITEMS), Qnil, false), parent);
  if (hkey(schema, STATIC_STRING(CONTAINS))) r->as.array.contains = compile_child(self, node_child(node, STATIC_STRING(CONTAINS), Qnil, false), parent);
  r->as.array.min_contains = hkey(schema, STATIC_STRING(MIN_CONTAINS)) ? hget(schema, STATIC_STRING(MIN_CONTAINS)) : INT2NUM(1);
  r->as.array.max_contains = hkey(schema, STATIC_STRING(MAX_CONTAINS)) ? hget(schema, STATIC_STRING(MAX_CONTAINS)) : DBL2NUM(HUGE_VAL);
  if (hkey(schema, STATIC_STRING(UNEVALUATED_ITEMS))) { r->as.array.unevaluated = compile_child(self, node_child(node, STATIC_STRING(UNEVALUATED_ITEMS), Qnil, false), parent); program_t *p; TypedData_Get_Struct(parent, program_t, &program_type, p); p->flags |= FLAG_EVALUATION; }
  VALUE *values[] = {&r->as.array.max_items, &r->as.array.min_items, &r->as.array.prefix_items, &r->as.array.items, &r->as.array.additional, &r->as.array.contains, &r->as.array.min_contains, &r->as.array.max_contains, &r->as.array.unevaluated};
  for (int i = 0; i < 9; i++) RB_OBJ_WRITTEN(obj, Qundef, *values[i]);
  return rb_obj_freeze(obj);
}

static VALUE compile_dependencies(VALUE self, VALUE node, VALUE parent, VALUE schema) {
  VALUE source = hget(schema, STATIC_STRING(DEPENDENCIES)); if (NIL_P(source) || RHASH_EMPTY_P(source)) return Qnil;
  VALUE out = rb_hash_new(), keys = rb_funcall(source, id_keys, 0);
  for (long i = 0; i < RARRAY_LEN(keys); i++) {
    VALUE key = rb_ary_entry(keys, i), value = rb_hash_aref(source, key);
    VALUE compiled = RB_TYPE_P(value, T_ARRAY) ? snapshot(value) : compile_child(self, node_child(node, STATIC_STRING(DEPENDENCIES), key, true), parent);
    rb_hash_aset(out, snapshot(key), compiled);
  }
  return rb_obj_freeze(out);
}

static VALUE compile_object(VALUE self, VALUE node, VALUE parent, VALUE schema) {
  VALUE obj = rule_new(RULE_OBJECT); rule_t *r; TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  r->as.object.max_properties = hget(schema, STATIC_STRING(MAX_PROPERTIES));
  r->as.object.min_properties = hget(schema, STATIC_STRING(MIN_PROPERTIES));
  r->as.object.required = snapshot(hget(schema, STATIC_STRING(REQUIRED)));
  r->as.object.properties = compile_map(self, node, parent, schema, STATIC_STRING(PROPERTIES));
  VALUE map = compile_map(self, node, parent, schema, STATIC_STRING(PATTERN_PROPERTIES)); r->as.object.patterns = RHASH_EMPTY_P(map) ? Qnil : map;
  if (hkey(schema, STATIC_STRING(ADDITIONAL_PROPERTIES))) r->as.object.additional = compile_child(self, node_child(node, STATIC_STRING(ADDITIONAL_PROPERTIES), Qnil, false), parent);
  if (hkey(schema, STATIC_STRING(PROPERTY_NAMES))) r->as.object.property_names = compile_child(self, node_child(node, STATIC_STRING(PROPERTY_NAMES), Qnil, false), parent);
  r->as.object.dependencies = compile_dependencies(self, node, parent, schema);
  VALUE dep_req = hget(schema, STATIC_STRING(DEPENDENT_REQUIRED)); r->as.object.dependent_required = NIL_P(dep_req) || RHASH_EMPTY_P(dep_req) ? Qnil : snapshot(dep_req);
  map = compile_map(self, node, parent, schema, STATIC_STRING(DEPENDENT_SCHEMAS)); r->as.object.dependent_schemas = RHASH_EMPTY_P(map) ? Qnil : map;
  if (hkey(schema, STATIC_STRING(UNEVALUATED_PROPERTIES))) { r->as.object.unevaluated = compile_child(self, node_child(node, STATIC_STRING(UNEVALUATED_PROPERTIES), Qnil, false), parent); program_t *p; TypedData_Get_Struct(parent, program_t, &program_type, p); p->flags |= FLAG_EVALUATION; }
  VALUE *values[] = {&r->as.object.max_properties, &r->as.object.min_properties, &r->as.object.required, &r->as.object.properties, &r->as.object.patterns, &r->as.object.additional, &r->as.object.property_names, &r->as.object.dependencies, &r->as.object.dependent_required, &r->as.object.dependent_schemas, &r->as.object.unevaluated};
  for (int i = 0; i < 11; i++) RB_OBJ_WRITTEN(obj, Qundef, *values[i]);
  return rb_obj_freeze(obj);
}

static VALUE compiler_initialize(VALUE self, VALUE graph) {
  compiler_t *c; TypedData_Get_Struct(self, compiler_t, &compiler_type, c);
  RB_OBJ_WRITE(self, &c->graph, graph); RB_OBJ_WRITE(self, &c->programs, rb_hash_new());
  rb_funcall(c->programs, id_compare_by_identity, 0); return self;
}

static void compile_combiners(VALUE self, VALUE node, VALUE program, VALUE schema) {
  VALUE keys[] = {STATIC_STRING(ALL_OF), STATIC_STRING(ANY_OF), STATIC_STRING(ONE_OF)}; const uint8_t ops[] = {OP_ALL_OF, OP_ANY_OF, OP_ONE_OF};
  for (int i = 0; i < 3; i++) if (hkey(schema, keys[i])) emit(program, ops[i], compile_program_list(self, node, program, hget(schema, keys[i]), keys[i]));
  if (hkey(schema, STATIC_STRING(NOT))) emit(program, OP_NOT, compile_child(self, node_child(node, STATIC_STRING(NOT), Qnil, false), program));
  if (hkey(schema, STATIC_STRING(IF))) {
    VALUE obj = rule_new(RULE_CONDITIONAL); rule_t *r; TypedData_Get_Struct(obj, rule_t, &rule_type, r);
    r->as.conditional.condition = compile_child(self, node_child(node, STATIC_STRING(IF), Qnil, false), program);
    if (hkey(schema, STATIC_STRING(THEN))) r->as.conditional.then_branch = compile_child(self, node_child(node, STATIC_STRING(THEN), Qnil, false), program);
    if (hkey(schema, STATIC_STRING(ELSE))) r->as.conditional.else_branch = compile_child(self, node_child(node, STATIC_STRING(ELSE), Qnil, false), program);
    RB_OBJ_WRITTEN(obj, Qundef, r->as.conditional.condition); RB_OBJ_WRITTEN(obj, Qundef, r->as.conditional.then_branch); RB_OBJ_WRITTEN(obj, Qundef, r->as.conditional.else_branch);
    emit(program, OP_CONDITIONAL, rb_obj_freeze(obj));
  }
}

static VALUE compiler_compile(VALUE self, VALUE node) {
  compiler_t *c; TypedData_Get_Struct(self, compiler_t, &compiler_type, c);
  VALUE cached = rb_hash_lookup2(c->programs, node, Qundef); if (cached != Qundef) return cached;
  VALUE program = program_alloc(cProgram); program_t *p; TypedData_Get_Struct(program, program_t, &program_type, p);
  RB_OBJ_WRITE(program, &p->node, node); p->dynamic_anchor = Qnil;
  rb_hash_aset(c->programs, node, program);
  VALUE schema = rb_funcall(node, id_schema, 0);
  if (RB_TYPE_P(schema, T_HASH)) {
    p->recursive_anchor = hget(schema, STATIC_STRING(RECURSIVE_ANCHOR)) == Qtrue;
    VALUE anchor = hget(schema, STATIC_STRING(DYNAMIC_ANCHOR)); if (RB_TYPE_P(anchor, T_STRING)) RB_OBJ_WRITE(program, &p->dynamic_anchor, rb_str_new_frozen(anchor));
  }
  if (schema == Qtrue || schema == Qfalse) emit(program, OP_BOOLEAN, schema);
  else if (RB_TYPE_P(schema, T_HASH)) {
    if (hkey(schema, STATIC_STRING(REF))) {
      p->flags |= FLAG_DYNAMIC_SCOPE; emit(program, OP_REF, compile_reference(hget(schema, STATIC_STRING(REF))));
      if (!RTEST(rb_funcall(rb_funcall(node, id_dialect, 0), id_ref_siblings_p, 0))) goto finish;
    }
    if (hkey(schema, STATIC_STRING(RECURSIVE_REF))) { p->flags |= FLAG_DYNAMIC_SCOPE; emit(program, OP_RECURSIVE_REF, compile_reference(hget(schema, STATIC_STRING(RECURSIVE_REF)))); }
    if (hkey(schema, STATIC_STRING(DYNAMIC_REF))) { p->flags |= FLAG_DYNAMIC_SCOPE; emit(program, OP_DYNAMIC_REF, compile_reference(hget(schema, STATIC_STRING(DYNAMIC_REF)))); }
    unsigned long mask = NUM2ULONG(rb_funcall(node, id_keyword_mask, 0));
    if ((mask & 1) && hkey(schema, STATIC_STRING(TYPE))) {
      VALUE types = hget(schema, STATIC_STRING(TYPE));
      if (RB_TYPE_P(types, T_ARRAY)) {
        VALUE rule = rule_new(RULE_TYPES); rule_t *r; TypedData_Get_Struct(rule, rule_t, &rule_type, r);
        for (long i = 0; i < RARRAY_LEN(types); i++) {
          VALUE type_name = rb_ary_entry(types, i); const char *name = StringValueCStr(type_name);
          if (!strcmp(name,"null")) r->mask |= TYPE_NULL; else if (!strcmp(name,"boolean")) r->mask |= TYPE_BOOLEAN;
          else if (!strcmp(name,"object")) r->mask |= TYPE_OBJECT; else if (!strcmp(name,"array")) r->mask |= TYPE_ARRAY;
          else if (!strcmp(name,"number")) r->mask |= TYPE_NUMBER; else if (!strcmp(name,"integer")) r->mask |= TYPE_INTEGER; else if (!strcmp(name,"string")) r->mask |= TYPE_STRING;
        }
        r->as.types.names = snapshot(types); RB_OBJ_WRITTEN(rule,Qundef,r->as.types.names); emit(program, OP_TYPES, rb_obj_freeze(rule));
      } else {
        const char *name = StringValueCStr(types); uint8_t op = OP_TYPE_STRING;
        if (!strcmp(name,"null")) op=OP_TYPE_NULL; else if (!strcmp(name,"boolean")) op=OP_TYPE_BOOLEAN; else if (!strcmp(name,"object")) op=OP_TYPE_OBJECT;
        else if (!strcmp(name,"array")) op=OP_TYPE_ARRAY; else if (!strcmp(name,"number")) op=OP_TYPE_NUMBER; else if (!strcmp(name,"integer")) op=OP_TYPE_INTEGER;
        emit(program, op, Qnil);
      }
    }
    if (mask & 2) { if (hkey(schema,STATIC_STRING(ENUM))) emit(program,OP_ENUM,snapshot(hget(schema,STATIC_STRING(ENUM)))); if (hkey(schema,STATIC_STRING(CONST))) emit(program,OP_CONST,snapshot(hget(schema,STATIC_STRING(CONST)))); }
    if (mask & 4) compile_combiners(self,node,program,schema);
    if (mask & 8) emit(program,OP_NUMBER,compile_number(schema));
    if ((mask & 16) || !NIL_P(rb_funcall(node,id_format,0))) emit(program,OP_STRING,compile_string(node,schema));
    if (mask & 32) emit(program,OP_ARRAY,compile_array(self,node,program,schema));
    if (mask & 64) emit(program,OP_OBJECT,compile_object(self,node,program,schema));
    for (size_t i=0; i+1<p->length; i++) {
      uint8_t a=p->instructions[i].opcode,b=p->instructions[i+1].opcode,fused=255;
      if (a==OP_TYPE_OBJECT&&b==OP_OBJECT) fused=OP_TYPED_OBJECT; else if(a==OP_TYPE_ARRAY&&b==OP_ARRAY) fused=OP_TYPED_ARRAY;
      else if(a==OP_TYPE_STRING&&b==OP_STRING) fused=OP_TYPED_STRING; else if(a==OP_TYPE_NUMBER&&b==OP_NUMBER) fused=OP_TYPED_NUMBER; else if(a==OP_TYPE_INTEGER&&b==OP_NUMBER) fused=OP_TYPED_INTEGER;
      if(fused!=255){ p->instructions[i].opcode=fused; RB_OBJ_WRITE(program,&p->instructions[i].operand,p->instructions[i+1].operand); memmove(&p->instructions[i+1],&p->instructions[i+2],(p->length-i-2)*sizeof(instruction_t)); p->length--; break; }
    }
  }
finish:
  rb_obj_freeze(program); return program;
}

static VALUE compiler_compile_all(VALUE self) {
  compiler_t *c; TypedData_Get_Struct(self,compiler_t,&compiler_type,c); VALUE nodes=rb_funcall(c->graph,id_nodes,0);
  for(long i=0;i<RARRAY_LEN(nodes);i++) compiler_compile(self,rb_ary_entry(nodes,i));
  return self;
}
static VALUE compiler_resolve(VALUE self, VALUE program, VALUE reference) {
  compiler_t *c; program_t *p; TypedData_Get_Struct(self,compiler_t,&compiler_type,c); TypedData_Get_Struct(program,program_t,&program_type,p);
  return compiler_compile(self,rb_funcall(c->graph,id_resolve,2,p->node,reference));
}
typedef struct { bool valid; VALUE properties, items; } evaluation_t;

/* Evaluator core: validity and annotations stay in a small native value type.
 * Ruby arrays are allocated lazily only when an applicator records locations. */

static evaluation_t evaluation(bool valid) { evaluation_t r = {valid, Qnil, Qnil}; return r; }
static void add_unique(VALUE *list, VALUE value) {
  if (NIL_P(*list)) *list = rb_ary_new();
  if (!RTEST(rb_funcall(*list, id_include_p, 1, value))) rb_ary_push(*list, value);
}
static void merge_locations(VALUE *target, VALUE source) {
  if (NIL_P(source)) return;
  for (long i=0; i<RARRAY_LEN(source); i++) add_unique(target,rb_ary_entry(source,i));
}
static void merge_evaluation(evaluation_t *target, evaluation_t source) {
  if (!source.valid) { target->valid=false; return; }
  if (!target->valid) return;
  merge_locations(&target->properties,source.properties); merge_locations(&target->items,source.items);
}
static bool has_location(VALUE list, VALUE item) { return !NIL_P(list) && RTEST(rb_funcall(list,id_include_p,1,item)); }

static bool number_p(VALUE value) {
  VALUE complex = rb_const_get(rb_cObject,id_complex);
  return RTEST(rb_obj_is_kind_of(value,rb_cNumeric)) && !RTEST(rb_obj_is_kind_of(value,complex));
}
static bool integer_p(VALUE value) {
  return number_p(value) && RTEST(rb_funcall(value,id_finite_p,0)) && RTEST(rb_equal(rb_funcall(value,id_to_i,0),value));
}
static uint32_t instance_type(VALUE value, bool integer) {
  if (NIL_P(value)) return TYPE_NULL;
  if (value==Qtrue||value==Qfalse) return TYPE_BOOLEAN;
  if (RB_TYPE_P(value,T_HASH)) return TYPE_OBJECT;
  if (RB_TYPE_P(value,T_ARRAY)) return TYPE_ARRAY;
  if (RB_TYPE_P(value,T_STRING)) return TYPE_STRING;
  if (!number_p(value)) return 0;
  return integer && integer_p(value) ? TYPE_NUMBER|TYPE_INTEGER : TYPE_NUMBER;
}
static int compare_values(VALUE left, VALUE right) { return rb_cmpint(rb_funcall(left,id_compare,1,right),left,right); }
static VALUE decimal(VALUE value) {
  if (RB_INTEGER_TYPE_P(value) || RB_TYPE_P(value,T_RATIONAL)) return value;
  return rb_funcall(rb_mKernel,id_rational,1,rb_funcall(value,id_to_s,0));
}
static bool valid_number(rule_t *r, VALUE value) {
  VALUE actual = (r->mask&NUM_MULTIPLE_OF) ? decimal(value) : value;
  if ((r->mask&NUM_MAXIMUM) && compare_values(actual,r->as.number.maximum)>0) return false;
  if ((r->mask&NUM_MINIMUM) && compare_values(actual,r->as.number.minimum)<0) return false;
  if ((r->mask&NUM_EXCLUSIVE_MAXIMUM) && compare_values(actual,r->as.number.exclusive_maximum)>=0) return false;
  if ((r->mask&NUM_EXCLUSIVE_MINIMUM) && compare_values(actual,r->as.number.exclusive_minimum)<=0) return false;
  if (r->mask&NUM_MULTIPLE_OF) {
    VALUE divisor=decimal(r->as.number.multiple_of);
    return RTEST(rb_funcall(divisor,id_positive_p,0)) && RTEST(rb_funcall(rb_funcall(decimal(value),id_remainder,1,divisor),id_zero_p,0));
  }
  return true;
}

static bool json_equal(VALUE left, VALUE right) {
  if (number_p(left)) return number_p(right) && RTEST(rb_equal(left,right));
  if (CLASS_OF(left)!=CLASS_OF(right)) return false;
  if (RB_TYPE_P(left,T_ARRAY)) {
    if (RARRAY_LEN(left)!=RARRAY_LEN(right)) return false;
    for(long i=0;i<RARRAY_LEN(left);i++) if(!json_equal(rb_ary_entry(left,i),rb_ary_entry(right,i))) return false;
    return true;
  }
  if (RB_TYPE_P(left,T_HASH)) {
    if(RHASH_SIZE(left)!=RHASH_SIZE(right)) return false;
    VALUE keys=rb_funcall(left,id_keys,0);
    for(long i=0;i<RARRAY_LEN(keys);i++){VALUE k=rb_ary_entry(keys,i); if(!RTEST(rb_funcall(right,id_key_p,1,k))||!json_equal(rb_hash_aref(left,k),rb_hash_aref(right,k))) return false;}
    return true;
  }
  return RTEST(rb_equal(left,right));
}

struct protected_call { VALUE receiver; ID method; int argc; VALUE argv[3]; };
static VALUE protected_func(VALUE arg) { struct protected_call *c=(struct protected_call *)arg; return rb_funcallv(c->receiver,c->method,c->argc,c->argv); }
static bool protected_truth(struct protected_call *call) {
  int state=0; VALUE result=rb_protect(protected_func,(VALUE)call,&state);
  if(state){rb_set_errinfo(Qnil);return false;} return RTEST(result);
}
static VALUE regexp_for(evaluator_t *e, VALUE pattern) {
  VALUE found=rb_hash_lookup2(e->regexps,pattern,Qundef); if(found!=Qundef)return found;
  VALUE regexp=rb_funcall(mNativeSupport,id_regexp,1,pattern); rb_hash_aset(e->regexps,pattern,regexp); return regexp;
}
static bool valid_string(evaluator_t *e, rule_t *r, VALUE value) {
  long length=NUM2LONG(rb_funcall(value,id_length,0));
  if(!NIL_P(r->as.string.max_length)&&length>NUM2LONG(r->as.string.max_length))return false;
  if(!NIL_P(r->as.string.min_length)&&length<NUM2LONG(r->as.string.min_length))return false;
  if(!NIL_P(r->as.string.pattern)){struct protected_call c={regexp_for(e,r->as.string.pattern),id_match_p,1,{value}};if(!protected_truth(&c))return false;}
  if(!NIL_P(r->as.string.format)&&(e->format||r->as.string.format_assertion)){struct protected_call c={r->as.string.format,id_call,1,{value}};if(!protected_truth(&c))return false;}
  if(e->content&&(r->as.string.decode_base64||r->as.string.parse_json)){struct protected_call c={mNativeSupport,id_valid_content_p,3,{value,r->as.string.decode_base64?Qtrue:Qfalse,r->as.string.parse_json?Qtrue:Qfalse}};if(!protected_truth(&c))return false;}
  return true;
}

static evaluation_t evaluate_program_mode(evaluator_t *e, VALUE program, VALUE instance, bool collect);
static evaluation_t evaluate_program(evaluator_t *e, VALUE program, VALUE instance) {
  return evaluate_program_mode(e, program, instance, false);
}

static bool active_enter(evaluator_t *e, VALUE source, VALUE instance) {
  VALUE instances=rb_hash_lookup2(e->active,source,Qundef);
  if(instances==Qundef){instances=rb_hash_new();rb_funcall(instances,id_compare_by_identity,0);rb_hash_aset(e->active,source,instances);}
  if(rb_hash_lookup2(instances,instance,Qundef)!=Qundef)return false;
  rb_hash_aset(instances,instance,Qtrue);return true;
}
static void active_leave(evaluator_t *e,VALUE source,VALUE instance){VALUE instances=rb_hash_aref(e->active,source);rb_hash_delete(instances,instance);}
static VALUE reference_target(evaluator_t *e,VALUE source,VALUE rule_obj){
  VALUE target=rb_hash_lookup2(e->resolved,rule_obj,Qundef);if(target!=Qundef)return target;rule_t*r;TypedData_Get_Struct(rule_obj,rule_t,&rule_type,r);
  target=compiler_resolve(e->compiler,source,r->as.reference.value);rb_hash_aset(e->resolved,rule_obj,target);return target;
}
static VALUE recursive_target(evaluator_t*e,VALUE source,VALUE rule_obj){
  VALUE target=reference_target(e,source,rule_obj);rule_t*r;program_t*t;TypedData_Get_Struct(rule_obj,rule_t,&rule_type,r);TypedData_Get_Struct(target,program_t,&program_type,t);
  if(!RB_TYPE_P(r->as.reference.fragment,T_STRING)||RSTRING_LEN(r->as.reference.fragment)||!t->recursive_anchor)return target;
  for(long i=0;i<RARRAY_LEN(e->dynamic_scope);i++){VALUE resource=rb_ary_entry(e->dynamic_scope,i);VALUE candidate=compiler_compile(e->compiler,rb_funcall(resource,id_root,0));program_t*p;TypedData_Get_Struct(candidate,program_t,&program_type,p);if(p->recursive_anchor)return candidate;}return target;
}
static VALUE dynamic_target(evaluator_t*e,VALUE source,VALUE rule_obj){
  VALUE target=reference_target(e,source,rule_obj);rule_t*r;program_t*t;TypedData_Get_Struct(rule_obj,rule_t,&rule_type,r);TypedData_Get_Struct(target,program_t,&program_type,t);VALUE fragment=r->as.reference.fragment;
  if(NIL_P(fragment)||RSTRING_LEN(fragment)==0||RSTRING_PTR(fragment)[0]=='/'||
      !RB_TYPE_P(t->dynamic_anchor,T_STRING)||!RTEST(rb_str_equal(t->dynamic_anchor,fragment)))return target;
  for(long i=0;i<RARRAY_LEN(e->dynamic_scope);i++){VALUE resource=rb_ary_entry(e->dynamic_scope,i);VALUE node=rb_funcall(e->graph,id_dynamic_anchor,2,resource,fragment);if(!NIL_P(node))return compiler_compile(e->compiler,node);}return target;
}
struct target_call { evaluator_t *e; VALUE source, rule; uint8_t opcode; };
static VALUE target_func(VALUE arg){struct target_call*c=(struct target_call*)arg;if(c->opcode==OP_RECURSIVE_REF)return recursive_target(c->e,c->source,c->rule);if(c->opcode==OP_DYNAMIC_REF)return dynamic_target(c->e,c->source,c->rule);return reference_target(c->e,c->source,c->rule);}
static VALUE safe_target(evaluator_t*e,VALUE source,VALUE rule,uint8_t opcode,int*state){struct target_call call={e,source,rule,opcode};return rb_protect(target_func,(VALUE)&call,state);}
static evaluation_t evaluate_reference(evaluator_t*e,VALUE source,VALUE target,VALUE instance,bool collect){if(!active_enter(e,source,instance))return evaluation(true);evaluation_t r=evaluate_program_mode(e,target,instance,collect);active_leave(e,source,instance);return r;}

static evaluation_t valid_array(evaluator_t*e,rule_t*r,VALUE value,evaluation_t prior,bool collect){
  evaluation_t out=evaluation(true);long len=RARRAY_LEN(value);
  if(!NIL_P(r->as.array.max_items)&&len>NUM2LONG(r->as.array.max_items))return evaluation(false);
  if(!NIL_P(r->as.array.min_items)&&len<NUM2LONG(r->as.array.min_items))return evaluation(false);
  if(r->as.array.unique)for(long i=1;i<len;i++)for(long j=0;j<i;j++)if(json_equal(rb_ary_entry(value,j),rb_ary_entry(value,i)))return evaluation(false);
  if(!NIL_P(r->as.array.prefix_items))for(long i=0;i<RARRAY_LEN(r->as.array.prefix_items)&&i<len;i++){evaluation_t x=evaluate_program(e,rb_ary_entry(r->as.array.prefix_items,i),rb_ary_entry(value,i));if(!x.valid)return evaluation(false);if(collect)add_unique(&out.items,LONG2NUM(i));}
  if(r->as.array.items_list){long n=RARRAY_LEN(r->as.array.items);for(long i=0;i<n&&i<len;i++){evaluation_t x=evaluate_program(e,rb_ary_entry(r->as.array.items,i),rb_ary_entry(value,i));if(!x.valid)return evaluation(false);if(collect)add_unique(&out.items,LONG2NUM(i));}if(!NIL_P(r->as.array.additional))for(long i=n;i<len;i++){evaluation_t x=evaluate_program(e,r->as.array.additional,rb_ary_entry(value,i));if(!x.valid)return evaluation(false);if(collect)add_unique(&out.items,LONG2NUM(i));}}
  else if(!NIL_P(r->as.array.items)){long start=NIL_P(r->as.array.prefix_items)?0:RARRAY_LEN(r->as.array.prefix_items);for(long i=start;i<len;i++){evaluation_t x=evaluate_program(e,r->as.array.items,rb_ary_entry(value,i));if(!x.valid)return evaluation(false);if(collect)add_unique(&out.items,LONG2NUM(i));}}
  if(!NIL_P(r->as.array.contains)){long matches=0;VALUE matched=collect?rb_ary_new():Qnil;for(long i=0;i<len;i++)if(evaluate_program(e,r->as.array.contains,rb_ary_entry(value,i)).valid){matches++;if(collect)rb_ary_push(matched,LONG2NUM(i));}if(matches<NUM2LONG(r->as.array.min_contains)||compare_values(LONG2NUM(matches),r->as.array.max_contains)>0)return evaluation(false);if(collect)merge_locations(&out.items,matched);}
  if(!NIL_P(r->as.array.unevaluated))for(long i=0;i<len;i++){VALUE index=LONG2NUM(i);if(has_location(prior.items,index)||has_location(out.items,index))continue;evaluation_t x=evaluate_program(e,r->as.array.unevaluated,rb_ary_entry(value,i));if(!x.valid)return evaluation(false);add_unique(&out.items,index);}
  return out;
}

static bool required_present(VALUE object,VALUE names){if(NIL_P(names))return true;for(long i=0;i<RARRAY_LEN(names);i++)if(!RTEST(rb_funcall(object,id_key_p,1,rb_ary_entry(names,i))))return false;return true;}
static evaluation_t valid_object(evaluator_t*e,rule_t*r,VALUE value,evaluation_t prior,bool collect){
  evaluation_t out=evaluation(true);long len=RHASH_SIZE(value);if(!NIL_P(r->as.object.max_properties)&&len>NUM2LONG(r->as.object.max_properties))return evaluation(false);if(!NIL_P(r->as.object.min_properties)&&len<NUM2LONG(r->as.object.min_properties))return evaluation(false);if(!required_present(value,r->as.object.required))return evaluation(false);
  VALUE keys=rb_funcall(value,id_keys,0);
  for(long i=0;i<RARRAY_LEN(keys);i++){VALUE name=rb_ary_entry(keys,i),item=rb_hash_aref(value,name);bool matched=false;VALUE child=rb_hash_lookup2(r->as.object.properties,name,Qundef);if(child!=Qundef){matched=true;if(!evaluate_program(e,child,item).valid)return evaluation(false);if(collect)add_unique(&out.properties,name);}if(!NIL_P(r->as.object.patterns)){VALUE patterns=rb_funcall(r->as.object.patterns,id_keys,0);for(long j=0;j<RARRAY_LEN(patterns);j++){VALUE pattern=rb_ary_entry(patterns,j);struct protected_call c={regexp_for(e,pattern),id_match_p,1,{name}};if(protected_truth(&c)){matched=true;if(!evaluate_program(e,rb_hash_aref(r->as.object.patterns,pattern),item).valid)return evaluation(false);if(collect)add_unique(&out.properties,name);}}}if(!matched&&!NIL_P(r->as.object.additional)){if(!evaluate_program(e,r->as.object.additional,item).valid)return evaluation(false);if(collect)add_unique(&out.properties,name);}}
  if(!NIL_P(r->as.object.property_names))for(long i=0;i<RARRAY_LEN(keys);i++)if(!evaluate_program(e,r->as.object.property_names,rb_ary_entry(keys,i)).valid)return evaluation(false);
  VALUE dep_sets[]={r->as.object.dependencies,r->as.object.dependent_required};for(int d=0;d<2;d++)if(!NIL_P(dep_sets[d])){VALUE names=rb_funcall(dep_sets[d],id_keys,0);for(long i=0;i<RARRAY_LEN(names);i++){VALUE name=rb_ary_entry(names,i);if(!RTEST(rb_funcall(value,id_key_p,1,name)))continue;VALUE dep=rb_hash_aref(dep_sets[d],name);if(RB_TYPE_P(dep,T_ARRAY)){if(!required_present(value,dep))return evaluation(false);}else{evaluation_t x=evaluate_program_mode(e,dep,value,collect);if(!x.valid)return evaluation(false);if(collect)merge_locations(&out.properties,x.properties);}}}
  if(!NIL_P(r->as.object.dependent_schemas)){VALUE names=rb_funcall(r->as.object.dependent_schemas,id_keys,0);for(long i=0;i<RARRAY_LEN(names);i++){VALUE name=rb_ary_entry(names,i);if(!RTEST(rb_funcall(value,id_key_p,1,name)))continue;evaluation_t x=evaluate_program_mode(e,rb_hash_aref(r->as.object.dependent_schemas,name),value,collect);if(!x.valid)return evaluation(false);if(collect)merge_locations(&out.properties,x.properties);}}
  if(!NIL_P(r->as.object.unevaluated))for(long i=0;i<RARRAY_LEN(keys);i++){VALUE name=rb_ary_entry(keys,i);if(has_location(prior.properties,name)||has_location(out.properties,name))continue;if(!evaluate_program(e,r->as.object.unevaluated,rb_hash_aref(value,name)).valid)return evaluation(false);add_unique(&out.properties,name);}
  return out;
}

static evaluation_t evaluate_program_mode(evaluator_t*e,VALUE program,VALUE instance,bool collect){
  program_t*p;TypedData_Get_Struct(program,program_t,&program_type,p);evaluation_t out=evaluation(true);bool entered=false;
  collect=collect||(p->flags&FLAG_EVALUATION);
  if(p->flags&FLAG_DYNAMIC_SCOPE){VALUE resource=rb_funcall(p->node,id_resource,0);if(RARRAY_LEN(e->dynamic_scope)==0||rb_ary_entry(e->dynamic_scope,-1)!=resource){rb_ary_push(e->dynamic_scope,resource);entered=true;}}
  for(size_t i=0;i<p->length&&out.valid;i++){instruction_t*ins=&p->instructions[i];rule_t*r=NULL;if(rb_typeddata_is_kind_of(ins->operand,&rule_type))TypedData_Get_Struct(ins->operand,rule_t,&rule_type,r);evaluation_t x=evaluation(true);
    switch(ins->opcode){
      case OP_BOOLEAN:out.valid=RTEST(ins->operand);break;
      case OP_REF:case OP_RECURSIVE_REF:case OP_DYNAMIC_REF:{int state=0;VALUE target=safe_target(e,program,ins->operand,ins->opcode,&state);if(state){if(!RTEST(rb_obj_is_kind_of(rb_errinfo(),eResolutionError)))rb_jump_tag(state);rb_set_errinfo(Qnil);out.valid=false;}else{x=evaluate_reference(e,program,target,instance,collect);merge_evaluation(&out,x);}break;}
      case OP_TYPE_NULL:out.valid=NIL_P(instance);break;case OP_TYPE_BOOLEAN:out.valid=instance==Qtrue||instance==Qfalse;break;case OP_TYPE_OBJECT:out.valid=RB_TYPE_P(instance,T_HASH);break;case OP_TYPE_ARRAY:out.valid=RB_TYPE_P(instance,T_ARRAY);break;case OP_TYPE_NUMBER:out.valid=number_p(instance);break;case OP_TYPE_INTEGER:out.valid=integer_p(instance);break;case OP_TYPE_STRING:out.valid=RB_TYPE_P(instance,T_STRING);break;
      case OP_TYPES:out.valid=(r->mask&instance_type(instance,(r->mask&TYPE_INTEGER)!=0))!=0;break;
      case OP_ENUM:out.valid=false;for(long j=0;j<RARRAY_LEN(ins->operand);j++)if(json_equal(rb_ary_entry(ins->operand,j),instance)){out.valid=true;break;}break;
      case OP_CONST:out.valid=json_equal(ins->operand,instance);break;
      case OP_ALL_OF:for(long j=0;j<RARRAY_LEN(ins->operand);j++){x=evaluate_program_mode(e,rb_ary_entry(ins->operand,j),instance,collect);merge_evaluation(&out,x);if(!out.valid)break;}break;
      case OP_ANY_OF:{bool matched=false;for(long j=0;j<RARRAY_LEN(ins->operand);j++){x=evaluate_program_mode(e,rb_ary_entry(ins->operand,j),instance,collect);if(x.valid){matched=true;merge_evaluation(&out,x);if(!collect)break;}}out.valid=matched;break;}
      case OP_ONE_OF:{long matches=0;evaluation_t found=evaluation(true);for(long j=0;j<RARRAY_LEN(ins->operand);j++){x=evaluate_program_mode(e,rb_ary_entry(ins->operand,j),instance,collect);if(x.valid){matches++;found=x;if(matches>1)break;}}if(matches==1)merge_evaluation(&out,found);else out.valid=false;break;}
      case OP_NOT:out.valid=!evaluate_program(e,ins->operand,instance).valid;break;
      case OP_CONDITIONAL:x=evaluate_program_mode(e,r->as.conditional.condition,instance,collect);if(x.valid){merge_evaluation(&out,x);if(!NIL_P(r->as.conditional.then_branch))merge_evaluation(&out,evaluate_program_mode(e,r->as.conditional.then_branch,instance,collect));}else if(!NIL_P(r->as.conditional.else_branch))merge_evaluation(&out,evaluate_program_mode(e,r->as.conditional.else_branch,instance,collect));break;
      case OP_NUMBER:if(number_p(instance))out.valid=valid_number(r,instance);break;case OP_STRING:if(RB_TYPE_P(instance,T_STRING))out.valid=valid_string(e,r,instance);break;
      case OP_ARRAY:if(RB_TYPE_P(instance,T_ARRAY)){x=valid_array(e,r,instance,out,collect);merge_evaluation(&out,x);}break;case OP_OBJECT:if(RB_TYPE_P(instance,T_HASH)){x=valid_object(e,r,instance,out,collect);merge_evaluation(&out,x);}break;
      case OP_TYPED_NUMBER:out.valid=number_p(instance)&&valid_number(r,instance);break;case OP_TYPED_INTEGER:out.valid=integer_p(instance)&&valid_number(r,instance);break;case OP_TYPED_STRING:out.valid=RB_TYPE_P(instance,T_STRING)&&valid_string(e,r,instance);break;
      case OP_TYPED_ARRAY:if(RB_TYPE_P(instance,T_ARRAY)){x=valid_array(e,r,instance,out,collect);merge_evaluation(&out,x);}else out.valid=false;break;case OP_TYPED_OBJECT:if(RB_TYPE_P(instance,T_HASH)){x=valid_object(e,r,instance,out,collect);merge_evaluation(&out,x);}else out.valid=false;break;
    }
  }
  if(entered)rb_ary_pop(e->dynamic_scope);
  return out;
}

static VALUE compiler_evaluator(int argc,VALUE*argv,VALUE self){
  VALUE node,options;rb_scan_args(argc,argv,"1:",&node,&options);
  compiler_t*c;TypedData_Get_Struct(self,compiler_t,&compiler_type,c);
  VALUE evaluator=evaluator_alloc(cEvaluator);evaluator_t*e;TypedData_Get_Struct(evaluator,evaluator_t,&evaluator_type,e);
  RB_OBJ_WRITE(evaluator,&e->graph,c->graph);RB_OBJ_WRITE(evaluator,&e->compiler,self);RB_OBJ_WRITE(evaluator,&e->root,compiler_compile(self,node));
  RB_OBJ_WRITE(evaluator,&e->regexps,rb_hash_new());RB_OBJ_WRITE(evaluator,&e->resolved,rb_hash_new());rb_funcall(e->resolved,id_compare_by_identity,0);
  RB_OBJ_WRITE(evaluator,&e->active,rb_hash_new());rb_funcall(e->active,id_compare_by_identity,0);RB_OBJ_WRITE(evaluator,&e->dynamic_scope,rb_ary_new());
  e->content=RTEST(rb_hash_aref(options,sym_content));e->format=RTEST(rb_hash_aref(options,sym_format));return evaluator;
}
static VALUE evaluator_backend(VALUE self){return sym_vm;}
static bool supported_instance(VALUE value){
  if(NIL_P(value)||value==Qtrue||value==Qfalse||RB_INTEGER_TYPE_P(value))return true;
  if(CLASS_OF(value)==rb_cFloat)return RTEST(rb_funcall(value,id_finite_p,0));
  if(CLASS_OF(value)==rb_cString)return true;
  if(CLASS_OF(value)==rb_cArray){for(long i=0;i<RARRAY_LEN(value);i++)if(!supported_instance(rb_ary_entry(value,i)))return false;return true;}
  if(CLASS_OF(value)==rb_cHash){VALUE keys=rb_funcall(value,id_keys,0);for(long i=0;i<RARRAY_LEN(keys);i++){VALUE key=rb_ary_entry(keys,i);if(CLASS_OF(key)!=rb_cString||!supported_instance(rb_hash_aref(value,key)))return false;}return true;}
  return false;
}
static VALUE ruby_evaluator(evaluator_t*e){program_t*p;TypedData_Get_Struct(e->root,program_t,&program_type,p);VALUE kwargs=rb_hash_new();rb_hash_aset(kwargs,sym_content,e->content?Qtrue:Qfalse);rb_hash_aset(kwargs,sym_format,e->format?Qtrue:Qfalse);VALUE argv[]={e->graph,p->node,kwargs};return rb_class_new_instance_kw(3,argv,cRubyEvaluator,RB_PASS_KEYWORDS);}
static VALUE evaluator_valid(VALUE self,VALUE instance){evaluator_t*e;TypedData_Get_Struct(self,evaluator_t,&evaluator_type,e);if(!supported_instance(instance))return rb_funcall(ruby_evaluator(e),id_valid_p,1,instance);rb_ary_clear(e->dynamic_scope);rb_hash_clear(e->active);return evaluate_program(e,e->root,instance).valid?Qtrue:Qfalse;}

static VALUE pointer(VALUE path,VALUE final,bool has_final){VALUE result=rb_str_buf_new(0);long n=RARRAY_LEN(path)+(has_final?1:0);for(long i=0;i<n;i++){VALUE segment=i<RARRAY_LEN(path)?rb_ary_entry(path,i):final;VALUE string=rb_funcall(segment,id_to_s,0);string=rb_funcall(string,id_gsub,2,STATIC_STRING(TILDE),STATIC_STRING(ESCAPED_TILDE));string=rb_funcall(string,id_gsub,2,STATIC_STRING(SLASH),STATIC_STRING(ESCAPED_SLASH));rb_str_cat_cstr(result,"/");rb_str_append(result,string);}return result;}

/* Detailed diagnostics use the same native programs, adding only public Ruby
 * ValidationError objects at the API boundary. */
static VALUE error_message(ID method,int argc,VALUE*a){return rb_funcallv(mErrorMessage,method,argc,a);}
static void add_error(evaluator_t*e,VALUE keyword,VALUE message,bool append_keyword){VALUE kwargs=rb_hash_new();rb_hash_aset(kwargs,sym_keyword,keyword);rb_hash_aset(kwargs,sym_instance_path,pointer(e->instance_path,Qnil,false));rb_hash_aset(kwargs,sym_schema_path,pointer(e->schema_path,keyword,append_keyword));rb_hash_aset(kwargs,sym_message,message);VALUE argv[]={kwargs};rb_ary_push(e->errors,rb_class_new_instance_kw(1,argv,cValidationError,RB_PASS_KEYWORDS));e->error_count++;}
static void add_message0(evaluator_t*e,VALUE keyword,ID method){add_error(e,keyword,error_message(method,0,NULL),true);}
static evaluation_t evaluate_detail(evaluator_t*e,VALUE program,VALUE instance);
static evaluation_t detail_at(evaluator_t*e,VALUE program,VALUE instance,VALUE instance_segment,bool has_instance,VALUE schema_segment,VALUE child_segment,bool has_child){if(has_instance)rb_ary_push(e->instance_path,instance_segment);rb_ary_push(e->schema_path,schema_segment);if(has_child)rb_ary_push(e->schema_path,child_segment);evaluation_t out=evaluate_detail(e,program,instance);if(has_child)rb_ary_pop(e->schema_path);rb_ary_pop(e->schema_path);if(has_instance)rb_ary_pop(e->instance_path);return out;}
static evaluation_t detail_reference(evaluator_t*e,VALUE source,VALUE target,VALUE instance,VALUE keyword){if(!active_enter(e,source,instance))return evaluation(true);evaluation_t out=detail_at(e,target,instance,Qnil,false,keyword,Qnil,false);active_leave(e,source,instance);return out;}

static void check_number_detail(evaluator_t*e,rule_t*r,VALUE value){VALUE actual=(r->mask&NUM_MULTIPLE_OF)?decimal(value):value;VALUE keys[]={STATIC_STRING(MAXIMUM),STATIC_STRING(MINIMUM),STATIC_STRING(EXCLUSIVE_MAXIMUM),STATIC_STRING(EXCLUSIVE_MINIMUM)};VALUE limits[]={r->as.number.maximum,r->as.number.minimum,r->as.number.exclusive_maximum,r->as.number.exclusive_minimum};for(int i=0;i<4;i++)if(r->mask&(1u<<i)){int comparison=compare_values(actual,limits[i]);bool invalid=(i==0&&comparison>0)||(i==1&&comparison<0)||(i==2&&comparison>=0)||(i==3&&comparison<=0);if(invalid){VALUE a[]={keys[i],limits[i]};add_error(e,keys[i],error_message(id_error_numeric_limit,2,a),true);}}if(r->mask&NUM_MULTIPLE_OF){VALUE divisor=decimal(r->as.number.multiple_of);bool ok=RTEST(rb_funcall(divisor,id_positive_p,0))&&RTEST(rb_funcall(rb_funcall(decimal(value),id_remainder,1,divisor),id_zero_p,0));if(!ok){VALUE a[]={r->as.number.multiple_of};add_error(e,STATIC_STRING(MULTIPLE_OF),error_message(id_error_multiple_of,1,a),true);}}}
static void check_type_detail(evaluator_t*e,VALUE expected,VALUE value,bool valid){if(valid)return;VALUE a[]={expected,value};add_error(e,STATIC_STRING(TYPE),error_message(id_error_type,2,a),true);}
static void check_string_detail(evaluator_t*e,rule_t*r,VALUE value){long len=NUM2LONG(rb_funcall(value,id_length,0));if(!NIL_P(r->as.string.max_length)&&len>NUM2LONG(r->as.string.max_length)){VALUE a[]={STATIC_STRING(MAX_LENGTH),r->as.string.max_length,LONG2NUM(len)};add_error(e,STATIC_STRING(MAX_LENGTH),error_message(id_error_size,3,a),true);}if(!NIL_P(r->as.string.min_length)&&len<NUM2LONG(r->as.string.min_length)){VALUE a[]={STATIC_STRING(MIN_LENGTH),r->as.string.min_length,LONG2NUM(len)};add_error(e,STATIC_STRING(MIN_LENGTH),error_message(id_error_size,3,a),true);}if(!NIL_P(r->as.string.pattern)){int state=0;VALUE regexp=rb_protect(protected_func,(VALUE)&(struct protected_call){mNativeSupport,id_regexp,1,{r->as.string.pattern}},&state);if(state){rb_set_errinfo(Qnil);VALUE a[]={r->as.string.pattern};add_error(e,STATIC_STRING(PATTERN),error_message(id_error_invalid_pattern,1,a),true);}else if(!RTEST(rb_funcall(regexp,id_match_p,1,value))){VALUE a[]={r->as.string.pattern};add_error(e,STATIC_STRING(PATTERN),error_message(id_error_pattern,1,a),true);}}if(!NIL_P(r->as.string.format)&&(e->format||r->as.string.format_assertion)&&!RTEST(rb_funcall(r->as.string.format,id_call,1,value))){VALUE a[]={rb_funcall(r->as.string.format,id_name,0)};add_error(e,STATIC_STRING(FORMAT),error_message(id_error_format,1,a),true);}if(e->content&&(r->as.string.decode_base64||r->as.string.parse_json)&&!RTEST(rb_funcall(mNativeSupport,id_valid_content_p,3,value,r->as.string.decode_base64?Qtrue:Qfalse,r->as.string.parse_json?Qtrue:Qfalse))){if(r->as.string.decode_base64)add_message0(e,STATIC_STRING(CONTENT_ENCODING),id_error_content_encoding);else add_message0(e,STATIC_STRING(CONTENT_MEDIA_TYPE),id_error_content_media_type);}}

static evaluation_t check_array_detail(evaluator_t*e,rule_t*r,VALUE value,evaluation_t prior){evaluation_t out=evaluation(true);long before=e->error_count,len=RARRAY_LEN(value);if(!NIL_P(r->as.array.max_items)&&len>NUM2LONG(r->as.array.max_items)){VALUE a[]={STATIC_STRING(MAX_ITEMS),r->as.array.max_items,LONG2NUM(len)};add_error(e,STATIC_STRING(MAX_ITEMS),error_message(id_error_size,3,a),true);}if(!NIL_P(r->as.array.min_items)&&len<NUM2LONG(r->as.array.min_items)){VALUE a[]={STATIC_STRING(MIN_ITEMS),r->as.array.min_items,LONG2NUM(len)};add_error(e,STATIC_STRING(MIN_ITEMS),error_message(id_error_size,3,a),true);}if(r->as.array.unique){bool duplicate=false;for(long i=1;i<len&&!duplicate;i++)for(long j=0;j<i;j++)if(json_equal(rb_ary_entry(value,j),rb_ary_entry(value,i))){duplicate=true;break;}if(duplicate)add_message0(e,STATIC_STRING(UNIQUE_ITEMS),id_error_unique_items);}
  if(!NIL_P(r->as.array.prefix_items))for(long i=0;i<RARRAY_LEN(r->as.array.prefix_items)&&i<len;i++){detail_at(e,rb_ary_entry(r->as.array.prefix_items,i),rb_ary_entry(value,i),LONG2NUM(i),true,STATIC_STRING(PREFIX_ITEMS),LONG2NUM(i),true);add_unique(&out.items,LONG2NUM(i));}
  if(r->as.array.items_list){long n=RARRAY_LEN(r->as.array.items);for(long i=0;i<n&&i<len;i++){detail_at(e,rb_ary_entry(r->as.array.items,i),rb_ary_entry(value,i),LONG2NUM(i),true,STATIC_STRING(ITEMS),LONG2NUM(i),true);add_unique(&out.items,LONG2NUM(i));}if(!NIL_P(r->as.array.additional))for(long i=n;i<len;i++){detail_at(e,r->as.array.additional,rb_ary_entry(value,i),LONG2NUM(i),true,STATIC_STRING(ADDITIONAL_ITEMS),Qnil,false);add_unique(&out.items,LONG2NUM(i));}}
  else if(!NIL_P(r->as.array.items)){long start=NIL_P(r->as.array.prefix_items)?0:RARRAY_LEN(r->as.array.prefix_items);for(long i=start;i<len;i++){detail_at(e,r->as.array.items,rb_ary_entry(value,i),LONG2NUM(i),true,STATIC_STRING(ITEMS),Qnil,false);add_unique(&out.items,LONG2NUM(i));}}
  if(!NIL_P(r->as.array.contains)){VALUE matched=rb_ary_new();for(long i=0;i<len;i++)if(evaluate_program(e,r->as.array.contains,rb_ary_entry(value,i)).valid)rb_ary_push(matched,LONG2NUM(i));long count=RARRAY_LEN(matched);if(count<NUM2LONG(r->as.array.min_contains)||compare_values(LONG2NUM(count),r->as.array.max_contains)>0){VALUE a[]={LONG2NUM(count),r->as.array.min_contains,r->as.array.max_contains};add_error(e,STATIC_STRING(CONTAINS),error_message(id_error_contains,3,a),true);}merge_locations(&out.items,matched);}
  if(!NIL_P(r->as.array.unevaluated))for(long i=0;i<len;i++){VALUE index=LONG2NUM(i);if(has_location(prior.items,index)||has_location(out.items,index))continue;detail_at(e,r->as.array.unevaluated,rb_ary_entry(value,i),index,true,STATIC_STRING(UNEVALUATED_ITEMS),Qnil,false);add_unique(&out.items,index);}
  out.valid=e->error_count==before;return out;}

static evaluation_t check_object_detail(evaluator_t*e,rule_t*r,VALUE value,evaluation_t prior){evaluation_t out=evaluation(true);long before=e->error_count,len=RHASH_SIZE(value);if(!NIL_P(r->as.object.max_properties)&&len>NUM2LONG(r->as.object.max_properties)){VALUE a[]={STATIC_STRING(MAX_PROPERTIES),r->as.object.max_properties,LONG2NUM(len)};add_error(e,STATIC_STRING(MAX_PROPERTIES),error_message(id_error_size,3,a),true);}if(!NIL_P(r->as.object.min_properties)&&len<NUM2LONG(r->as.object.min_properties)){VALUE a[]={STATIC_STRING(MIN_PROPERTIES),r->as.object.min_properties,LONG2NUM(len)};add_error(e,STATIC_STRING(MIN_PROPERTIES),error_message(id_error_size,3,a),true);}if(!NIL_P(r->as.object.required))for(long i=0;i<RARRAY_LEN(r->as.object.required);i++){VALUE name=rb_ary_entry(r->as.object.required,i);if(!RTEST(rb_funcall(value,id_key_p,1,name))){VALUE a[]={name};add_error(e,STATIC_STRING(REQUIRED),error_message(id_error_required,1,a),true);}}
  VALUE keys=rb_funcall(value,id_keys,0);for(long i=0;i<RARRAY_LEN(keys);i++){VALUE name=rb_ary_entry(keys,i),item=rb_hash_aref(value,name);bool matched=false;VALUE child=rb_hash_lookup2(r->as.object.properties,name,Qundef);if(child!=Qundef){matched=true;detail_at(e,child,item,name,true,STATIC_STRING(PROPERTIES),name,true);add_unique(&out.properties,name);}if(!NIL_P(r->as.object.patterns)){VALUE patterns=rb_funcall(r->as.object.patterns,id_keys,0);for(long j=0;j<RARRAY_LEN(patterns);j++){VALUE pattern=rb_ary_entry(patterns,j);if(RTEST(rb_funcall(regexp_for(e,pattern),id_match_p,1,name))){matched=true;detail_at(e,rb_hash_aref(r->as.object.patterns,pattern),item,name,true,STATIC_STRING(PATTERN_PROPERTIES),pattern,true);add_unique(&out.properties,name);}}}if(!matched&&!NIL_P(r->as.object.additional)){detail_at(e,r->as.object.additional,item,name,true,STATIC_STRING(ADDITIONAL_PROPERTIES),Qnil,false);add_unique(&out.properties,name);}}
  if(!NIL_P(r->as.object.property_names))for(long i=0;i<RARRAY_LEN(keys);i++){VALUE name=rb_ary_entry(keys,i);detail_at(e,r->as.object.property_names,name,name,true,STATIC_STRING(PROPERTY_NAMES),Qnil,false);}
  if(!NIL_P(r->as.object.dependencies)){VALUE names=rb_funcall(r->as.object.dependencies,id_keys,0);for(long i=0;i<RARRAY_LEN(names);i++){VALUE name=rb_ary_entry(names,i);if(!RTEST(rb_funcall(value,id_key_p,1,name)))continue;VALUE dep=rb_hash_aref(r->as.object.dependencies,name);if(RB_TYPE_P(dep,T_ARRAY)){for(long j=0;j<RARRAY_LEN(dep);j++){VALUE req=rb_ary_entry(dep,j);if(!RTEST(rb_funcall(value,id_key_p,1,req))){VALUE a[]={name,req};add_error(e,STATIC_STRING(DEPENDENCIES),error_message(id_error_dependent_required,2,a),true);}}}else{evaluation_t x=detail_at(e,dep,value,Qnil,false,STATIC_STRING(DEPENDENCIES),name,true);if(x.valid)merge_locations(&out.properties,x.properties);}}}
  if(!NIL_P(r->as.object.dependent_required)){VALUE names=rb_funcall(r->as.object.dependent_required,id_keys,0);for(long i=0;i<RARRAY_LEN(names);i++){VALUE name=rb_ary_entry(names,i);if(!RTEST(rb_funcall(value,id_key_p,1,name)))continue;VALUE reqs=rb_hash_aref(r->as.object.dependent_required,name);for(long j=0;j<RARRAY_LEN(reqs);j++){VALUE req=rb_ary_entry(reqs,j);if(!RTEST(rb_funcall(value,id_key_p,1,req))){VALUE a[]={name,req};add_error(e,STATIC_STRING(DEPENDENT_REQUIRED),error_message(id_error_dependent_required,2,a),true);}}}}
  if(!NIL_P(r->as.object.dependent_schemas)){VALUE names=rb_funcall(r->as.object.dependent_schemas,id_keys,0);for(long i=0;i<RARRAY_LEN(names);i++){VALUE name=rb_ary_entry(names,i);if(!RTEST(rb_funcall(value,id_key_p,1,name)))continue;evaluation_t x=detail_at(e,rb_hash_aref(r->as.object.dependent_schemas,name),value,Qnil,false,STATIC_STRING(DEPENDENT_SCHEMAS),name,true);if(x.valid)merge_locations(&out.properties,x.properties);}}
  if(!NIL_P(r->as.object.unevaluated))for(long i=0;i<RARRAY_LEN(keys);i++){VALUE name=rb_ary_entry(keys,i);if(has_location(prior.properties,name)||has_location(out.properties,name))continue;detail_at(e,r->as.object.unevaluated,rb_hash_aref(value,name),name,true,STATIC_STRING(UNEVALUATED_PROPERTIES),Qnil,false);add_unique(&out.properties,name);}
  out.valid=e->error_count==before;return out;}

static evaluation_t check_combiner_detail(evaluator_t*e,uint8_t op,VALUE operand,VALUE value){evaluation_t out=evaluation(true);if(op==OP_ALL_OF){for(long i=0;i<RARRAY_LEN(operand);i++)merge_evaluation(&out,detail_at(e,rb_ary_entry(operand,i),value,Qnil,false,STATIC_STRING(ALL_OF),LONG2NUM(i),true));}else if(op==OP_ANY_OF||op==OP_ONE_OF){long matches=0;evaluation_t matched=evaluation(true);for(long i=0;i<RARRAY_LEN(operand);i++){evaluation_t x=evaluate_program_mode(e,rb_ary_entry(operand,i),value,true);if(x.valid){matches++;merge_evaluation(&matched,x);}}if(op==OP_ANY_OF&&matches==0)add_message0(e,STATIC_STRING(ANY_OF),id_error_any_of);else if(op==OP_ONE_OF&&matches!=1){VALUE a[]={LONG2NUM(matches)};add_error(e,STATIC_STRING(ONE_OF),error_message(id_error_one_of,1,a),true);}else merge_evaluation(&out,matched);}else if(op==OP_NOT){if(evaluate_program(e,operand,value).valid)add_message0(e,STATIC_STRING(NOT),id_error_not);}else{rule_t*r;TypedData_Get_Struct(operand,rule_t,&rule_type,r);evaluation_t condition=evaluate_program_mode(e,r->as.conditional.condition,value,true);if(condition.valid){merge_evaluation(&out,condition);if(!NIL_P(r->as.conditional.then_branch))merge_evaluation(&out,detail_at(e,r->as.conditional.then_branch,value,Qnil,false,STATIC_STRING(THEN),Qnil,false));}else if(!NIL_P(r->as.conditional.else_branch))merge_evaluation(&out,detail_at(e,r->as.conditional.else_branch,value,Qnil,false,STATIC_STRING(ELSE),Qnil,false));}return out;}

static evaluation_t evaluate_detail(evaluator_t*e,VALUE program,VALUE instance){program_t*p;TypedData_Get_Struct(program,program_t,&program_type,p);long before=e->error_count;evaluation_t out=evaluation(true);bool entered=false;if(p->flags&FLAG_DYNAMIC_SCOPE){VALUE resource=rb_funcall(p->node,id_resource,0);if(RARRAY_LEN(e->dynamic_scope)==0||rb_ary_entry(e->dynamic_scope,-1)!=resource){rb_ary_push(e->dynamic_scope,resource);entered=true;}}
  for(size_t i=0;i<p->length;i++){instruction_t*ins=&p->instructions[i];rule_t*r=NULL;if(rb_typeddata_is_kind_of(ins->operand,&rule_type))TypedData_Get_Struct(ins->operand,rule_t,&rule_type,r);evaluation_t x=evaluation(true);switch(ins->opcode){case OP_BOOLEAN:if(!RTEST(ins->operand))add_error(e,STATIC_STRING(FALSE_SCHEMA),error_message(id_error_false_schema,0,NULL),false);break;case OP_REF:case OP_RECURSIVE_REF:case OP_DYNAMIC_REF:{int state=0;VALUE target=safe_target(e,program,ins->operand,ins->opcode,&state);VALUE keyword=ins->opcode==OP_REF?STATIC_STRING(REF):ins->opcode==OP_RECURSIVE_REF?STATIC_STRING(RECURSIVE_REF):STATIC_STRING(DYNAMIC_REF);if(state){VALUE error=rb_errinfo();if(!RTEST(rb_obj_is_kind_of(error,eResolutionError)))rb_jump_tag(state);VALUE message=rb_funcall(error,id_message,0);rb_set_errinfo(Qnil);add_error(e,keyword,message,false);}else{x=detail_reference(e,program,target,instance,keyword);merge_evaluation(&out,x);}break;}
    case OP_TYPE_NULL:check_type_detail(e,STATIC_STRING(NULL_TYPE),instance,NIL_P(instance));break;case OP_TYPE_BOOLEAN:check_type_detail(e,STATIC_STRING(BOOLEAN_TYPE),instance,instance==Qtrue||instance==Qfalse);break;case OP_TYPE_OBJECT:check_type_detail(e,STATIC_STRING(OBJECT_TYPE),instance,RB_TYPE_P(instance,T_HASH));break;case OP_TYPE_ARRAY:check_type_detail(e,STATIC_STRING(ARRAY_TYPE),instance,RB_TYPE_P(instance,T_ARRAY));break;case OP_TYPE_NUMBER:check_type_detail(e,STATIC_STRING(NUMBER_TYPE),instance,number_p(instance));break;case OP_TYPE_INTEGER:check_type_detail(e,STATIC_STRING(INTEGER_TYPE),instance,integer_p(instance));break;case OP_TYPE_STRING:check_type_detail(e,STATIC_STRING(STRING_TYPE),instance,RB_TYPE_P(instance,T_STRING));break;case OP_TYPES:check_type_detail(e,r->as.types.names,instance,(r->mask&instance_type(instance,(r->mask&TYPE_INTEGER)!=0))!=0);break;
    case OP_ENUM:{bool ok=false;for(long j=0;j<RARRAY_LEN(ins->operand);j++)if(json_equal(rb_ary_entry(ins->operand,j),instance)){ok=true;break;}if(!ok)add_message0(e,STATIC_STRING(ENUM),id_error_enum);break;}case OP_CONST:if(!json_equal(ins->operand,instance))add_message0(e,STATIC_STRING(CONST),id_error_const);break;
    case OP_ALL_OF:case OP_ANY_OF:case OP_ONE_OF:case OP_NOT:case OP_CONDITIONAL:x=check_combiner_detail(e,ins->opcode,ins->operand,instance);merge_evaluation(&out,x);break;
    case OP_NUMBER:if(number_p(instance))check_number_detail(e,r,instance);break;case OP_STRING:if(RB_TYPE_P(instance,T_STRING))check_string_detail(e,r,instance);break;case OP_ARRAY:if(RB_TYPE_P(instance,T_ARRAY)){x=check_array_detail(e,r,instance,out);merge_evaluation(&out,x);}break;case OP_OBJECT:if(RB_TYPE_P(instance,T_HASH)){x=check_object_detail(e,r,instance,out);merge_evaluation(&out,x);}break;
    case OP_TYPED_NUMBER:if(number_p(instance))check_number_detail(e,r,instance);else check_type_detail(e,STATIC_STRING(NUMBER_TYPE),instance,false);break;case OP_TYPED_INTEGER:if(number_p(instance)){check_type_detail(e,STATIC_STRING(INTEGER_TYPE),instance,integer_p(instance));check_number_detail(e,r,instance);}else check_type_detail(e,STATIC_STRING(INTEGER_TYPE),instance,false);break;case OP_TYPED_STRING:if(RB_TYPE_P(instance,T_STRING))check_string_detail(e,r,instance);else check_type_detail(e,STATIC_STRING(STRING_TYPE),instance,false);break;case OP_TYPED_ARRAY:if(RB_TYPE_P(instance,T_ARRAY)){x=check_array_detail(e,r,instance,out);merge_evaluation(&out,x);}else check_type_detail(e,STATIC_STRING(ARRAY_TYPE),instance,false);break;case OP_TYPED_OBJECT:if(RB_TYPE_P(instance,T_HASH)){x=check_object_detail(e,r,instance,out);merge_evaluation(&out,x);}else check_type_detail(e,STATIC_STRING(OBJECT_TYPE),instance,false);break;}}
  if(entered)rb_ary_pop(e->dynamic_scope);
  out.valid=e->error_count==before;return out;}
static VALUE evaluator_validate(VALUE self,VALUE instance){evaluator_t*e;TypedData_Get_Struct(self,evaluator_t,&evaluator_type,e);if(!supported_instance(instance))return rb_funcall(ruby_evaluator(e),id_validate,1,instance);RB_OBJ_WRITE(self,&e->errors,rb_ary_new());RB_OBJ_WRITE(self,&e->instance_path,rb_ary_new());RB_OBJ_WRITE(self,&e->schema_path,rb_ary_new());rb_ary_clear(e->dynamic_scope);rb_hash_clear(e->active);e->error_count=0;evaluate_detail(e,e->root,instance);VALUE result=rb_class_new_instance(1,&e->errors,cResult);RB_OBJ_WRITE(self,&e->errors,Qnil);return result;}

static void initialize_static_strings(void) {
#define INITIALIZE_STATIC_STRING(name, literal) do { \
  static_strings[STATIC_STRING_##name] = rb_obj_freeze(rb_str_new_static(literal, (long)(sizeof(literal) - 1))); \
  rb_gc_register_address(&static_strings[STATIC_STRING_##name]); \
} while (0);
  STATIC_STRING_LIST(INITIALIZE_STATIC_STRING)
#undef INITIALIZE_STATIC_STRING
}

void Init_schemurai_native(void) {
  rb_ext_ractor_safe(true);
  initialize_static_strings();

  id_schema=rb_intern_const("schema"); id_dialect=rb_intern_const("dialect"); id_keyword_mask=rb_intern_const("keyword_mask"); id_format=rb_intern_const("format"); id_child=rb_intern_const("child"); id_resource=rb_intern_const("resource");
  id_nodes=rb_intern_const("nodes"); id_resolve=rb_intern_const("resolve"); id_dynamic_anchor=rb_intern_const("dynamic_anchor"); id_root=rb_intern_const("root"); id_ref_siblings_p=rb_intern_const("ref_siblings?"); id_format_assertion_p=rb_intern_const("format_assertion?"); id_key_p=rb_intern_const("key?"); id_call=rb_intern_const("call"); id_finite_p=rb_intern_const("finite?"); id_to_i=rb_intern_const("to_i"); id_to_s=rb_intern_const("to_s"); id_remainder=rb_intern_const("remainder"); id_zero_p=rb_intern_const("zero?"); id_positive_p=rb_intern_const("positive?"); id_name=rb_intern_const("name"); id_regexp=rb_intern_const("regexp"); id_valid_content_p=rb_intern_const("valid_content?"); id_valid_p=rb_intern_const("valid?");
  id_keys=rb_intern_const("keys"); id_include_p=rb_intern_const("include?"); id_compare_by_identity=rb_intern_const("compare_by_identity"); id_compare=rb_intern_const("<=>"); id_length=rb_intern_const("length"); id_match_p=rb_intern_const("match?"); id_gsub=rb_intern_const("gsub"); id_message=rb_intern_const("message"); id_validate=rb_intern_const("validate"); id_complex=rb_intern_const("Complex"); id_rational=rb_intern_const("Rational");
  id_error_any_of=rb_intern_const("any_of"); id_error_const=rb_intern_const("const"); id_error_contains=rb_intern_const("contains"); id_error_content_encoding=rb_intern_const("content_encoding"); id_error_content_media_type=rb_intern_const("content_media_type"); id_error_dependent_required=rb_intern_const("dependent_required"); id_error_enum=rb_intern_const("enum"); id_error_false_schema=rb_intern_const("false_schema"); id_error_format=rb_intern_const("format"); id_error_invalid_pattern=rb_intern_const("invalid_pattern"); id_error_multiple_of=rb_intern_const("multiple_of"); id_error_not=rb_intern_const("not"); id_error_numeric_limit=rb_intern_const("numeric_limit"); id_error_one_of=rb_intern_const("one_of"); id_error_pattern=rb_intern_const("pattern"); id_error_required=rb_intern_const("required"); id_error_size=rb_intern_const("size"); id_error_type=rb_intern_const("type"); id_error_unique_items=rb_intern_const("unique_items");
  sym_content=ID2SYM(rb_intern_const("content")); sym_format=ID2SYM(id_format); sym_vm=ID2SYM(rb_intern_const("vm"));
  sym_keyword=ID2SYM(rb_intern_const("keyword")); sym_instance_path=ID2SYM(rb_intern_const("instance_path")); sym_schema_path=ID2SYM(rb_intern_const("schema_path")); sym_message=ID2SYM(id_message);

  mSchemurai=rb_const_get(rb_cObject,rb_intern_const("Schemurai")); mInternal=rb_const_get(mSchemurai,rb_intern_const("Internal"));
  mVM=rb_define_module_under(mSchemurai,"VM"); mErrorMessage=rb_const_get(mInternal,rb_intern_const("ErrorMessage"));
  mNativeSupport=rb_const_get(mVM,rb_intern_const("NativeSupport"));
  cResult=rb_const_get(mSchemurai,rb_intern_const("Result")); cValidationError=rb_const_get(mSchemurai,rb_intern_const("ValidationError"));
  cRubyEvaluator=rb_const_get(mInternal,rb_intern_const("Evaluator"));
  eResolutionError=rb_const_get(mSchemurai,rb_intern_const("ResolutionError"));
  rb_gc_register_address(&mSchemurai);rb_gc_register_address(&mVM);rb_gc_register_address(&mInternal);
  rb_gc_register_address(&mErrorMessage);rb_gc_register_address(&mNativeSupport);rb_gc_register_address(&cResult);
  rb_gc_register_address(&cValidationError);rb_gc_register_address(&cRubyEvaluator);rb_gc_register_address(&eResolutionError);
  /* Programs and opcode operands are implementation-only native values.  Their
   * anonymous wrapper classes let Ruby's GC own the native allocations without
   * publishing a Ruby object model for the VM's instruction representation. */
  cRule=rb_class_new(rb_cObject);rb_undef_alloc_func(cRule);
  cProgram=rb_class_new(rb_cObject);rb_define_alloc_func(cProgram,program_alloc);
  rb_gc_register_address(&cRule);rb_gc_register_address(&cProgram);
  cCompiler=rb_define_class_under(mVM,"Compiler",rb_cObject);rb_define_alloc_func(cCompiler,compiler_alloc);rb_define_method(cCompiler,"initialize",compiler_initialize,1);rb_define_method(cCompiler,"compile_all",compiler_compile_all,0);rb_define_method(cCompiler,"evaluator",compiler_evaluator,-1);
  cEvaluator=rb_define_class_under(mVM,"Evaluator",rb_cObject);rb_undef_alloc_func(cEvaluator);rb_define_method(cEvaluator,"backend",evaluator_backend,0);rb_define_method(cEvaluator,"valid?",evaluator_valid,1);rb_define_method(cEvaluator,"validate",evaluator_validate,1);
  rb_gc_register_address(&cCompiler);rb_gc_register_address(&cEvaluator);
}
