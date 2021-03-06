require 'haml/attribute_parser'

module Haml
  class AttributeCompiler
    # @param type [Symbol] :static or :dynamic
    # @param key [String]
    # @param value [String] Actual string value for :static type, value's Ruby literal for :dynamic type.
    class AttributeValue < Struct.new(:type, :key, :value)
      # @return [String] A Ruby literal of value.
      def to_literal
        case type
        when :static
          Haml::Util.inspect_obj(value)
        when :dynamic
          value
        end
      end

      # Key's substring before a hyphen. This is necessary because values with the same
      # base_key can conflict by Haml::AttributeBuidler#build_data_keys.
      def base_key
        key.split('-', 2).first
      end
    end

    # Returns a script to render attributes on runtime.
    #
    # @param attributes [Hash]
    # @param object_ref [String,:nil]
    # @param attributes_hashes [Array<String>]
    # @return [String] Attributes rendering code
    def self.runtime_build(attributes, object_ref, attributes_hashes)
      "_hamlout.attributes(#{Haml::Util.inspect_obj(attributes)}, #{object_ref},#{attributes_hashes.join(', ')})"
    end

    # @param options [Haml::Options]
    def initialize(options)
      @is_html = [:html4, :html5].include?(options[:format])
      @attr_wrapper = options[:attr_wrapper]
      @escape_attrs = options[:escape_attrs]
      @hyphenate_data_attrs = options[:hyphenate_data_attrs]
    end

    # Returns Temple expression to render attributes.
    #
    # @param attributes [Hash]
    # @param object_ref [String,:nil]
    # @param attributes_hashes [Array<String>]
    # @return [Array] Temple expression
    def compile(attributes, object_ref, attributes_hashes)
      if object_ref != :nil || !AttributeParser.available?
        return [:dynamic, AttributeCompiler.runtime_build(attributes, object_ref, attributes_hashes)]
      end

      parsed_hashes = attributes_hashes.map do |attribute_hash|
        unless (hash = AttributeParser.parse(attribute_hash))
          return [:dynamic, AttributeCompiler.runtime_build(attributes, object_ref, attributes_hashes)]
        end
        hash
      end
      attribute_values = build_attribute_values(attributes, parsed_hashes)
      AttributeBuilder.verify_attribute_names!(attribute_values.map(&:key))

      values_by_base_key = attribute_values.group_by(&:base_key)
      [:multi, *values_by_base_key.keys.sort.map { |base_key|
        compile_attribute_values(values_by_base_key[base_key])
      }]
    end

    private

    # Returns array of AttributeValue instnces from static attributes and dynamic attributes_hashes. For each key,
    # the values' order in returned value is preserved in the same order as Haml::Buffer#attributes's merge order.
    #
    # @param attributes [{ String => String }]
    # @param parsed_hashes [{ String => String }]
    # @return [Array<AttributeValue>]
    def build_attribute_values(attributes, parsed_hashes)
      [].tap do |attribute_values|
        attributes.each do |key, static_value|
          attribute_values << AttributeValue.new(:static, key, static_value)
        end
        parsed_hashes.each do |parsed_hash|
          parsed_hash.each do |key, dynamic_value|
            attribute_values << AttributeValue.new(:dynamic, key, dynamic_value)
          end
        end
      end
    end

    # Compiles attribute values with the same base_key to Temple expression.
    #
    # @param values [Array<AttributeValue>] `base_key`'s results are the same. `key`'s result may differ.
    # @return [Array] Temple expression
    def compile_attribute_values(values)
      if values.map(&:key).uniq.size == 1
        compile_attribute(values.first.key, values)
      else
        runtime_build(values)
      end
    end

    # @param values [Array<AttributeValue>]
    # @return [Array] Temple expression
    def runtime_build(values)
      hash_content = values.group_by(&:key).map do |key, values_for_key|
        "#{frozen_string(key)} => #{merged_value(key, values_for_key)}"
      end.join(', ')
      [:dynamic, "_hamlout.attributes({ #{hash_content} }, nil)"]
    end

    # Renders attribute values statically.
    #
    # @param values [Array<AttributeValue>]
    # @return [Array] Temple expression
    def static_build(values)
      hash_content = values.group_by(&:key).map do |key, values_for_key|
        "#{frozen_string(key)} => #{merged_value(key, values_for_key)}"
      end.join(', ')

      arguments = [@is_html, @attr_wrapper, @escape_attrs, @hyphenate_data_attrs]
      code = "::Haml::AttributeBuilder.build_attributes"\
        "(#{arguments.map { |a| Haml::Util.inspect_obj(a) }.join(', ')}, { #{hash_content} })"
      [:static, eval(code).to_s]
    end

    # @param key [String]
    # @param values [Array<AttributeValue>]
    # @return [String]
    def merged_value(key, values)
      if values.size == 1
        values.first.to_literal
      else
        "::Haml::AttributeBuilder.merge_values(#{frozen_string(key)}, #{values.map(&:to_literal).join(', ')})"
      end
    end

    # @param str [String]
    # @return [String]
    def frozen_string(str)
      "#{Haml::Util.inspect_obj(str)}.freeze"
    end

    # Compiles attribute values for one key to Temple expression that generates ` key='value'`.
    #
    # @param key [String]
    # @param values [Array<AttributeValue>]
    # @return [Array] Temple expression
    def compile_attribute(key, values)
      if values.all? { |v| Temple::StaticAnalyzer.static?(v.to_literal) }
        return static_build(values)
      end

      case key
      when 'id', 'class'
        compile_id_or_class_attribute(key, values)
      else
        compile_common_attribute(key, values)
      end
    end

    # @param id_or_class [String] "id" or "class"
    # @param values [Array<AttributeValue>]
    # @return [Array] Temple expression
    def compile_id_or_class_attribute(id_or_class, values)
      var = unique_name
      [:multi,
       [:code, "#{var} = (#{merged_value(id_or_class, values)})"],
       [:case, var,
        ['Hash, Array', runtime_build([AttributeValue.new(:dynamic, id_or_class, var)])],
        ['false, nil', [:multi]],
        [:else, [:multi,
                 [:static, " #{id_or_class}=#{@attr_wrapper}"],
                 [:escape, @escape_attrs, [:dynamic, var]],
                 [:static, @attr_wrapper]],
        ]
       ],
      ]
    end

    # @param key [String] Not "id" or "class"
    # @param values [Array<AttributeValue>]
    # @return [Array] Temple expression
    def compile_common_attribute(key, values)
      var = unique_name
      [:multi,
       [:code, "#{var} = (#{merged_value(key, values)})"],
       [:case, var,
        ['Hash', runtime_build([AttributeValue.new(:dynamic, key, var)])],
        ['true', true_value(key)],
        ['false, nil', [:multi]],
        [:else, [:multi,
                 [:static, " #{key}=#{@attr_wrapper}"],
                 [:escape, @escape_attrs, [:dynamic, var]],
                 [:static, @attr_wrapper]],
        ]
       ],
      ]
    end

    def true_value(key)
      if @is_html
        [:static, " #{key}"]
      else
        [:static, " #{key}=#{@attr_wrapper}#{key}#{@attr_wrapper}"]
      end
    end

    def unique_name
      @unique_name ||= 0
      "_haml_attribute_compiler#{@unique_name += 1}"
    end
  end
end
