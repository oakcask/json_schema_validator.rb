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
    VALUE slots[16];
    struct { VALUE value, fragment; } reference;
    struct { VALUE names; } types;
    struct { VALUE condition, then_branch, else_branch; } conditional;
    struct { VALUE maximum, minimum, exclusive_maximum, exclusive_minimum, multiple_of; } number;
    struct { VALUE max_length, min_length, pattern, format, format_assertion, decode_base64, parse_json; } string;
    struct {
      VALUE max_items, min_items, unique, prefix_items, items, items_list;
      VALUE additional, contains, min_contains, max_contains, count_contains, unevaluated;
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
static ID id_schema, id_dialect, id_keyword_mask, id_format, id_child, id_resource;
static ID id_nodes, id_resolve, id_dynamic_anchor, id_root, id_ref_siblings_p;
static ID id_format_assertion_p, id_keywords, id_key_p, id_call, id_finite_p;
static ID id_to_i, id_to_s, id_remainder, id_zero_p, id_positive_p, id_name;
static ID id_regexp, id_valid_content_p, id_new, id_compile, id_valid_p;
static ID id_evaluated_properties, id_evaluated_items;

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

static void rule_mark(void *ptr) { rule_t *r = ptr; for (int i = 0; i < 16; i++) rb_gc_mark_movable(r->as.slots[i]); }
static void rule_compact(void *ptr) { rule_t *r = ptr; for (int i = 0; i < 16; i++) r->as.slots[i] = rb_gc_location(r->as.slots[i]); }
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
  for (int i = 0; i < 16; i++) r->as.slots[i] = Qnil;
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

static VALUE hget(VALUE hash, const char *key) { return rb_hash_aref(hash, rb_str_new_cstr(key)); }
static bool hkey(VALUE hash, const char *key) { return RTEST(rb_funcall(hash, id_key_p, 1, rb_str_new_cstr(key))); }
static VALUE node_child(VALUE node, const char *keyword, VALUE segment, bool has_segment) {
  VALUE key = rb_str_new_cstr(keyword);
  return has_segment ? rb_funcall(node, id_child, 2, key, segment) : rb_funcall(node, id_child, 1, key);
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
    VALUE keys = rb_funcall(value, rb_intern("keys"), 0), copy = rb_hash_new();
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

static VALUE compile_map(VALUE self, VALUE node, VALUE parent, VALUE schema, const char *keyword) {
  VALUE source = hget(schema, keyword), result = rb_hash_new();
  if (NIL_P(source)) return rb_obj_freeze(result);
  VALUE keys = rb_funcall(source, rb_intern("keys"), 0);
  for (long i = 0; i < RARRAY_LEN(keys); i++) {
    VALUE key = rb_ary_entry(keys, i);
    rb_hash_aset(result, snapshot(key), compile_child(self, node_child(node, keyword, key, true), parent));
  }
  return rb_obj_freeze(result);
}

static VALUE compile_number(VALUE schema) {
  VALUE obj = rule_new(RULE_NUMBER); rule_t *r; TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  const char *keys[] = {"maximum", "minimum", "exclusiveMaximum", "exclusiveMinimum", "multipleOf"};
  for (int i = 0; i < 5; i++) if (hkey(schema, keys[i])) { r->mask |= 1u << i; r->as.slots[i] = hget(schema, keys[i]); RB_OBJ_WRITTEN(obj, Qundef, r->as.slots[i]); }
  return rb_obj_freeze(obj);
}

static VALUE compile_string(VALUE node, VALUE schema) {
  VALUE obj = rule_new(RULE_STRING); rule_t *r; TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  r->as.string.max_length = hget(schema, "maxLength");
  r->as.string.min_length = hget(schema, "minLength");
  r->as.string.pattern = snapshot(hget(schema, "pattern"));
  r->as.string.format = rb_funcall(node, id_format, 0);
  VALUE dialect = rb_funcall(node, id_dialect, 0);
  r->as.string.format_assertion = rb_funcall(dialect, id_format_assertion_p, 0);
  VALUE encoding = hget(schema, "contentEncoding");
  VALUE media_type = hget(schema, "contentMediaType");
  r->as.string.decode_base64 = RB_TYPE_P(encoding, T_STRING) && rb_str_equal(encoding, rb_str_new_cstr("base64")) ? Qtrue : Qfalse;
  r->as.string.parse_json = RB_TYPE_P(media_type, T_STRING) && rb_str_equal(media_type, rb_str_new_cstr("application/json")) ? Qtrue : Qfalse;
  for (int i = 0; i < 7; i++) RB_OBJ_WRITTEN(obj, Qundef, r->as.slots[i]);
  return rb_obj_freeze(obj);
}

static VALUE compile_program_list(VALUE self, VALUE node, VALUE parent, VALUE source, const char *keyword) {
  long n = RARRAY_LEN(source); VALUE list = rb_ary_new_capa(n);
  for (long i = 0; i < n; i++) rb_ary_push(list, compile_child(self, node_child(node, keyword, LONG2NUM(i), true), parent));
  return rb_obj_freeze(list);
}

static VALUE compile_array(VALUE self, VALUE node, VALUE parent, VALUE schema) {
  VALUE obj = rule_new(RULE_ARRAY); rule_t *r; TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  r->as.array.max_items = hget(schema, "maxItems");
  r->as.array.min_items = hget(schema, "minItems");
  r->as.array.unique = hget(schema, "uniqueItems");
  VALUE prefix = hget(schema, "prefixItems");
  if (RB_TYPE_P(prefix, T_ARRAY)) r->as.array.prefix_items = compile_program_list(self, node, parent, prefix, "prefixItems");
  VALUE items = hget(schema, "items");
  if (RB_TYPE_P(items, T_ARRAY)) { r->as.array.items = compile_program_list(self, node, parent, items, "items"); r->as.array.items_list = Qtrue; }
  else if (!NIL_P(items)) r->as.array.items = compile_child(self, node_child(node, "items", Qnil, false), parent);
  if (hkey(schema, "additionalItems")) r->as.array.additional = compile_child(self, node_child(node, "additionalItems", Qnil, false), parent);
  if (hkey(schema, "contains")) r->as.array.contains = compile_child(self, node_child(node, "contains", Qnil, false), parent);
  r->as.array.min_contains = hkey(schema, "minContains") ? hget(schema, "minContains") : INT2NUM(1);
  r->as.array.max_contains = hkey(schema, "maxContains") ? hget(schema, "maxContains") : DBL2NUM(HUGE_VAL);
  VALUE keywords = rb_funcall(rb_funcall(node, id_dialect, 0), id_keywords, 0);
  r->as.array.count_contains = rb_hash_lookup2(keywords, rb_str_new_cstr("minContains"), Qundef) == Qundef ? Qfalse : Qtrue;
  if (hkey(schema, "unevaluatedItems")) { r->as.array.unevaluated = compile_child(self, node_child(node, "unevaluatedItems", Qnil, false), parent); program_t *p; TypedData_Get_Struct(parent, program_t, &program_type, p); p->flags |= FLAG_EVALUATION; }
  for (int i = 0; i < 12; i++) RB_OBJ_WRITTEN(obj, Qundef, r->as.slots[i]);
  return rb_obj_freeze(obj);
}

static VALUE compile_dependencies(VALUE self, VALUE node, VALUE parent, VALUE schema) {
  VALUE source = hget(schema, "dependencies"); if (NIL_P(source) || RHASH_EMPTY_P(source)) return Qnil;
  VALUE out = rb_hash_new(), keys = rb_funcall(source, rb_intern("keys"), 0);
  for (long i = 0; i < RARRAY_LEN(keys); i++) {
    VALUE key = rb_ary_entry(keys, i), value = rb_hash_aref(source, key);
    VALUE compiled = RB_TYPE_P(value, T_ARRAY) ? snapshot(value) : compile_child(self, node_child(node, "dependencies", key, true), parent);
    rb_hash_aset(out, snapshot(key), compiled);
  }
  return rb_obj_freeze(out);
}

static VALUE compile_object(VALUE self, VALUE node, VALUE parent, VALUE schema) {
  VALUE obj = rule_new(RULE_OBJECT); rule_t *r; TypedData_Get_Struct(obj, rule_t, &rule_type, r);
  r->as.object.max_properties = hget(schema, "maxProperties");
  r->as.object.min_properties = hget(schema, "minProperties");
  r->as.object.required = snapshot(hget(schema, "required"));
  r->as.object.properties = compile_map(self, node, parent, schema, "properties");
  VALUE map = compile_map(self, node, parent, schema, "patternProperties"); r->as.object.patterns = RHASH_EMPTY_P(map) ? Qnil : map;
  if (hkey(schema, "additionalProperties")) r->as.object.additional = compile_child(self, node_child(node, "additionalProperties", Qnil, false), parent);
  if (hkey(schema, "propertyNames")) r->as.object.property_names = compile_child(self, node_child(node, "propertyNames", Qnil, false), parent);
  r->as.object.dependencies = compile_dependencies(self, node, parent, schema);
  VALUE dep_req = hget(schema, "dependentRequired"); r->as.object.dependent_required = NIL_P(dep_req) || RHASH_EMPTY_P(dep_req) ? Qnil : snapshot(dep_req);
  map = compile_map(self, node, parent, schema, "dependentSchemas"); r->as.object.dependent_schemas = RHASH_EMPTY_P(map) ? Qnil : map;
  if (hkey(schema, "unevaluatedProperties")) { r->as.object.unevaluated = compile_child(self, node_child(node, "unevaluatedProperties", Qnil, false), parent); program_t *p; TypedData_Get_Struct(parent, program_t, &program_type, p); p->flags |= FLAG_EVALUATION; }
  for (int i = 0; i < 11; i++) RB_OBJ_WRITTEN(obj, Qundef, r->as.slots[i]);
  return rb_obj_freeze(obj);
}

static VALUE compiler_initialize(VALUE self, VALUE graph) {
  compiler_t *c; TypedData_Get_Struct(self, compiler_t, &compiler_type, c);
  RB_OBJ_WRITE(self, &c->graph, graph); RB_OBJ_WRITE(self, &c->programs, rb_hash_new());
  rb_funcall(c->programs, rb_intern("compare_by_identity"), 0); return self;
}

static void compile_combiners(VALUE self, VALUE node, VALUE program, VALUE schema) {
  const char *keys[] = {"allOf", "anyOf", "oneOf"}; const uint8_t ops[] = {OP_ALL_OF, OP_ANY_OF, OP_ONE_OF};
  for (int i = 0; i < 3; i++) if (hkey(schema, keys[i])) emit(program, ops[i], compile_program_list(self, node, program, hget(schema, keys[i]), keys[i]));
  if (hkey(schema, "not")) emit(program, OP_NOT, compile_child(self, node_child(node, "not", Qnil, false), program));
  if (hkey(schema, "if")) {
    VALUE obj = rule_new(RULE_CONDITIONAL); rule_t *r; TypedData_Get_Struct(obj, rule_t, &rule_type, r);
    r->as.conditional.condition = compile_child(self, node_child(node, "if", Qnil, false), program);
    if (hkey(schema, "then")) r->as.conditional.then_branch = compile_child(self, node_child(node, "then", Qnil, false), program);
    if (hkey(schema, "else")) r->as.conditional.else_branch = compile_child(self, node_child(node, "else", Qnil, false), program);
    for (int i = 0; i < 3; i++) RB_OBJ_WRITTEN(obj, Qundef, r->as.slots[i]);
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
    p->recursive_anchor = hget(schema, "$recursiveAnchor") == Qtrue;
    VALUE anchor = hget(schema, "$dynamicAnchor"); if (RB_TYPE_P(anchor, T_STRING)) RB_OBJ_WRITE(program, &p->dynamic_anchor, rb_str_new_frozen(anchor));
  }
  if (schema == Qtrue || schema == Qfalse) emit(program, OP_BOOLEAN, schema);
  else if (RB_TYPE_P(schema, T_HASH)) {
    if (hkey(schema, "$ref")) {
      p->flags |= FLAG_DYNAMIC_SCOPE; emit(program, OP_REF, compile_reference(hget(schema, "$ref")));
      if (!RTEST(rb_funcall(rb_funcall(node, id_dialect, 0), id_ref_siblings_p, 0))) goto finish;
    }
    if (hkey(schema, "$recursiveRef")) { p->flags |= FLAG_DYNAMIC_SCOPE; emit(program, OP_RECURSIVE_REF, compile_reference(hget(schema, "$recursiveRef"))); }
    if (hkey(schema, "$dynamicRef")) { p->flags |= FLAG_DYNAMIC_SCOPE; emit(program, OP_DYNAMIC_REF, compile_reference(hget(schema, "$dynamicRef"))); }
    unsigned long mask = NUM2ULONG(rb_funcall(node, id_keyword_mask, 0));
    if ((mask & 1) && hkey(schema, "type")) {
      VALUE types = hget(schema, "type");
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
    if (mask & 2) { if (hkey(schema,"enum")) emit(program,OP_ENUM,snapshot(hget(schema,"enum"))); if (hkey(schema,"const")) emit(program,OP_CONST,snapshot(hget(schema,"const"))); }
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
static VALUE program_instruction_count(VALUE self) { program_t *p; TypedData_Get_Struct(self,program_t,&program_type,p); return SIZET2NUM(p->length); }

typedef struct { bool valid; VALUE properties, items; } evaluation_t;

/* Evaluator core: validity and annotations stay in a small native value type.
 * Ruby arrays are allocated lazily only when an applicator records locations. */

static evaluation_t evaluation(bool valid) { evaluation_t r = {valid, Qnil, Qnil}; return r; }
static void add_unique(VALUE *list, VALUE value) {
  if (NIL_P(*list)) *list = rb_ary_new();
  if (!RTEST(rb_funcall(*list, rb_intern("include?"), 1, value))) rb_ary_push(*list, value);
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
static bool has_location(VALUE list, VALUE item) { return !NIL_P(list) && RTEST(rb_funcall(list,rb_intern("include?"),1,item)); }

static bool number_p(VALUE value) {
  VALUE complex = rb_const_get(rb_cObject,rb_intern("Complex"));
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
static int compare_values(VALUE left, VALUE right) { return rb_cmpint(rb_funcall(left,rb_intern("<=>"),1,right),left,right); }
static VALUE decimal(VALUE value) {
  if (RB_INTEGER_TYPE_P(value) || RB_TYPE_P(value,T_RATIONAL)) return value;
  return rb_funcall(rb_mKernel,rb_intern("Rational"),1,rb_funcall(value,id_to_s,0));
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
    VALUE keys=rb_funcall(left,rb_intern("keys"),0);
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
  long length=NUM2LONG(rb_funcall(value,rb_intern("length"),0));
  if(!NIL_P(r->as.string.max_length)&&length>NUM2LONG(r->as.string.max_length))return false;
  if(!NIL_P(r->as.string.min_length)&&length<NUM2LONG(r->as.string.min_length))return false;
  if(!NIL_P(r->as.string.pattern)){struct protected_call c={regexp_for(e,r->as.string.pattern),rb_intern("match?"),1,{value}};if(!protected_truth(&c))return false;}
  if(!NIL_P(r->as.string.format)&&(e->format||RTEST(r->as.string.format_assertion))){struct protected_call c={r->as.string.format,id_call,1,{value}};if(!protected_truth(&c))return false;}
  if(e->content&&(RTEST(r->as.string.decode_base64)||RTEST(r->as.string.parse_json))){struct protected_call c={mNativeSupport,id_valid_content_p,3,{value,r->as.string.decode_base64,r->as.string.parse_json}};if(!protected_truth(&c))return false;}
  return true;
}

static evaluation_t evaluate_program(evaluator_t *e, VALUE program, VALUE instance);

static bool active_enter(evaluator_t *e, VALUE source, VALUE instance) {
  VALUE instances=rb_hash_lookup2(e->active,source,Qundef);
  if(instances==Qundef){instances=rb_hash_new();rb_funcall(instances,rb_intern("compare_by_identity"),0);rb_hash_aset(e->active,source,instances);}
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
static evaluation_t evaluate_reference(evaluator_t*e,VALUE source,VALUE target,VALUE instance){if(!active_enter(e,source,instance))return evaluation(true);evaluation_t r=evaluate_program(e,target,instance);active_leave(e,source,instance);return r;}

static evaluation_t valid_array(evaluator_t*e,rule_t*r,VALUE value,evaluation_t prior){
  evaluation_t out=evaluation(true);long len=RARRAY_LEN(value);
  if(!NIL_P(r->as.slots[0])&&len>NUM2LONG(r->as.slots[0]))return evaluation(false);
  if(!NIL_P(r->as.slots[1])&&len<NUM2LONG(r->as.slots[1]))return evaluation(false);
  if(RTEST(r->as.slots[2]))for(long i=1;i<len;i++)for(long j=0;j<i;j++)if(json_equal(rb_ary_entry(value,j),rb_ary_entry(value,i)))return evaluation(false);
  if(!NIL_P(r->as.slots[3]))for(long i=0;i<RARRAY_LEN(r->as.slots[3])&&i<len;i++){evaluation_t x=evaluate_program(e,rb_ary_entry(r->as.slots[3],i),rb_ary_entry(value,i));if(!x.valid)return evaluation(false);add_unique(&out.items,LONG2NUM(i));}
  if(RTEST(r->as.slots[5])){long n=RARRAY_LEN(r->as.slots[4]);for(long i=0;i<n&&i<len;i++){evaluation_t x=evaluate_program(e,rb_ary_entry(r->as.slots[4],i),rb_ary_entry(value,i));if(!x.valid)return evaluation(false);add_unique(&out.items,LONG2NUM(i));}if(!NIL_P(r->as.slots[6]))for(long i=n;i<len;i++){evaluation_t x=evaluate_program(e,r->as.slots[6],rb_ary_entry(value,i));if(!x.valid)return evaluation(false);add_unique(&out.items,LONG2NUM(i));}}
  else if(!NIL_P(r->as.slots[4])){long start=NIL_P(r->as.slots[3])?0:RARRAY_LEN(r->as.slots[3]);for(long i=start;i<len;i++){evaluation_t x=evaluate_program(e,r->as.slots[4],rb_ary_entry(value,i));if(!x.valid)return evaluation(false);add_unique(&out.items,LONG2NUM(i));}}
  if(!NIL_P(r->as.slots[7])){long matches=0;VALUE matched=rb_ary_new();for(long i=0;i<len;i++)if(evaluate_program(e,r->as.slots[7],rb_ary_entry(value,i)).valid){matches++;rb_ary_push(matched,LONG2NUM(i));}if(matches<NUM2LONG(r->as.slots[8])||compare_values(LONG2NUM(matches),r->as.slots[9])>0)return evaluation(false);merge_locations(&out.items,matched);}
  if(!NIL_P(r->as.slots[11]))for(long i=0;i<len;i++){VALUE index=LONG2NUM(i);if(has_location(prior.items,index)||has_location(out.items,index))continue;evaluation_t x=evaluate_program(e,r->as.slots[11],rb_ary_entry(value,i));if(!x.valid)return evaluation(false);add_unique(&out.items,index);}
  return out;
}

static bool required_present(VALUE object,VALUE names){if(NIL_P(names))return true;for(long i=0;i<RARRAY_LEN(names);i++)if(!RTEST(rb_funcall(object,id_key_p,1,rb_ary_entry(names,i))))return false;return true;}
static evaluation_t valid_object(evaluator_t*e,rule_t*r,VALUE value,evaluation_t prior){
  evaluation_t out=evaluation(true);long len=RHASH_SIZE(value);if(!NIL_P(r->as.slots[0])&&len>NUM2LONG(r->as.slots[0]))return evaluation(false);if(!NIL_P(r->as.slots[1])&&len<NUM2LONG(r->as.slots[1]))return evaluation(false);if(!required_present(value,r->as.slots[2]))return evaluation(false);
  VALUE keys=rb_funcall(value,rb_intern("keys"),0);
  for(long i=0;i<RARRAY_LEN(keys);i++){VALUE name=rb_ary_entry(keys,i),item=rb_hash_aref(value,name);bool matched=false;VALUE child=rb_hash_lookup2(r->as.slots[3],name,Qundef);if(child!=Qundef){matched=true;if(!evaluate_program(e,child,item).valid)return evaluation(false);add_unique(&out.properties,name);}if(!NIL_P(r->as.slots[4])){VALUE patterns=rb_funcall(r->as.slots[4],rb_intern("keys"),0);for(long j=0;j<RARRAY_LEN(patterns);j++){VALUE pattern=rb_ary_entry(patterns,j);struct protected_call c={regexp_for(e,pattern),rb_intern("match?"),1,{name}};if(protected_truth(&c)){matched=true;if(!evaluate_program(e,rb_hash_aref(r->as.slots[4],pattern),item).valid)return evaluation(false);add_unique(&out.properties,name);}}}if(!matched&&!NIL_P(r->as.slots[5])){if(!evaluate_program(e,r->as.slots[5],item).valid)return evaluation(false);add_unique(&out.properties,name);}}
  if(!NIL_P(r->as.slots[6]))for(long i=0;i<RARRAY_LEN(keys);i++)if(!evaluate_program(e,r->as.slots[6],rb_ary_entry(keys,i)).valid)return evaluation(false);
  VALUE dep_sets[]={r->as.slots[7],r->as.slots[8]};for(int d=0;d<2;d++)if(!NIL_P(dep_sets[d])){VALUE names=rb_funcall(dep_sets[d],rb_intern("keys"),0);for(long i=0;i<RARRAY_LEN(names);i++){VALUE name=rb_ary_entry(names,i);if(!RTEST(rb_funcall(value,id_key_p,1,name)))continue;VALUE dep=rb_hash_aref(dep_sets[d],name);if(RB_TYPE_P(dep,T_ARRAY)){if(!required_present(value,dep))return evaluation(false);}else{evaluation_t x=evaluate_program(e,dep,value);if(!x.valid)return evaluation(false);merge_locations(&out.properties,x.properties);}}}
  if(!NIL_P(r->as.slots[9])){VALUE names=rb_funcall(r->as.slots[9],rb_intern("keys"),0);for(long i=0;i<RARRAY_LEN(names);i++){VALUE name=rb_ary_entry(names,i);if(!RTEST(rb_funcall(value,id_key_p,1,name)))continue;evaluation_t x=evaluate_program(e,rb_hash_aref(r->as.slots[9],name),value);if(!x.valid)return evaluation(false);merge_locations(&out.properties,x.properties);}}
  if(!NIL_P(r->as.slots[10]))for(long i=0;i<RARRAY_LEN(keys);i++){VALUE name=rb_ary_entry(keys,i);if(has_location(prior.properties,name)||has_location(out.properties,name))continue;if(!evaluate_program(e,r->as.slots[10],rb_hash_aref(value,name)).valid)return evaluation(false);add_unique(&out.properties,name);}
  return out;
}

static evaluation_t evaluate_program(evaluator_t*e,VALUE program,VALUE instance){
  program_t*p;TypedData_Get_Struct(program,program_t,&program_type,p);evaluation_t out=evaluation(true);bool entered=false;
  if(p->flags&FLAG_DYNAMIC_SCOPE){VALUE resource=rb_funcall(p->node,id_resource,0);if(RARRAY_LEN(e->dynamic_scope)==0||rb_ary_entry(e->dynamic_scope,-1)!=resource){rb_ary_push(e->dynamic_scope,resource);entered=true;}}
  for(size_t i=0;i<p->length&&out.valid;i++){instruction_t*ins=&p->instructions[i];rule_t*r=NULL;if(rb_typeddata_is_kind_of(ins->operand,&rule_type))TypedData_Get_Struct(ins->operand,rule_t,&rule_type,r);evaluation_t x=evaluation(true);
    switch(ins->opcode){
      case OP_BOOLEAN:out.valid=RTEST(ins->operand);break;
      case OP_REF:case OP_RECURSIVE_REF:case OP_DYNAMIC_REF:{int state=0;VALUE target=safe_target(e,program,ins->operand,ins->opcode,&state);if(state){if(!RTEST(rb_obj_is_kind_of(rb_errinfo(),eResolutionError)))rb_jump_tag(state);rb_set_errinfo(Qnil);out.valid=false;}else{ x=evaluate_reference(e,program,target,instance);merge_evaluation(&out,x);}break;}
      case OP_TYPE_NULL:out.valid=NIL_P(instance);break;case OP_TYPE_BOOLEAN:out.valid=instance==Qtrue||instance==Qfalse;break;case OP_TYPE_OBJECT:out.valid=RB_TYPE_P(instance,T_HASH);break;case OP_TYPE_ARRAY:out.valid=RB_TYPE_P(instance,T_ARRAY);break;case OP_TYPE_NUMBER:out.valid=number_p(instance);break;case OP_TYPE_INTEGER:out.valid=integer_p(instance);break;case OP_TYPE_STRING:out.valid=RB_TYPE_P(instance,T_STRING);break;
      case OP_TYPES:out.valid=(r->mask&instance_type(instance,(r->mask&TYPE_INTEGER)!=0))!=0;break;
      case OP_ENUM:out.valid=false;for(long j=0;j<RARRAY_LEN(ins->operand);j++)if(json_equal(rb_ary_entry(ins->operand,j),instance)){out.valid=true;break;}break;
      case OP_CONST:out.valid=json_equal(ins->operand,instance);break;
      case OP_ALL_OF:for(long j=0;j<RARRAY_LEN(ins->operand);j++){x=evaluate_program(e,rb_ary_entry(ins->operand,j),instance);merge_evaluation(&out,x);}break;
      case OP_ANY_OF:{bool matched=false;for(long j=0;j<RARRAY_LEN(ins->operand);j++){x=evaluate_program(e,rb_ary_entry(ins->operand,j),instance);if(x.valid){matched=true;merge_evaluation(&out,x);}}out.valid=matched;break;}
      case OP_ONE_OF:{long matches=0;evaluation_t found=evaluation(true);for(long j=0;j<RARRAY_LEN(ins->operand);j++){x=evaluate_program(e,rb_ary_entry(ins->operand,j),instance);if(x.valid){matches++;found=x;}}if(matches==1)merge_evaluation(&out,found);else out.valid=false;break;}
      case OP_NOT:out.valid=!evaluate_program(e,ins->operand,instance).valid;break;
      case OP_CONDITIONAL:x=evaluate_program(e,r->as.conditional.condition,instance);if(x.valid){merge_evaluation(&out,x);if(!NIL_P(r->as.conditional.then_branch))merge_evaluation(&out,evaluate_program(e,r->as.conditional.then_branch,instance));}else if(!NIL_P(r->as.conditional.else_branch))merge_evaluation(&out,evaluate_program(e,r->as.conditional.else_branch,instance));break;
      case OP_NUMBER:if(number_p(instance))out.valid=valid_number(r,instance);break;case OP_STRING:if(RB_TYPE_P(instance,T_STRING))out.valid=valid_string(e,r,instance);break;
      case OP_ARRAY:if(RB_TYPE_P(instance,T_ARRAY)){x=valid_array(e,r,instance,out);merge_evaluation(&out,x);}break;case OP_OBJECT:if(RB_TYPE_P(instance,T_HASH)){x=valid_object(e,r,instance,out);merge_evaluation(&out,x);}break;
      case OP_TYPED_NUMBER:out.valid=number_p(instance)&&valid_number(r,instance);break;case OP_TYPED_INTEGER:out.valid=integer_p(instance)&&valid_number(r,instance);break;case OP_TYPED_STRING:out.valid=RB_TYPE_P(instance,T_STRING)&&valid_string(e,r,instance);break;
      case OP_TYPED_ARRAY:if(RB_TYPE_P(instance,T_ARRAY)){x=valid_array(e,r,instance,out);merge_evaluation(&out,x);}else out.valid=false;break;case OP_TYPED_OBJECT:if(RB_TYPE_P(instance,T_HASH)){x=valid_object(e,r,instance,out);merge_evaluation(&out,x);}else out.valid=false;break;
    }
  }
  if(entered)rb_ary_pop(e->dynamic_scope);
  return out;
}

static VALUE evaluator_initialize(int argc,VALUE*argv,VALUE self){VALUE graph,compiler,root,options;rb_scan_args(argc,argv,"3:",&graph,&compiler,&root,&options);evaluator_t*e;TypedData_Get_Struct(self,evaluator_t,&evaluator_type,e);RB_OBJ_WRITE(self,&e->graph,graph);RB_OBJ_WRITE(self,&e->compiler,compiler);RB_OBJ_WRITE(self,&e->root,root);rb_ivar_set(self,rb_intern("@compiler"),compiler);rb_ivar_set(self,rb_intern("@root"),root);RB_OBJ_WRITE(self,&e->regexps,rb_hash_new());RB_OBJ_WRITE(self,&e->resolved,rb_hash_new());rb_funcall(e->resolved,rb_intern("compare_by_identity"),0);RB_OBJ_WRITE(self,&e->active,rb_hash_new());rb_funcall(e->active,rb_intern("compare_by_identity"),0);RB_OBJ_WRITE(self,&e->dynamic_scope,rb_ary_new());e->content=RTEST(rb_hash_aref(options,ID2SYM(rb_intern("content"))));e->format=RTEST(rb_hash_aref(options,ID2SYM(rb_intern("format"))));return self;}
static VALUE evaluator_backend(VALUE self){return ID2SYM(rb_intern("vm"));}
static bool supported_instance(VALUE value){
  if(NIL_P(value)||value==Qtrue||value==Qfalse||RB_INTEGER_TYPE_P(value))return true;
  if(CLASS_OF(value)==rb_cFloat)return RTEST(rb_funcall(value,id_finite_p,0));
  if(CLASS_OF(value)==rb_cString)return true;
  if(CLASS_OF(value)==rb_cArray){for(long i=0;i<RARRAY_LEN(value);i++)if(!supported_instance(rb_ary_entry(value,i)))return false;return true;}
  if(CLASS_OF(value)==rb_cHash){VALUE keys=rb_funcall(value,rb_intern("keys"),0);for(long i=0;i<RARRAY_LEN(keys);i++){VALUE key=rb_ary_entry(keys,i);if(CLASS_OF(key)!=rb_cString||!supported_instance(rb_hash_aref(value,key)))return false;}return true;}
  return false;
}
static VALUE ruby_evaluator(evaluator_t*e){program_t*p;TypedData_Get_Struct(e->root,program_t,&program_type,p);VALUE kwargs=rb_hash_new();rb_hash_aset(kwargs,ID2SYM(rb_intern("content")),e->content?Qtrue:Qfalse);rb_hash_aset(kwargs,ID2SYM(rb_intern("format")),e->format?Qtrue:Qfalse);VALUE argv[]={e->graph,p->node,kwargs};return rb_class_new_instance_kw(3,argv,cRubyEvaluator,RB_PASS_KEYWORDS);}
static VALUE evaluator_valid(VALUE self,VALUE instance){evaluator_t*e;TypedData_Get_Struct(self,evaluator_t,&evaluator_type,e);if(!supported_instance(instance))return rb_funcall(ruby_evaluator(e),id_valid_p,1,instance);rb_ary_clear(e->dynamic_scope);rb_hash_clear(e->active);return evaluate_program(e,e->root,instance).valid?Qtrue:Qfalse;}

static VALUE pointer(VALUE path,VALUE final,bool has_final){VALUE result=rb_str_new_cstr("");long n=RARRAY_LEN(path)+(has_final?1:0);for(long i=0;i<n;i++){VALUE segment=i<RARRAY_LEN(path)?rb_ary_entry(path,i):final;VALUE string=rb_funcall(segment,id_to_s,0);string=rb_funcall(string,rb_intern("gsub"),2,rb_str_new_cstr("~"),rb_str_new_cstr("~0"));string=rb_funcall(string,rb_intern("gsub"),2,rb_str_new_cstr("/"),rb_str_new_cstr("~1"));rb_str_cat_cstr(result,"/");rb_str_append(result,string);}return result;}

/* Detailed diagnostics use the same native programs, adding only public Ruby
 * ValidationError objects at the API boundary. */
static VALUE error_message(const char*method,int argc,VALUE*a){return rb_funcallv(mErrorMessage,rb_intern(method),argc,a);}
static void add_error(evaluator_t*e,const char*keyword,VALUE message,bool append_keyword){VALUE key=rb_str_new_cstr(keyword),kwargs=rb_hash_new();rb_hash_aset(kwargs,ID2SYM(rb_intern("keyword")),key);rb_hash_aset(kwargs,ID2SYM(rb_intern("instance_path")),pointer(e->instance_path,Qnil,false));rb_hash_aset(kwargs,ID2SYM(rb_intern("schema_path")),pointer(e->schema_path,key,append_keyword));rb_hash_aset(kwargs,ID2SYM(rb_intern("message")),message);VALUE argv[]={kwargs};rb_ary_push(e->errors,rb_class_new_instance_kw(1,argv,cValidationError,RB_PASS_KEYWORDS));e->error_count++;}
static void add_message0(evaluator_t*e,const char*keyword,const char*method){add_error(e,keyword,error_message(method,0,NULL),true);}
static evaluation_t evaluate_detail(evaluator_t*e,VALUE program,VALUE instance);
static evaluation_t detail_at(evaluator_t*e,VALUE program,VALUE instance,VALUE instance_segment,bool has_instance,const char*schema_segment,VALUE child_segment,bool has_child){if(has_instance)rb_ary_push(e->instance_path,instance_segment);rb_ary_push(e->schema_path,rb_str_new_cstr(schema_segment));if(has_child)rb_ary_push(e->schema_path,child_segment);evaluation_t out=evaluate_detail(e,program,instance);if(has_child)rb_ary_pop(e->schema_path);rb_ary_pop(e->schema_path);if(has_instance)rb_ary_pop(e->instance_path);return out;}
static evaluation_t detail_reference(evaluator_t*e,VALUE source,VALUE target,VALUE instance,const char*keyword){if(!active_enter(e,source,instance))return evaluation(true);evaluation_t out=detail_at(e,target,instance,Qnil,false,keyword,Qnil,false);active_leave(e,source,instance);return out;}

static void check_number_detail(evaluator_t*e,rule_t*r,VALUE value){VALUE actual=(r->mask&NUM_MULTIPLE_OF)?decimal(value):value;const char*keys[]={"maximum","minimum","exclusiveMaximum","exclusiveMinimum"};for(int i=0;i<4;i++)if(r->mask&(1u<<i)){int comparison=compare_values(actual,r->as.slots[i]);bool invalid=(i==0&&comparison>0)||(i==1&&comparison<0)||(i==2&&comparison>=0)||(i==3&&comparison<=0);if(invalid){VALUE a[]={rb_str_new_cstr(keys[i]),r->as.slots[i]};add_error(e,keys[i],error_message("numeric_limit",2,a),true);}}if(r->mask&NUM_MULTIPLE_OF){VALUE divisor=decimal(r->as.slots[4]);bool ok=RTEST(rb_funcall(divisor,id_positive_p,0))&&RTEST(rb_funcall(rb_funcall(decimal(value),id_remainder,1,divisor),id_zero_p,0));if(!ok){VALUE a[]={r->as.slots[4]};add_error(e,"multipleOf",error_message("multiple_of",1,a),true);}}}
static void check_type_detail(evaluator_t*e,VALUE expected,VALUE value,bool valid){if(valid)return;VALUE a[]={expected,value};add_error(e,"type",error_message("type",2,a),true);}
static void check_string_detail(evaluator_t*e,rule_t*r,VALUE value){long len=NUM2LONG(rb_funcall(value,rb_intern("length"),0));if(!NIL_P(r->as.slots[0])&&len>NUM2LONG(r->as.slots[0])){VALUE a[]={rb_str_new_cstr("maxLength"),r->as.slots[0],LONG2NUM(len)};add_error(e,"maxLength",error_message("size",3,a),true);}if(!NIL_P(r->as.slots[1])&&len<NUM2LONG(r->as.slots[1])){VALUE a[]={rb_str_new_cstr("minLength"),r->as.slots[1],LONG2NUM(len)};add_error(e,"minLength",error_message("size",3,a),true);}if(!NIL_P(r->as.slots[2])){int state=0;VALUE regexp=rb_protect(protected_func,(VALUE)&(struct protected_call){mNativeSupport,id_regexp,1,{r->as.slots[2]}},&state);if(state){rb_set_errinfo(Qnil);VALUE a[]={r->as.slots[2]};add_error(e,"pattern",error_message("invalid_pattern",1,a),true);}else if(!RTEST(rb_funcall(regexp,rb_intern("match?"),1,value))){VALUE a[]={r->as.slots[2]};add_error(e,"pattern",error_message("pattern",1,a),true);}}if(!NIL_P(r->as.slots[3])&&(e->format||RTEST(r->as.slots[4]))&&!RTEST(rb_funcall(r->as.slots[3],id_call,1,value))){VALUE a[]={rb_funcall(r->as.slots[3],id_name,0)};add_error(e,"format",error_message("format",1,a),true);}if(e->content&&(RTEST(r->as.slots[5])||RTEST(r->as.slots[6]))&&!RTEST(rb_funcall(mNativeSupport,id_valid_content_p,3,value,r->as.slots[5],r->as.slots[6]))){if(RTEST(r->as.slots[5]))add_message0(e,"contentEncoding","content_encoding");else add_message0(e,"contentMediaType","content_media_type");}}

static evaluation_t check_array_detail(evaluator_t*e,rule_t*r,VALUE value,evaluation_t prior){evaluation_t out=evaluation(true);long before=e->error_count,len=RARRAY_LEN(value);if(!NIL_P(r->as.slots[0])&&len>NUM2LONG(r->as.slots[0])){VALUE a[]={rb_str_new_cstr("maxItems"),r->as.slots[0],LONG2NUM(len)};add_error(e,"maxItems",error_message("size",3,a),true);}if(!NIL_P(r->as.slots[1])&&len<NUM2LONG(r->as.slots[1])){VALUE a[]={rb_str_new_cstr("minItems"),r->as.slots[1],LONG2NUM(len)};add_error(e,"minItems",error_message("size",3,a),true);}if(RTEST(r->as.slots[2])){bool duplicate=false;for(long i=1;i<len&&!duplicate;i++)for(long j=0;j<i;j++)if(json_equal(rb_ary_entry(value,j),rb_ary_entry(value,i))){duplicate=true;break;}if(duplicate)add_message0(e,"uniqueItems","unique_items");}
  if(!NIL_P(r->as.slots[3]))for(long i=0;i<RARRAY_LEN(r->as.slots[3])&&i<len;i++){detail_at(e,rb_ary_entry(r->as.slots[3],i),rb_ary_entry(value,i),LONG2NUM(i),true,"prefixItems",LONG2NUM(i),true);add_unique(&out.items,LONG2NUM(i));}
  if(RTEST(r->as.slots[5])){long n=RARRAY_LEN(r->as.slots[4]);for(long i=0;i<n&&i<len;i++){detail_at(e,rb_ary_entry(r->as.slots[4],i),rb_ary_entry(value,i),LONG2NUM(i),true,"items",LONG2NUM(i),true);add_unique(&out.items,LONG2NUM(i));}if(!NIL_P(r->as.slots[6]))for(long i=n;i<len;i++){detail_at(e,r->as.slots[6],rb_ary_entry(value,i),LONG2NUM(i),true,"additionalItems",Qnil,false);add_unique(&out.items,LONG2NUM(i));}}
  else if(!NIL_P(r->as.slots[4])){long start=NIL_P(r->as.slots[3])?0:RARRAY_LEN(r->as.slots[3]);for(long i=start;i<len;i++){detail_at(e,r->as.slots[4],rb_ary_entry(value,i),LONG2NUM(i),true,"items",Qnil,false);add_unique(&out.items,LONG2NUM(i));}}
  if(!NIL_P(r->as.slots[7])){VALUE matched=rb_ary_new();for(long i=0;i<len;i++)if(evaluate_program(e,r->as.slots[7],rb_ary_entry(value,i)).valid)rb_ary_push(matched,LONG2NUM(i));long count=RARRAY_LEN(matched);if(count<NUM2LONG(r->as.slots[8])||compare_values(LONG2NUM(count),r->as.slots[9])>0){VALUE a[]={LONG2NUM(count),r->as.slots[8],r->as.slots[9]};add_error(e,"contains",error_message("contains",3,a),true);}merge_locations(&out.items,matched);}
  if(!NIL_P(r->as.slots[11]))for(long i=0;i<len;i++){VALUE index=LONG2NUM(i);if(has_location(prior.items,index)||has_location(out.items,index))continue;detail_at(e,r->as.slots[11],rb_ary_entry(value,i),index,true,"unevaluatedItems",Qnil,false);add_unique(&out.items,index);}
  out.valid=e->error_count==before;return out;}

static evaluation_t check_object_detail(evaluator_t*e,rule_t*r,VALUE value,evaluation_t prior){evaluation_t out=evaluation(true);long before=e->error_count,len=RHASH_SIZE(value);if(!NIL_P(r->as.slots[0])&&len>NUM2LONG(r->as.slots[0])){VALUE a[]={rb_str_new_cstr("maxProperties"),r->as.slots[0],LONG2NUM(len)};add_error(e,"maxProperties",error_message("size",3,a),true);}if(!NIL_P(r->as.slots[1])&&len<NUM2LONG(r->as.slots[1])){VALUE a[]={rb_str_new_cstr("minProperties"),r->as.slots[1],LONG2NUM(len)};add_error(e,"minProperties",error_message("size",3,a),true);}if(!NIL_P(r->as.slots[2]))for(long i=0;i<RARRAY_LEN(r->as.slots[2]);i++){VALUE name=rb_ary_entry(r->as.slots[2],i);if(!RTEST(rb_funcall(value,id_key_p,1,name))){VALUE a[]={name};add_error(e,"required",error_message("required",1,a),true);}}
  VALUE keys=rb_funcall(value,rb_intern("keys"),0);for(long i=0;i<RARRAY_LEN(keys);i++){VALUE name=rb_ary_entry(keys,i),item=rb_hash_aref(value,name);bool matched=false;VALUE child=rb_hash_lookup2(r->as.slots[3],name,Qundef);if(child!=Qundef){matched=true;detail_at(e,child,item,name,true,"properties",name,true);add_unique(&out.properties,name);}if(!NIL_P(r->as.slots[4])){VALUE patterns=rb_funcall(r->as.slots[4],rb_intern("keys"),0);for(long j=0;j<RARRAY_LEN(patterns);j++){VALUE pattern=rb_ary_entry(patterns,j);if(RTEST(rb_funcall(regexp_for(e,pattern),rb_intern("match?"),1,name))){matched=true;detail_at(e,rb_hash_aref(r->as.slots[4],pattern),item,name,true,"patternProperties",pattern,true);add_unique(&out.properties,name);}}}if(!matched&&!NIL_P(r->as.slots[5])){detail_at(e,r->as.slots[5],item,name,true,"additionalProperties",Qnil,false);add_unique(&out.properties,name);}}
  if(!NIL_P(r->as.slots[6]))for(long i=0;i<RARRAY_LEN(keys);i++){VALUE name=rb_ary_entry(keys,i);detail_at(e,r->as.slots[6],name,name,true,"propertyNames",Qnil,false);}
  if(!NIL_P(r->as.slots[7])){VALUE names=rb_funcall(r->as.slots[7],rb_intern("keys"),0);for(long i=0;i<RARRAY_LEN(names);i++){VALUE name=rb_ary_entry(names,i);if(!RTEST(rb_funcall(value,id_key_p,1,name)))continue;VALUE dep=rb_hash_aref(r->as.slots[7],name);if(RB_TYPE_P(dep,T_ARRAY)){for(long j=0;j<RARRAY_LEN(dep);j++){VALUE req=rb_ary_entry(dep,j);if(!RTEST(rb_funcall(value,id_key_p,1,req))){VALUE a[]={name,req};add_error(e,"dependencies",error_message("dependent_required",2,a),true);}}}else{evaluation_t x=detail_at(e,dep,value,Qnil,false,"dependencies",name,true);if(x.valid)merge_locations(&out.properties,x.properties);}}}
  if(!NIL_P(r->as.slots[8])){VALUE names=rb_funcall(r->as.slots[8],rb_intern("keys"),0);for(long i=0;i<RARRAY_LEN(names);i++){VALUE name=rb_ary_entry(names,i);if(!RTEST(rb_funcall(value,id_key_p,1,name)))continue;VALUE reqs=rb_hash_aref(r->as.slots[8],name);for(long j=0;j<RARRAY_LEN(reqs);j++){VALUE req=rb_ary_entry(reqs,j);if(!RTEST(rb_funcall(value,id_key_p,1,req))){VALUE a[]={name,req};add_error(e,"dependentRequired",error_message("dependent_required",2,a),true);}}}}
  if(!NIL_P(r->as.slots[9])){VALUE names=rb_funcall(r->as.slots[9],rb_intern("keys"),0);for(long i=0;i<RARRAY_LEN(names);i++){VALUE name=rb_ary_entry(names,i);if(!RTEST(rb_funcall(value,id_key_p,1,name)))continue;evaluation_t x=detail_at(e,rb_hash_aref(r->as.slots[9],name),value,Qnil,false,"dependentSchemas",name,true);if(x.valid)merge_locations(&out.properties,x.properties);}}
  if(!NIL_P(r->as.slots[10]))for(long i=0;i<RARRAY_LEN(keys);i++){VALUE name=rb_ary_entry(keys,i);if(has_location(prior.properties,name)||has_location(out.properties,name))continue;detail_at(e,r->as.slots[10],rb_hash_aref(value,name),name,true,"unevaluatedProperties",Qnil,false);add_unique(&out.properties,name);}
  out.valid=e->error_count==before;return out;}

static evaluation_t check_combiner_detail(evaluator_t*e,uint8_t op,VALUE operand,VALUE value){evaluation_t out=evaluation(true);if(op==OP_ALL_OF){for(long i=0;i<RARRAY_LEN(operand);i++)merge_evaluation(&out,detail_at(e,rb_ary_entry(operand,i),value,Qnil,false,"allOf",LONG2NUM(i),true));}else if(op==OP_ANY_OF||op==OP_ONE_OF){long matches=0;evaluation_t matched=evaluation(true);for(long i=0;i<RARRAY_LEN(operand);i++){evaluation_t x=evaluate_program(e,rb_ary_entry(operand,i),value);if(x.valid){matches++;merge_evaluation(&matched,x);}}if(op==OP_ANY_OF&&matches==0)add_message0(e,"anyOf","any_of");else if(op==OP_ONE_OF&&matches!=1){VALUE a[]={LONG2NUM(matches)};add_error(e,"oneOf",error_message("one_of",1,a),true);}else merge_evaluation(&out,matched);}else if(op==OP_NOT){if(evaluate_program(e,operand,value).valid)add_message0(e,"not","not");}else{rule_t*r;TypedData_Get_Struct(operand,rule_t,&rule_type,r);evaluation_t condition=evaluate_program(e,r->as.slots[0],value);if(condition.valid){merge_evaluation(&out,condition);if(!NIL_P(r->as.slots[1]))merge_evaluation(&out,detail_at(e,r->as.slots[1],value,Qnil,false,"then",Qnil,false));}else if(!NIL_P(r->as.slots[2]))merge_evaluation(&out,detail_at(e,r->as.slots[2],value,Qnil,false,"else",Qnil,false));}return out;}

static evaluation_t evaluate_detail(evaluator_t*e,VALUE program,VALUE instance){program_t*p;TypedData_Get_Struct(program,program_t,&program_type,p);long before=e->error_count;evaluation_t out=evaluation(true);bool entered=false;if(p->flags&FLAG_DYNAMIC_SCOPE){VALUE resource=rb_funcall(p->node,id_resource,0);if(RARRAY_LEN(e->dynamic_scope)==0||rb_ary_entry(e->dynamic_scope,-1)!=resource){rb_ary_push(e->dynamic_scope,resource);entered=true;}}
  for(size_t i=0;i<p->length;i++){instruction_t*ins=&p->instructions[i];rule_t*r=NULL;if(rb_typeddata_is_kind_of(ins->operand,&rule_type))TypedData_Get_Struct(ins->operand,rule_t,&rule_type,r);evaluation_t x=evaluation(true);switch(ins->opcode){case OP_BOOLEAN:if(!RTEST(ins->operand))add_error(e,"falseSchema",error_message("false_schema",0,NULL),false);break;case OP_REF:case OP_RECURSIVE_REF:case OP_DYNAMIC_REF:{int state=0;VALUE target=safe_target(e,program,ins->operand,ins->opcode,&state);const char*keyword=ins->opcode==OP_REF?"$ref":ins->opcode==OP_RECURSIVE_REF?"$recursiveRef":"$dynamicRef";if(state){VALUE error=rb_errinfo();if(!RTEST(rb_obj_is_kind_of(error,eResolutionError)))rb_jump_tag(state);VALUE message=rb_funcall(error,rb_intern("message"),0);rb_set_errinfo(Qnil);add_error(e,keyword,message,false);}else{x=detail_reference(e,program,target,instance,keyword);merge_evaluation(&out,x);}break;}
    case OP_TYPE_NULL:check_type_detail(e,rb_str_new_cstr("null"),instance,NIL_P(instance));break;case OP_TYPE_BOOLEAN:check_type_detail(e,rb_str_new_cstr("boolean"),instance,instance==Qtrue||instance==Qfalse);break;case OP_TYPE_OBJECT:check_type_detail(e,rb_str_new_cstr("object"),instance,RB_TYPE_P(instance,T_HASH));break;case OP_TYPE_ARRAY:check_type_detail(e,rb_str_new_cstr("array"),instance,RB_TYPE_P(instance,T_ARRAY));break;case OP_TYPE_NUMBER:check_type_detail(e,rb_str_new_cstr("number"),instance,number_p(instance));break;case OP_TYPE_INTEGER:check_type_detail(e,rb_str_new_cstr("integer"),instance,integer_p(instance));break;case OP_TYPE_STRING:check_type_detail(e,rb_str_new_cstr("string"),instance,RB_TYPE_P(instance,T_STRING));break;case OP_TYPES:check_type_detail(e,r->as.slots[0],instance,(r->mask&instance_type(instance,(r->mask&TYPE_INTEGER)!=0))!=0);break;
    case OP_ENUM:{bool ok=false;for(long j=0;j<RARRAY_LEN(ins->operand);j++)if(json_equal(rb_ary_entry(ins->operand,j),instance)){ok=true;break;}if(!ok)add_message0(e,"enum","enum");break;}case OP_CONST:if(!json_equal(ins->operand,instance))add_message0(e,"const","const");break;
    case OP_ALL_OF:case OP_ANY_OF:case OP_ONE_OF:case OP_NOT:case OP_CONDITIONAL:x=check_combiner_detail(e,ins->opcode,ins->operand,instance);merge_evaluation(&out,x);break;
    case OP_NUMBER:if(number_p(instance))check_number_detail(e,r,instance);break;case OP_STRING:if(RB_TYPE_P(instance,T_STRING))check_string_detail(e,r,instance);break;case OP_ARRAY:if(RB_TYPE_P(instance,T_ARRAY)){x=check_array_detail(e,r,instance,out);merge_evaluation(&out,x);}break;case OP_OBJECT:if(RB_TYPE_P(instance,T_HASH)){x=check_object_detail(e,r,instance,out);merge_evaluation(&out,x);}break;
    case OP_TYPED_NUMBER:if(number_p(instance))check_number_detail(e,r,instance);else check_type_detail(e,rb_str_new_cstr("number"),instance,false);break;case OP_TYPED_INTEGER:if(number_p(instance)){check_type_detail(e,rb_str_new_cstr("integer"),instance,integer_p(instance));check_number_detail(e,r,instance);}else check_type_detail(e,rb_str_new_cstr("integer"),instance,false);break;case OP_TYPED_STRING:if(RB_TYPE_P(instance,T_STRING))check_string_detail(e,r,instance);else check_type_detail(e,rb_str_new_cstr("string"),instance,false);break;case OP_TYPED_ARRAY:if(RB_TYPE_P(instance,T_ARRAY)){x=check_array_detail(e,r,instance,out);merge_evaluation(&out,x);}else check_type_detail(e,rb_str_new_cstr("array"),instance,false);break;case OP_TYPED_OBJECT:if(RB_TYPE_P(instance,T_HASH)){x=check_object_detail(e,r,instance,out);merge_evaluation(&out,x);}else check_type_detail(e,rb_str_new_cstr("object"),instance,false);break;}}
  if(entered)rb_ary_pop(e->dynamic_scope);
  out.valid=e->error_count==before;return out;}
static VALUE evaluator_validate(VALUE self,VALUE instance){evaluator_t*e;TypedData_Get_Struct(self,evaluator_t,&evaluator_type,e);if(!supported_instance(instance))return rb_funcall(ruby_evaluator(e),rb_intern("validate"),1,instance);RB_OBJ_WRITE(self,&e->errors,rb_ary_new());RB_OBJ_WRITE(self,&e->instance_path,rb_ary_new());RB_OBJ_WRITE(self,&e->schema_path,rb_ary_new());rb_ary_clear(e->dynamic_scope);rb_hash_clear(e->active);e->error_count=0;evaluate_detail(e,e->root,instance);VALUE result=rb_class_new_instance(1,&e->errors,cResult);RB_OBJ_WRITE(self,&e->errors,Qnil);return result;}

void Init_schemurai_native(void) {
  rb_ext_ractor_safe(true);
  mSchemurai=rb_const_get(rb_cObject,rb_intern("Schemurai")); mInternal=rb_const_get(mSchemurai,rb_intern("Internal"));
  mVM=rb_define_module_under(mSchemurai,"VM"); mErrorMessage=rb_const_get(mInternal,rb_intern("ErrorMessage"));
  mNativeSupport=rb_const_get(mVM,rb_intern("NativeSupport"));
  cResult=rb_const_get(mSchemurai,rb_intern("Result")); cValidationError=rb_const_get(mSchemurai,rb_intern("ValidationError"));
  cRubyEvaluator=rb_const_get(mInternal,rb_intern("Evaluator"));
  eResolutionError=rb_const_get(mSchemurai,rb_intern("ResolutionError"));
  cRule=rb_define_class_under(mVM,"Rule",rb_cObject); rb_undef_alloc_func(cRule);
  rb_funcall(mVM,rb_intern("private_constant"),1,ID2SYM(rb_intern("Rule")));
  cProgram=rb_define_class_under(mVM,"Program",rb_cObject); rb_define_alloc_func(cProgram,program_alloc); rb_define_method(cProgram,"instruction_count",program_instruction_count,0);
  cCompiler=rb_define_class_under(mVM,"Compiler",rb_cObject); rb_define_alloc_func(cCompiler,compiler_alloc); rb_define_method(cCompiler,"initialize",compiler_initialize,1); rb_define_method(cCompiler,"compile",compiler_compile,1); rb_define_method(cCompiler,"compile_all",compiler_compile_all,0); rb_define_method(cCompiler,"resolve",compiler_resolve,2);
  cEvaluator=rb_define_class_under(mVM,"Evaluator",rb_cObject); rb_define_alloc_func(cEvaluator,evaluator_alloc); rb_define_method(cEvaluator,"initialize",evaluator_initialize,-1); rb_define_method(cEvaluator,"backend",evaluator_backend,0); rb_define_method(cEvaluator,"valid?",evaluator_valid,1); rb_define_method(cEvaluator,"validate",evaluator_validate,1);
  id_schema=rb_intern("schema"); id_dialect=rb_intern("dialect"); id_keyword_mask=rb_intern("keyword_mask"); id_format=rb_intern("format"); id_child=rb_intern("child"); id_resource=rb_intern("resource");
  id_nodes=rb_intern("nodes"); id_resolve=rb_intern("resolve"); id_dynamic_anchor=rb_intern("dynamic_anchor"); id_root=rb_intern("root"); id_ref_siblings_p=rb_intern("ref_siblings?"); id_format_assertion_p=rb_intern("format_assertion?"); id_keywords=rb_intern("keywords"); id_key_p=rb_intern("key?"); id_call=rb_intern("call"); id_finite_p=rb_intern("finite?"); id_to_i=rb_intern("to_i"); id_to_s=rb_intern("to_s"); id_remainder=rb_intern("remainder"); id_zero_p=rb_intern("zero?"); id_positive_p=rb_intern("positive?"); id_name=rb_intern("name"); id_regexp=rb_intern("regexp"); id_valid_content_p=rb_intern("valid_content?"); id_new=rb_intern("new"); id_compile=rb_intern("compile"); id_valid_p=rb_intern("valid?"); id_evaluated_properties=rb_intern("evaluated_properties"); id_evaluated_items=rb_intern("evaluated_items");
}
