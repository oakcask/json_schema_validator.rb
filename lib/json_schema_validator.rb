# frozen_string_literal: true

require "json"
require "uri"
require "base64"

module JsonSchemaValidator
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
      @bases = {}
      @ref_bases = {}
      @root_base = absolute_id(base_uri.to_s, schema.is_a?(Hash) ? schema["$id"] : nil)
      @root_base = base_uri.to_s if @root_base.empty? && base_uri

      schemas.each do |uri, external_schema|
        index(external_schema, uri.to_s)
        @registry[strip_fragment(uri.to_s)] ||= external_schema
      end
      meta_schema = JSON.parse(File.read(File.join(__dir__, "json_schema_validator", "draft7_schema.json")))
      index(meta_schema, "http://json-schema.org/draft-07/schema#")
      index(schema, @root_base)
      @registry[strip_fragment(@root_base)] ||= schema unless @root_base.empty?
    end

    def validate(instance)
      @errors = []
      @active = {}
      evaluate(@root, instance, @root_base, "", "")
      Result.new(@errors)
    end

    def valid?(instance)
      validate(instance).valid?
    end

    private def evaluate(schema, instance, base, instance_path, schema_path)
      return true if schema == true
      return add_error("falseSchema", instance_path, schema_path, "boolean schema is false") if schema == false
      return true unless schema.is_a?(Hash)

      base = @bases.fetch(schema.object_id, base)
      state = [schema.object_id, instance.object_id, base]
      return true if @active[state]

      @active[state] = true
      before = @errors.length

      if schema.key?("$ref")
        target, target_base = resolve(schema["$ref"], @ref_bases.fetch(schema.object_id, base))
        evaluate(target, instance, target_base, instance_path, append(schema_path, "$ref"))
        return finish(state, before)
      end

      check_type(schema, instance, instance_path, schema_path)
      check_enum(schema, instance, instance_path, schema_path)
      check_combiners(schema, instance, base, instance_path, schema_path)
      check_number(schema, instance, instance_path, schema_path) if number?(instance)
      check_string(schema, instance, instance_path, schema_path) if instance.is_a?(String)
      check_array(schema, instance, base, instance_path, schema_path) if instance.is_a?(Array)
      check_object(schema, instance, base, instance_path, schema_path) if instance.is_a?(Hash)

      finish(state, before)
    rescue ResolutionError => e
      add_error("$ref", instance_path, schema_path, e.message)
      finish(state, before)
    end

    private def finish(state, before)
      @active.delete(state)
      @errors.length == before
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
      @errors = []
      result = evaluate(schema, value, base, path, schema_path)
      result
    ensure
      @errors = saved_errors
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
      Rational(value.to_s)
    end

    # Ruby and ECMA-262 differ in their ASCII character classes, anchors, and
    # definition of whitespace. Draft 7 patterns use the ECMA behavior.
    private def ecma_regexp(pattern)
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
      Regexp.new(translated)
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
      @errors << Error.new(keyword: keyword, instance_path: instance_path, schema_path: schema_path, message: message)
      false
    end

    private def index(schema, inherited_base)
      return unless schema.is_a?(Hash) || schema.is_a?(Array)

      if schema.is_a?(Array)
        schema.each { |child| index(child, inherited_base) }
        return
      end

      @ref_bases[schema.object_id] = inherited_base
      if schema.key?("$ref")
        @bases[schema.object_id] = inherited_base
        return
      end
      base = absolute_id(inherited_base, schema["$id"])
      base = inherited_base if base.empty?
      @bases[schema.object_id] = base
      @registry[base] = schema if schema.key?("$id") && !base.empty?
      @registry[strip_fragment(base)] ||= schema if schema.key?("$id") && !base.empty? && fragment(base).empty?
      %w[additionalItems additionalProperties contains propertyNames not if then else].each do |keyword|
        index(schema[keyword], base) if schema.key?(keyword)
      end
      if schema.key?("items")
        index(schema["items"], base)
      end
      %w[allOf anyOf oneOf].each do |keyword|
        index(schema[keyword], base) if schema.key?(keyword)
      end
      %w[definitions properties patternProperties].each do |keyword|
        schema.fetch(keyword, {}).each_value { |child| index(child, base) }
      end
      schema.fetch("dependencies", {}).each_value do |child|
        index(child, base) unless child.is_a?(Array)
      end
    end

    private def resolve(reference, base)
      uri = absolute_id(base, reference)
      return [@registry[uri], @bases.fetch(@registry[uri].object_id, strip_fragment(uri))] if @registry.key?(uri)

      document_uri = strip_fragment(uri)
      document = if document_uri.empty? || document_uri == strip_fragment(@root_base)
        @root
      else
        @registry[document_uri]
      end
      raise ResolutionError, "unresolvable reference #{reference.inspect}" unless document

      target = pointer(document, fragment(uri))
      [target, @bases.fetch(target.object_id, document_uri)]
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
      return base.to_s if identifier.nil?
      return identifier.to_s if base.to_s.empty?
      URI.join(base.to_s, identifier.to_s).to_s
    rescue URI::Error
      begin
        URI.join("resolve:///", base.to_s, identifier.to_s).to_s.delete_prefix("resolve:///")
      rescue URI::Error
        identifier.to_s
      end
    end

    private def strip_fragment(uri)
      uri.sub(/#.*/, "")
    end

    private def fragment(uri)
      uri.include?("#") ? uri.split("#", 2).last : ""
    end

    private def append(path, segment)
      "#{path}/#{segment.to_s.gsub("~", "~0").gsub("/", "~1")}"
    end
  end

  module_function def validate(schema, instance, **options)
    Validator.new(schema, **options).validate(instance)
  end

  module_function def valid?(schema, instance, **options)
    Validator.new(schema, **options).valid?(instance)
  end
end
