#!/usr/bin/env ruby
# frozen_string_literal: true

# Parse and structurally validate the checked-in OpenAPI contract using only
# Ruby's standard-library YAML parser. This keeps the runtime Python host
# dependency-free while making the publication gate reject malformed or
# incomplete API documents.

require "set"
require "yaml"

HTTP_METHODS = %w[get post put patch delete options head trace].freeze
SCHEMA_TYPES = %w[array boolean integer null number object string].freeze
STATUS_PATTERN = /\A(?:[1-5][0-9]{2}|default)\z/.freeze

def abort_usage
  warn "usage: Scripts/check-openapi.rb [Docs/openapi.yaml]"
  exit 2
end

abort_usage if ARGV.length > 1
contract_path = File.expand_path(ARGV.fetch(0, File.join(__dir__, "..", "Docs", "openapi.yaml")))

unless File.file?(contract_path)
  warn "[cofleet] error: missing checked-in OpenAPI contract: #{contract_path}"
  exit 1
end

def detect_duplicate_keys(node, path = "$")
  if node.is_a?(Psych::Nodes::Mapping)
    seen = {}
    node.children.each_slice(2) do |key, value|
      if key.is_a?(Psych::Nodes::Scalar)
        name = key.value
        raise ArgumentError, "duplicate mapping key #{name.inspect} at #{path}" if seen.key?(name)

        seen[name] = true
        detect_duplicate_keys(value, "#{path}/#{name}")
      else
        detect_duplicate_keys(key, path)
        detect_duplicate_keys(value, path)
      end
    end
  elsif node.respond_to?(:children) && node.children.is_a?(Array)
    node.children.each { |child| detect_duplicate_keys(child, path) }
  end
end

begin
  source = File.read(contract_path, encoding: "UTF-8")
  syntax_tree = Psych.parse_stream(source, contract_path)
  detect_duplicate_keys(syntax_tree)
  document = YAML.safe_load(
    source,
    permitted_classes: [],
    permitted_symbols: [],
    aliases: false,
    filename: contract_path
  )
rescue Psych::Exception, ArgumentError => error
  warn "[cofleet] error: OpenAPI YAML parse failed: #{error.message}"
  exit 1
end

errors = []

def expect_hash(value, path, errors)
  return value if value.is_a?(Hash)

  errors << "#{path} must be an object"
  {}
end

def expect_nonempty_string(value, path, errors)
  return if value.is_a?(String) && !value.strip.empty?

  errors << "#{path} must be a non-empty string"
end

def resolve_ref(document, reference, path, errors)
  unless reference.is_a?(String) && reference.start_with?("#/")
    errors << "#{path} must be a local JSON Pointer reference"
    return nil
  end

  current = document
  reference.delete_prefix("#/").split("/").each do |raw_segment|
    segment = raw_segment.gsub("~1", "/").gsub("~0", "~")
    unless current.is_a?(Hash) && current.key?(segment)
      errors << "#{path} is dangling: #{reference}"
      return nil
    end
    current = current[segment]
  end
  current
end

def dereference(document, value, path, errors)
  return value unless value.is_a?(Hash) && value.key?("$ref")

  resolve_ref(document, value["$ref"], "#{path}/$ref", errors)
end

def validate_schema(document, raw_schema, path, errors, active_refs = Set.new)
  schema = expect_hash(raw_schema, path, errors)
  return if schema.empty?

  if schema.key?("$ref")
    reference = schema["$ref"]
    target = resolve_ref(document, reference, "#{path}/$ref", errors)
    if target && !active_refs.include?(reference)
      validate_schema(document, target, reference, errors, active_refs | [reference])
    end
  end

  if schema.key?("type")
    types = schema["type"].is_a?(Array) ? schema["type"] : [schema["type"]]
    if types.empty? || types.any? { |type| !SCHEMA_TYPES.include?(type) }
      errors << "#{path}/type contains an invalid JSON Schema type"
    end
  end

  if schema.key?("required")
    required = schema["required"]
    unless required.is_a?(Array) && required.all? { |name| name.is_a?(String) } && required.uniq == required
      errors << "#{path}/required must be an array of unique property names"
    end
  end

  if schema.key?("properties")
    properties = expect_hash(schema["properties"], "#{path}/properties", errors)
    properties.each do |name, property|
      validate_schema(document, property, "#{path}/properties/#{name}", errors, active_refs)
    end
    if schema["required"].is_a?(Array)
      missing = schema["required"].reject { |name| properties.key?(name) }
      errors << "#{path}/required names undefined properties: #{missing.join(', ')}" unless missing.empty?
    end
  end

  validate_schema(document, schema["items"], "#{path}/items", errors, active_refs) if schema.key?("items")
  if schema["additionalProperties"].is_a?(Hash)
    validate_schema(
      document,
      schema["additionalProperties"],
      "#{path}/additionalProperties",
      errors,
      active_refs
    )
  end
  %w[allOf anyOf oneOf].each do |keyword|
    next unless schema.key?(keyword)

    branches = schema[keyword]
    unless branches.is_a?(Array) && !branches.empty?
      errors << "#{path}/#{keyword} must be a non-empty array"
      next
    end
    branches.each_with_index do |branch, index|
      validate_schema(document, branch, "#{path}/#{keyword}/#{index}", errors, active_refs)
    end
  end
end

def validate_content(document, raw_content, path, errors)
  content = expect_hash(raw_content, path, errors)
  errors << "#{path} must declare at least one media type" if content.empty?
  content.each do |media_type, media|
    media_object = expect_hash(media, "#{path}/#{media_type}", errors)
    unless media_object.key?("schema")
      errors << "#{path}/#{media_type} must declare a schema"
      next
    end
    validate_schema(document, media_object["schema"], "#{path}/#{media_type}/schema", errors)
  end
end

root = expect_hash(document, "$", errors)
unless root["openapi"].is_a?(String) && root["openapi"].match?(/\A3\.1(?:\.[0-9]+)?\z/)
  errors << "$/openapi must declare an OpenAPI 3.1 version"
end

info = expect_hash(root["info"], "$/info", errors)
expect_nonempty_string(info["title"], "$/info/title", errors)
expect_nonempty_string(info["version"], "$/info/version", errors)

components = expect_hash(root["components"], "$/components", errors)
schemas = expect_hash(components["schemas"], "$/components/schemas", errors)
errors << "$/components/schemas must not be empty" if schemas.empty?
schemas.each do |name, schema|
  validate_schema(root, schema, "$/components/schemas/#{name}", errors)
end

paths = expect_hash(root["paths"], "$/paths", errors)
errors << "$/paths must not be empty" if paths.empty?
operation_ids = {}
operation_count = 0

paths.each do |route, raw_path_item|
  unless route.is_a?(String) && route.start_with?("/")
    errors << "$/paths contains an invalid route key: #{route.inspect}"
    next
  end
  path_item = expect_hash(raw_path_item, "$/paths/#{route}", errors)
  operations = path_item.select { |key, _value| HTTP_METHODS.include?(key) }
  errors << "$/paths/#{route} must declare an HTTP operation" if operations.empty?

  operations.each do |method, raw_operation|
    operation_count += 1
    operation_path = "$/paths/#{route}/#{method}"
    operation = expect_hash(raw_operation, operation_path, errors)
    operation_id = operation["operationId"]
    expect_nonempty_string(operation_id, "#{operation_path}/operationId", errors)
    if operation_id.is_a?(String) && !operation_id.empty?
      if operation_ids.key?(operation_id)
        errors << "#{operation_path}/operationId duplicates #{operation_ids[operation_id]}"
      else
        operation_ids[operation_id] = operation_path
      end
    end

    placeholders = route.scan(/\{([^}]+)\}/).flatten.to_set
    parameters = Array(path_item["parameters"]) + Array(operation["parameters"])
    declared_path_parameters = Set.new
    parameters.each_with_index do |raw_parameter, index|
      parameter_path = "#{operation_path}/parameters/#{index}"
      parameter = dereference(root, raw_parameter, parameter_path, errors)
      next unless parameter.is_a?(Hash)

      validate_schema(root, parameter["schema"], "#{parameter_path}/schema", errors) if parameter.key?("schema")
      next unless parameter["in"] == "path"

      name = parameter["name"]
      declared_path_parameters << name if name.is_a?(String)
      errors << "#{parameter_path} path parameters must set required: true" unless parameter["required"] == true
    end
    missing_parameters = placeholders - declared_path_parameters
    extra_parameters = declared_path_parameters - placeholders
    errors << "#{operation_path} is missing path parameters: #{missing_parameters.to_a.join(', ')}" unless missing_parameters.empty?
    errors << "#{operation_path} declares unused path parameters: #{extra_parameters.to_a.join(', ')}" unless extra_parameters.empty?

    if operation.key?("requestBody")
      request_body = dereference(root, operation["requestBody"], "#{operation_path}/requestBody", errors)
      if request_body.is_a?(Hash)
        validate_content(root, request_body["content"], "#{operation_path}/requestBody/content", errors)
      end
    end

    responses = expect_hash(operation["responses"], "#{operation_path}/responses", errors)
    errors << "#{operation_path}/responses must not be empty" if responses.empty?
    success_count = 0
    responses.each do |status, raw_response|
      status_text = status.to_s
      errors << "#{operation_path}/responses has an invalid status #{status.inspect}" unless status_text.match?(STATUS_PATTERN)
      response_path = "#{operation_path}/responses/#{status_text}"
      response = dereference(root, raw_response, response_path, errors)
      next unless response.is_a?(Hash)

      expect_nonempty_string(response["description"], "#{response_path}/description", errors)
      next unless status_text.start_with?("2")

      success_count += 1
      next if status_text == "204"

      unless response.key?("content")
        errors << "#{response_path} must describe its successful response body"
        next
      end
      validate_content(root, response["content"], "#{response_path}/content", errors)
    end
    errors << "#{operation_path} must declare a successful response" if success_count.zero?
  end
end

if errors.any?
  errors.uniq.each { |error| warn "[cofleet] error: #{error}" }
  warn "[cofleet] error: OpenAPI structural validation failed with #{errors.uniq.length} issue(s)"
  exit 1
end

puts "[cofleet] OpenAPI contract passed (#{paths.length} paths, #{operation_count} operations, #{schemas.length} schemas)"
