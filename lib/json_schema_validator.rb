# frozen_string_literal: true

require "json"
require "uri"
require "base64"

module JsonSchemaValidator
  DRAFT7_META_SCHEMA_URI = "http://json-schema.org/draft-07/schema"
  DRAFT7_META_SCHEMA = JSON.parse(
    File.read(File.join(__dir__, "json_schema_validator", "draft7_schema.json"))
  )

  TYPE_KEYWORDS = 1
  ENUM_KEYWORDS = 2
  COMBINER_KEYWORDS = 4
  NUMBER_KEYWORDS = 8
  STRING_KEYWORDS = 16
  ARRAY_KEYWORDS = 32
  OBJECT_KEYWORDS = 64
  KEYWORD_MASKS = {
    "type" => TYPE_KEYWORDS,
    "enum" => ENUM_KEYWORDS,
    "const" => ENUM_KEYWORDS,
    "allOf" => COMBINER_KEYWORDS,
    "anyOf" => COMBINER_KEYWORDS,
    "oneOf" => COMBINER_KEYWORDS,
    "not" => COMBINER_KEYWORDS,
    "if" => COMBINER_KEYWORDS,
    "maximum" => NUMBER_KEYWORDS,
    "minimum" => NUMBER_KEYWORDS,
    "exclusiveMaximum" => NUMBER_KEYWORDS,
    "exclusiveMinimum" => NUMBER_KEYWORDS,
    "multipleOf" => NUMBER_KEYWORDS,
    "maxLength" => STRING_KEYWORDS,
    "minLength" => STRING_KEYWORDS,
    "pattern" => STRING_KEYWORDS,
    "contentEncoding" => STRING_KEYWORDS,
    "contentMediaType" => STRING_KEYWORDS,
    "maxItems" => ARRAY_KEYWORDS,
    "minItems" => ARRAY_KEYWORDS,
    "uniqueItems" => ARRAY_KEYWORDS,
    "items" => ARRAY_KEYWORDS,
    "additionalItems" => ARRAY_KEYWORDS,
    "contains" => ARRAY_KEYWORDS,
    "maxProperties" => OBJECT_KEYWORDS,
    "minProperties" => OBJECT_KEYWORDS,
    "required" => OBJECT_KEYWORDS,
    "properties" => OBJECT_KEYWORDS,
    "patternProperties" => OBJECT_KEYWORDS,
    "additionalProperties" => OBJECT_KEYWORDS,
    "propertyNames" => OBJECT_KEYWORDS,
    "dependencies" => OBJECT_KEYWORDS
  }.freeze
  SINGLE_SCHEMA_KEYWORDS = %w[
    additionalItems additionalProperties contains propertyNames not if then else
  ].freeze
  ARRAY_SCHEMA_KEYWORDS = %w[allOf anyOf oneOf].freeze
  HASH_SCHEMA_KEYWORDS = %w[definitions properties patternProperties].freeze

  class ResolutionError < StandardError; end

  Error = Data.define(:keyword, :instance_path, :schema_path, :message) do
    def to_h
      {keyword: keyword, instance_path: instance_path, schema_path: schema_path, message: message}
    end
  end

  class Result
    attr_reader :errors

    def initialize(errors)
      @errors = errors.freeze
    end

    def valid?
      errors.empty?
    end

    alias_method :success?, :valid?
  end

  class Validator
    def initialize(schema, schemas: {}, base_uri: nil, content: false)
      @root = schema
      @validate_content = content
      @registry = {}
      @external_schemas = schemas
      @indexed_external_documents = nil
      @indexed_external_schemas = nil
      @bases = {}
      @ref_bases = {}
      @keyword_masks = {}
      @resolved_refs = nil
      @regexps = nil
      @active = nil
      @meta_schema_indexed = false
      @root_base = absolute_id(base_uri.to_s, schema.is_a?(Hash) ? schema["$id"] : nil)
      @root_base = base_uri.to_s if @root_base.empty? && base_uri

      @registry[DRAFT7_META_SCHEMA_URI] = DRAFT7_META_SCHEMA
      index(schema, @root_base)
      @registry[strip_fragment(@root_base)] ||= schema unless @root_base.empty?
    end

    def validate(instance)
      @errors = []
      @error_count = 0
      evaluate(@root, instance, @root_base, "", "")
      Result.new(@errors)
    end

    def valid?(instance)
      evaluate_valid(@root, instance, @root_base)
    end

    private def evaluate_valid(schema, instance, base)
      return schema if schema == true || schema == false
      return true unless schema.is_a?(Hash)

      base = @bases.fetch(schema.object_id, base)
      if schema.key?("$ref")
        instances = active_instances(schema)
        instance_id = instance.object_id
        return true if instances[instance_id]

        instances[instance_id] = true
        return begin
          target, target_base = resolve(schema["$ref"], @ref_bases.fetch(schema.object_id, base))
          evaluate_valid(target, instance, target_base)
        rescue ResolutionError
          false
        ensure
          instances.delete(instance_id)
        end
      end

      keywords = @keyword_masks.fetch(schema.object_id)
      return false if (keywords & TYPE_KEYWORDS) != 0 && !valid_type?(schema, instance)
      return false if (keywords & ENUM_KEYWORDS) != 0 && !valid_enum?(schema, instance)
      return false if (keywords & COMBINER_KEYWORDS) != 0 && !valid_combiners?(schema, instance, base)

      case instance
      when Hash
        (keywords & OBJECT_KEYWORDS) == 0 || valid_object?(schema, instance, base)
      when Array
        (keywords & ARRAY_KEYWORDS) == 0 || valid_array?(schema, instance, base)
      when String
        (keywords & STRING_KEYWORDS) == 0 || valid_string?(schema, instance)
      when Numeric
        instance.is_a?(Complex) || (keywords & NUMBER_KEYWORDS) == 0 || valid_number?(schema, instance)
      else
        true
      end
    end

    private def valid_type?(schema, value)
      types = schema["type"]
      return types.any? { |type| type?(value, type) } if types.is_a?(Array)

      type?(value, types)
    end

    private def valid_enum?(schema, value)
      return false if schema.key?("enum") && !schema["enum"].any? { |candidate| json_equal?(candidate, value) }
      return false if schema.key?("const") && !json_equal?(schema["const"], value)

      true
    end

    private def valid_combiners?(schema, value, base)
      return false if schema.key?("allOf") && !schema["allOf"].all? { |subschema| evaluate_valid(subschema, value, base) }
      return false if schema.key?("anyOf") && !schema["anyOf"].any? { |subschema| evaluate_valid(subschema, value, base) }

      if schema.key?("oneOf")
        matches = 0
        schema["oneOf"].each do |subschema|
          matches += 1 if evaluate_valid(subschema, value, base)
          return false if matches > 1
        end
        return false unless matches == 1
      end

      return false if schema.key?("not") && evaluate_valid(schema["not"], value, base)

      if schema.key?("if")
        branch = evaluate_valid(schema["if"], value, base) ? "then" : "else"
        return false if schema.key?(branch) && !evaluate_valid(schema[branch], value, base)
      end

      true
    end

    private def valid_number?(schema, value)
      actual = nil
      if schema.key?("maximum")
        actual ||= decimal(value)
        return false unless actual <= decimal(schema["maximum"])
      end
      if schema.key?("minimum")
        actual ||= decimal(value)
        return false unless actual >= decimal(schema["minimum"])
      end
      if schema.key?("exclusiveMaximum")
        actual ||= decimal(value)
        return false unless actual < decimal(schema["exclusiveMaximum"])
      end
      if schema.key?("exclusiveMinimum")
        actual ||= decimal(value)
        return false unless actual > decimal(schema["exclusiveMinimum"])
      end
      if schema.key?("multipleOf")
        divisor = decimal(schema["multipleOf"])
        return false unless divisor.positive?
        return false unless (actual || decimal(value)).remainder(divisor).zero?
      end
      true
    end

    private def valid_string?(schema, value)
      length = value.length
      return false if schema.key?("maxLength") && length > schema["maxLength"]
      return false if schema.key?("minLength") && length < schema["minLength"]
      return false if schema.key?("pattern") && !ecma_regexp(schema["pattern"]).match?(value)
      return valid_content?(schema, value) if @validate_content

      true
    rescue RegexpError
      false
    end

    private def valid_content?(schema, value)
      decoded = (schema["contentEncoding"] == "base64") ? Base64.strict_decode64(value) : value
      JSON.parse(decoded) if schema["contentMediaType"] == "application/json"
      true
    rescue ArgumentError, JSON::ParserError
      false
    end

    private def valid_array?(schema, value, base)
      length = value.length
      return false if schema.key?("maxItems") && length > schema["maxItems"]
      return false if schema.key?("minItems") && length < schema["minItems"]
      if schema["uniqueItems"]
        value.each_with_index do |item, index|
          return false if value[0...index].any? { |previous| json_equal?(previous, item) }
        end
      end

      items = schema["items"]
      if items.is_a?(Array)
        items.each_with_index do |subschema, index|
          break if index >= length
          return false unless evaluate_valid(subschema, value[index], base)
        end
        if length > items.length && schema.key?("additionalItems")
          (items.length...length).each do |index|
            return false unless evaluate_valid(schema["additionalItems"], value[index], base)
          end
        end
      elsif !items.nil?
        value.each { |item| return false unless evaluate_valid(items, item, base) }
      end

      return false if schema.key?("contains") && !value.any? { |item| evaluate_valid(schema["contains"], item, base) }

      true
    end

    private def valid_object?(schema, value, base)
      length = value.length
      return false if schema.key?("maxProperties") && length > schema["maxProperties"]
      return false if schema.key?("minProperties") && length < schema["minProperties"]
      return false if schema.key?("required") && !schema["required"].all? { |name| value.key?(name) }

      properties = schema["properties"]
      patterns = schema["patternProperties"]
      additional = schema["additionalProperties"] if schema.key?("additionalProperties")
      value.each do |name, property_value|
        matched = false
        if properties&.key?(name)
          matched = true
          return false unless evaluate_valid(properties[name], property_value, base)
        end
        if patterns
          patterns.each do |pattern, subschema|
            next unless ecma_regexp(pattern).match?(name)
            matched = true
            return false unless evaluate_valid(subschema, property_value, base)
          end
        end
        return false if !matched && !additional.nil? && !evaluate_valid(additional, property_value, base)
      end

      if schema.key?("propertyNames")
        value.each_key { |name| return false unless evaluate_valid(schema["propertyNames"], name, base) }
      end

      if schema.key?("dependencies")
        schema["dependencies"].each do |name, dependency|
          next unless value.key?(name)
          if dependency.is_a?(Array)
            return false unless dependency.all? { |required_name| value.key?(required_name) }
          else
            return false unless evaluate_valid(dependency, value, base)
          end
        end
      end
      true
    end

    private def evaluate(schema, instance, base, instance_path, schema_path)
      return true if schema == true
      return add_error("falseSchema", instance_path, schema_path, "boolean schema is false") if schema == false
      return true unless schema.is_a?(Hash)

      base = @bases.fetch(schema.object_id, base)
      before = @error_count

      if schema.key?("$ref")
        instances = active_instances(schema)
        instance_id = instance.object_id
        return true if instances[instance_id]

        instances[instance_id] = true
        begin
          target, target_base = resolve(schema["$ref"], @ref_bases.fetch(schema.object_id, base))
          evaluate(target, instance, target_base, instance_path, append(schema_path, "$ref"))
        rescue ResolutionError => e
          add_error("$ref", instance_path, schema_path, e.message)
        ensure
          instances.delete(instance_id)
        end
        return @error_count == before
      end

      keywords = @keyword_masks.fetch(schema.object_id)
      check_type(schema, instance, instance_path, schema_path) if (keywords & TYPE_KEYWORDS) != 0
      check_enum(schema, instance, instance_path, schema_path) if (keywords & ENUM_KEYWORDS) != 0
      check_combiners(schema, instance, base, instance_path, schema_path) if (keywords & COMBINER_KEYWORDS) != 0

      case instance
      when Hash
        check_object(schema, instance, base, instance_path, schema_path) if (keywords & OBJECT_KEYWORDS) != 0
      when Array
        check_array(schema, instance, base, instance_path, schema_path) if (keywords & ARRAY_KEYWORDS) != 0
      when String
        check_string(schema, instance, instance_path, schema_path) if (keywords & STRING_KEYWORDS) != 0
      when Numeric
        check_number(schema, instance, instance_path, schema_path) if !instance.is_a?(Complex) && (keywords & NUMBER_KEYWORDS) != 0
      end

      @error_count == before
    end

    private def active_instances(schema)
      active = (@active ||= {})
      active[schema.object_id] ||= {}
    end

    private def check_type(schema, value, path, schema_path)
      return unless schema.key?("type")

      types = Array(schema["type"])
      return if types.any? { |type| type?(value, type) }

      add_error("type", path, append(schema_path, "type"), "expected #{types.join(" or ")}")
    end

    private def check_enum(schema, value, path, schema_path)
      if schema.key?("enum") && !schema["enum"].any? { |candidate| json_equal?(candidate, value) }
        add_error("enum", path, append(schema_path, "enum"), "value is not in enum")
      end
      if schema.key?("const") && !json_equal?(schema["const"], value)
        add_error("const", path, append(schema_path, "const"), "value does not equal const")
      end
    end

    private def check_combiners(schema, value, base, path, schema_path)
      if schema.key?("allOf")
        schema["allOf"].each_with_index do |subschema, index|
          evaluate(subschema, value, base, path, append(append(schema_path, "allOf"), index))
        end
      end

      if schema.key?("anyOf")
        matches = schema["anyOf"].each_with_index.count do |subschema, index|
          trial(subschema, value, base, path, append(append(schema_path, "anyOf"), index))
        end
        add_error("anyOf", path, append(schema_path, "anyOf"), "no subschema matched") if matches.zero?
      end

      if schema.key?("oneOf")
        matches = schema["oneOf"].each_with_index.count do |subschema, index|
          trial(subschema, value, base, path, append(append(schema_path, "oneOf"), index))
        end
        add_error("oneOf", path, append(schema_path, "oneOf"), "expected exactly one match, got #{matches}") unless matches == 1
      end

      if schema.key?("not") && trial(schema["not"], value, base, path, append(schema_path, "not"))
        add_error("not", path, append(schema_path, "not"), "subschema matched")
      end

      return unless schema.key?("if")

      condition = trial(schema["if"], value, base, path, append(schema_path, "if"))
      branch = condition ? "then" : "else"
      evaluate(schema[branch], value, base, path, append(schema_path, branch)) if schema.key?(branch)
    end

    private def check_number(schema, value, path, schema_path)
      compare(schema, "maximum", value, path, schema_path) { |a, b| a <= b }
      compare(schema, "minimum", value, path, schema_path) { |a, b| a >= b }
      compare(schema, "exclusiveMaximum", value, path, schema_path) { |a, b| a < b }
      compare(schema, "exclusiveMinimum", value, path, schema_path) { |a, b| a > b }

      return unless schema.key?("multipleOf")

      divisor = decimal(schema["multipleOf"])
      valid = divisor.positive? && decimal(value).remainder(divisor).zero?
      add_error("multipleOf", path, append(schema_path, "multipleOf"), "number is not a multiple") unless valid
    end

    private def compare(schema, keyword, value, path, schema_path)
      return unless schema.key?(keyword)
      return if yield(decimal(value), decimal(schema[keyword]))

      add_error(keyword, path, append(schema_path, keyword), "numeric limit was exceeded")
    end

    private def check_string(schema, value, path, schema_path)
      length = value.length
      limit(schema, "maxLength", length, path, schema_path) { |actual, expected| actual <= expected }
      limit(schema, "minLength", length, path, schema_path) { |actual, expected| actual >= expected }

      if schema.key?("pattern")
        matched = ecma_regexp(schema["pattern"]).match?(value)
        add_error("pattern", path, append(schema_path, "pattern"), "string does not match pattern") unless matched
      end
      check_content(schema, value, path, schema_path) if @validate_content
    rescue RegexpError
      add_error("pattern", path, append(schema_path, "pattern"), "invalid regular expression")
    end

    private def check_array(schema, value, base, path, schema_path)
      limit(schema, "maxItems", value.length, path, schema_path) { |actual, expected| actual <= expected }
      limit(schema, "minItems", value.length, path, schema_path) { |actual, expected| actual >= expected }

      if schema["uniqueItems"]
        duplicate = value.each_with_index.any? do |item, index|
          value[0...index].any? { |previous| json_equal?(previous, item) }
        end
        add_error("uniqueItems", path, append(schema_path, "uniqueItems"), "array items are not unique") if duplicate
      end

      items = schema["items"]
      if items.is_a?(Array)
        items.each_with_index do |subschema, index|
          break if index >= value.length
          evaluate(subschema, value[index], base, append(path, index), append(append(schema_path, "items"), index))
        end
        if value.length > items.length && schema.key?("additionalItems")
          additional = schema["additionalItems"]
          (items.length...value.length).each do |index|
            evaluate(additional, value[index], base, append(path, index), append(schema_path, "additionalItems"))
          end
        end
      elsif !items.nil?
        value.each_with_index do |item, index|
          evaluate(items, item, base, append(path, index), append(schema_path, "items"))
        end
      end

      return unless schema.key?("contains")

      matched = value.each_with_index.any? do |item, index|
        trial(schema["contains"], item, base, append(path, index), append(schema_path, "contains"))
      end
      add_error("contains", path, append(schema_path, "contains"), "no array item matched") unless matched
    end

    private def check_object(schema, value, base, path, schema_path)
      limit(schema, "maxProperties", value.length, path, schema_path) { |actual, expected| actual <= expected }
      limit(schema, "minProperties", value.length, path, schema_path) { |actual, expected| actual >= expected }

      Array(schema["required"]).each do |name|
        add_error("required", path, append(schema_path, "required"), "required property #{name.inspect} is missing") unless value.key?(name)
      end

      properties = schema.fetch("properties", {})
      patterns = schema.fetch("patternProperties", {})
      value.each do |name, property_value|
        matched = false
        if properties.key?(name)
          matched = true
          evaluate(properties[name], property_value, base, append(path, name), append(append(schema_path, "properties"), name))
        end
        patterns.each do |pattern, subschema|
          next unless ecma_regexp(pattern).match?(name)
          matched = true
          evaluate(subschema, property_value, base, append(path, name), append(append(schema_path, "patternProperties"), pattern))
        end
        if !matched && schema.key?("additionalProperties")
          evaluate(schema["additionalProperties"], property_value, base, append(path, name), append(schema_path, "additionalProperties"))
        end
      end

      if schema.key?("propertyNames")
        value.each_key do |name|
          evaluate(schema["propertyNames"], name, base, append(path, name), append(schema_path, "propertyNames"))
        end
      end

      schema.fetch("dependencies", {}).each do |name, dependency|
        next unless value.key?(name)
        if dependency.is_a?(Array)
          dependency.each do |required_name|
            add_error("dependencies", path, append(schema_path, "dependencies"), "property #{required_name.inspect} is required by #{name.inspect}") unless value.key?(required_name)
          end
        else
          evaluate(dependency, value, base, path, append(append(schema_path, "dependencies"), name))
        end
      end
    end

    private def trial(schema, value, base, path, schema_path)
      saved_errors = @errors
      saved_error_count = @error_count
      @errors = [] if saved_errors
      @error_count = 0
      result = evaluate(schema, value, base, path, schema_path)
      result
    ensure
      @errors = saved_errors
      @error_count = saved_error_count
    end

    private def limit(schema, keyword, actual, path, schema_path)
      return unless schema.key?(keyword)
      return if yield(actual, schema[keyword])

      add_error(keyword, path, append(schema_path, keyword), "size limit was exceeded")
    end

    private def type?(value, type)
      case type
      when "null" then value.nil?
      when "boolean" then value == true || value == false
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "number" then number?(value)
      when "integer" then number?(value) && value.finite? && value.to_i == value
      when "string" then value.is_a?(String)
      else false
      end
    end

    private def number?(value)
      value.is_a?(Numeric) && !value.is_a?(Complex)
    end

    private def json_equal?(left, right)
      return false if json_kind(left) != json_kind(right)
      case left
      when Hash
        left.length == right.length && left.all? { |key, value| right.key?(key) && json_equal?(value, right[key]) }
      when Array
        left.length == right.length && left.each_index.all? { |index| json_equal?(left[index], right[index]) }
      else
        left == right
      end
    end

    private def json_kind(value)
      return :number if number?(value)
      return :boolean if value == true || value == false
      value.class
    end

    private def decimal(value)
      return value if value.is_a?(Integer) || value.is_a?(Rational)

      Rational(value.to_s)
    end

    # Ruby and ECMA-262 differ in their ASCII character classes, anchors, and
    # definition of whitespace. Draft 7 patterns use the ECMA behavior.
    private def ecma_regexp(pattern)
      regexps = (@regexps ||= {})
      return regexps[pattern] if regexps.key?(pattern)

      whitespace = "\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
      translated = +""
      escaped = false
      in_class = false
      pattern.each_char do |character|
        if escaped
          translated << case character
          when "d" then in_class ? "0-9" : "[0-9]"
          when "D" then in_class ? "^0-9" : "[^0-9]"
          when "w" then in_class ? "A-Za-z0-9_" : "[A-Za-z0-9_]"
          when "W" then in_class ? "^A-Za-z0-9_" : "[^A-Za-z0-9_]"
          when "s" then in_class ? whitespace : "[#{whitespace}]"
          when "S" then in_class ? "^#{whitespace}" : "[^#{whitespace}]"
          else "\\#{character}"
          end
          escaped = false
        elsif character == "\\"
          escaped = true
        elsif character == "["
          in_class = true
          translated << character
        elsif character == "]"
          in_class = false
          translated << character
        elsif character == "^" && !in_class
          translated << "\\A"
        elsif character == "$" && !in_class
          translated << "\\z"
        else
          translated << character
        end
      end
      translated << "\\" if escaped
      regexps[pattern] = Regexp.new(translated)
    end

    private def check_content(schema, value, path, schema_path)
      decoded = value
      if schema["contentEncoding"] == "base64"
        decoded = Base64.strict_decode64(value)
      end
      return unless schema["contentMediaType"] == "application/json"

      JSON.parse(decoded)
    rescue ArgumentError, JSON::ParserError
      keyword = (schema["contentEncoding"] == "base64") ? "contentEncoding" : "contentMediaType"
      add_error(keyword, path, append(schema_path, keyword), "string content is invalid")
    end

    private def add_error(keyword, instance_path, schema_path, message)
      @error_count += 1
      @errors << Error.new(keyword: keyword, instance_path: instance_path, schema_path: schema_path, message: message) if @errors
      false
    end

    private def index(schema, inherited_base)
      return unless schema.is_a?(Hash) || schema.is_a?(Array)

      if schema.is_a?(Array)
        schema.each { |child| index(child, inherited_base) }
        return
      end

      @ref_bases[schema.object_id] = inherited_base
      @keyword_masks[schema.object_id] = keyword_mask(schema)
      if schema.key?("$ref")
        @bases[schema.object_id] = inherited_base
        return
      end
      base = absolute_id(inherited_base, schema["$id"])
      base = inherited_base if base.empty?
      @bases[schema.object_id] = base
      @registry[base] = schema if schema.key?("$id") && !base.empty?
      @registry[strip_fragment(base)] ||= schema if schema.key?("$id") && !base.empty? && fragment(base).empty?
      SINGLE_SCHEMA_KEYWORDS.each do |keyword|
        index(schema[keyword], base) if schema.key?(keyword)
      end
      if schema.key?("items")
        index(schema["items"], base)
      end
      ARRAY_SCHEMA_KEYWORDS.each do |keyword|
        index(schema[keyword], base) if schema.key?(keyword)
      end
      HASH_SCHEMA_KEYWORDS.each do |keyword|
        schema.fetch(keyword, {}).each_value { |child| index(child, base) }
      end
      schema.fetch("dependencies", {}).each_value do |child|
        index(child, base) unless child.is_a?(Array)
      end
    end

    private def resolve(reference, base)
      resolved_refs = (@resolved_refs ||= {})
      cache_key = [base, reference]
      return resolved_refs[cache_key] if resolved_refs.key?(cache_key)

      uri = absolute_id(base, reference)
      document_uri = strip_fragment(uri)
      index_external(document_uri)
      unless @registry.key?(uri)
        @external_schemas.each do |external_uri, external_schema|
          index_external_schema(external_uri.to_s, external_schema)
          break if @registry.key?(uri)
        end
      end
      if @registry.key?(uri)
        target = @registry[uri]
        index_meta_schema if target.equal?(DRAFT7_META_SCHEMA)
        return resolved_refs[cache_key] = [target, @bases.fetch(target.object_id, strip_fragment(uri))]
      end

      document = if document_uri.empty? || document_uri == strip_fragment(@root_base)
        @root
      else
        @registry[document_uri]
      end
      raise ResolutionError, "unresolvable reference #{reference.inspect}" unless document

      index_meta_schema if document.equal?(DRAFT7_META_SCHEMA)

      target = pointer(document, fragment(uri))
      resolved_refs[cache_key] = [target, @bases.fetch(target.object_id, document_uri)]
    end

    private def index_external(document_uri)
      indexed_documents = (@indexed_external_documents ||= {})
      return if indexed_documents[document_uri]

      indexed_documents[document_uri] = true
      if @external_schemas.key?(document_uri)
        external_schema = @external_schemas[document_uri]
        index_external_schema(document_uri, external_schema)
        return
      end

      @external_schemas.each do |external_uri, external_schema|
        external_uri = external_uri.to_s
        next unless strip_fragment(external_uri) == document_uri

        index_external_schema(external_uri, external_schema)
      end
    end

    private def index_external_schema(external_uri, external_schema)
      indexed_schemas = (@indexed_external_schemas ||= {})
      return if indexed_schemas[external_uri]

      indexed_schemas[external_uri] = true
      @registry[strip_fragment(external_uri)] ||= external_schema
      index(external_schema, external_uri)
    end

    private def pointer(document, raw_fragment)
      return document if raw_fragment.empty?
      decoded = URI.decode_uri_component(raw_fragment)
      raise ResolutionError, "unsupported plain-name fragment ##{raw_fragment}" unless decoded.start_with?("/")

      decoded.split("/", -1).drop(1).reduce(document) do |current, token|
        key = token.gsub("~1", "/").gsub("~0", "~")
        if current.is_a?(Array)
          raise ResolutionError, "invalid JSON Pointer index #{key.inspect}" unless key.match?(/\A(?:0|[1-9]\d*)\z/)
          current.fetch(key.to_i)
        elsif current.is_a?(Hash)
          current.fetch(key)
        else
          raise ResolutionError, "JSON Pointer traverses a scalar"
        end
      end
    rescue IndexError
      raise ResolutionError, "JSON Pointer target does not exist"
    end

    private def absolute_id(base, identifier)
      base = base.to_s
      return base if identifier.nil?

      identifier = identifier.to_s
      return identifier if base.empty? || identifier.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)
      return strip_fragment(base) if identifier.empty?
      return "#{strip_fragment(base)}#{identifier}" if identifier.start_with?("#")

      URI.join(base, identifier).to_s
    rescue URI::Error
      begin
        URI.join("resolve:///", base.to_s, identifier.to_s).to_s.delete_prefix("resolve:///")
      rescue URI::Error
        identifier.to_s
      end
    end

    private def strip_fragment(uri)
      index = uri.index("#")
      index ? uri[0, index] : uri
    end

    private def fragment(uri)
      index = uri.index("#")
      index ? uri[(index + 1)..] : ""
    end

    private def append(path, segment)
      return if path.nil?

      "#{path}/#{segment.to_s.gsub("~", "~0").gsub("/", "~1")}"
    end

    private def keyword_mask(schema)
      mask = 0
      schema.each_key { |keyword| mask |= KEYWORD_MASKS.fetch(keyword, 0) }
      mask
    end

    private def index_meta_schema
      return if @meta_schema_indexed

      index(DRAFT7_META_SCHEMA, "#{DRAFT7_META_SCHEMA_URI}#")
      @meta_schema_indexed = true
    end
  end

  module_function def validate(schema, instance, **options)
    Validator.new(schema, **options).validate(instance)
  end

  module_function def valid?(schema, instance, **options)
    Validator.new(schema, **options).valid?(instance)
  end
end
