# frozen_string_literal: true

require 'ipaddr'
require 'puppet/resource_api'
require_relative 'nitro_provider'
require_relative 'compat_definitions'

module PuppetX
  module Netscaler
    # Builds the Resource API definitions of the puppetlabs-netscaler
    # compatible netscaler_* types.
    module Compat
      TRUTHY_TRUE = %w[true yes enabled on].freeze
      TRUTHY_FALSE = %w[false no disabled off].freeze
      TRUTHY_STRINGS = (TRUTHY_TRUE + TRUTHY_FALSE).flat_map { |v| [v, v.upcase] }.freeze
      SENSITIVE_TYPE = 'Optional[Variant[String, Sensitive[String]]]'

      module_function

      def definition(type_name)
        c = COMPAT.fetch(type_name)
        attributes = {
          ensure: {
            type: 'Enum[present, absent]',
            desc: 'Whether this resource should be present or absent on the NetScaler.',
            default: 'present',
          },
          name: {
            type: 'String',
            desc: c[:title_format] ? "Title in the form `#{c[:title_format].gsub(%r{%\{(\w+)\}}, '<\1>')}`." : 'Name of the object.',
            behaviour: :namevar,
          },
        }
        c[:attributes].each do |name, a|
          desc = a[:desc].to_s
          desc += "\n\nIgnored: #{a[:ignored]}." if a[:ignored]
          desc += "\n\nWrite-only: sent to NITRO but never compared, NITRO does not return it." if write_only?(c, a)
          behaviour = if parameter?(c, a) then :parameter
                      elsif a[:init_only] then :init_only
                      end
          type = sensitive?(c, a) ? SENSITIVE_TYPE : puppet_type(a)
          attributes[name] = { type: type, desc: desc, behaviour: behaviour }.compact
        end
        {
          name: type_name,
          docs: "@summary #{c[:doc]}\n\nCompatibility type for manifests written for puppetlabs-netscaler. " \
                "It is backed by the `nitro_#{c[:nitro]}` implementation; new code should use `nitro_#{c[:nitro]}`.",
          features: %w[remote_resource canonicalize simple_get_filter],
          attributes: attributes,
        }
      end

      # Attributes Puppet sends but never reads back: old parameters, ignored
      # attributes, and those the nitro_* implementation never compares
      def parameter?(compat, attr)
        attr[:param] || attr[:ignored] || write_only?(compat, attr)
      end

      # The backing nitro_* attribute is a parameter because NITRO does not
      # return it (secrets such as lbmonitor password, update-only triggers).
      # Options of the disable action (delay, graceful) are parameters for
      # another reason and are not write-only.
      def write_only?(compat, attr)
        native = native(compat, attr)
        !native.nil? && native['behaviour'] == 'parameter' && !native['disable_param']
      end

      # Secrets, as declared on the backing nitro_* attribute
      def sensitive?(compat, attr)
        native = native(compat, attr)
        !native.nil? && native['sensitive'] == true
      end

      # The backing nitro_* attribute
      def native(compat, attr)
        return nil if attr[:api].nil?

        SPECS.fetch(compat[:nitro])['attributes'].values.find { |n| n['api'] == attr[:api] }
      end

      def puppet_type(attr)
        case attr[:kind]
        when :truthy then "Optional[Variant[Boolean, Enum[#{TRUTHY_STRINGS.map { |s| "'#{s}'" }.join(', ')}]]]"
        # puppetlabs-netscaler accepted numeric strings ('80')
        when :integer then 'Optional[Variant[Integer, Pattern[/\\A\\d+\\z/]]]'
        # NITRO lists; puppetlabs-netscaler also took a single value (200)
        when :array then 'Optional[Variant[String, Integer, Array[Variant[String, Integer]]]]'
        else 'Optional[String]'
        end
      end

      # A NITRO list in the canonical form of the backing nitro_* attribute.
      # puppetlabs-netscaler also took a single value, and numbers as
      # strings in lists of integers.
      def list(compat, attr, value)
        native = native(compat, attr) || { 'kind' => 'array' }
        items = Array(value).map do |v|
          (native['items'] == 'integer' && v.to_s.match?(%r{\A\d+\z})) ? Integer(v.to_s, 10) : v.to_s
        end
        NitroResource.canonical_list(native, items)
      end

      # NITRO's spelling of an enum value. puppetlabs-netscaler accepted any
      # case, but NITRO enums are not all upper case (RADIUSListener), so the
      # value is matched case-insensitively against the enum of the backing
      # nitro_* attribute. Values outside the enum are upcased, as before.
      def enum(compat, attr, value)
        value = value.to_s
        enum_values(compat, attr)&.find { |v| v.casecmp?(value) } || value.upcase
      end

      # The values of the backing nitro_* attribute's Enum type, nil if it
      # is not an enum
      def enum_values(compat, attr)
        @enum_values ||= {}
        cache_key = [compat[:nitro], attr[:api]]
        return @enum_values[cache_key] if @enum_values.key?(cache_key)

        @enum_values[cache_key] = parse_enum(compat, attr)
      end

      def parse_enum(compat, attr)
        name, = SPECS.fetch(compat[:nitro])['attributes'].find { |_n, a| a['api'] == attr[:api] }
        return nil if name.nil?

        nitro_type = Puppet::Type.type(:"nitro_#{compat[:nitro]}")
        return nil if nitro_type.nil?

        type = nitro_type.type_definition.attributes.dig(name.to_sym, :type)
        return nil if type.nil?

        parsed = Puppet::Pops::Types::TypeParser.singleton.parse(type)
        parsed = parsed.optional_type if parsed.is_a?(Puppet::Pops::Types::POptionalType)
        parsed.is_a?(Puppet::Pops::Types::PEnumType) ? parsed.values.freeze : nil
      end

      # Map any truthy spelling onto the value pair NITRO expects
      def truthy(attr, value)
        return value if value.nil?

        if TRUTHY_TRUE.include?(value.to_s.downcase) then attr[:values][0]
        elsif TRUTHY_FALSE.include?(value.to_s.downcase) then attr[:values][1]
        else value
        end
      end
    end

    # Provider of the netscaler_* compatibility types. Translates the
    # puppetlabs-netscaler attribute names and values to NITRO records and
    # delegates the work to NitroResource.
    class CompatProvider
      include ReturnedValues

      def self.compat
        COMPAT.fetch(compat_type)
      end

      def compat
        self.class.compat
      end

      def nitro
        NitroResource.for(compat[:nitro])
      end

      # names = [] means every resource (see NitroProvider#get). Values that
      # do not fit the type are dropped (see ReturnedValues), also those the
      # from_nitro of a subclass adds.
      def get(context, names = nil)
        names = nil if names && names.empty?
        parents = names&.map { |n| title_keys(n)&.fetch(nitro.key) }&.compact
        nitro.list(context.transport, parents).map { |rec| drop_invalid(context, from_nitro(rec)) }
      end

      def canonicalize(_context, resources)
        resources.each do |r|
          compat[:attributes].each do |name, a|
            next if r[name].nil?

            r[name] = case a[:kind]
                      when :truthy then Compat.truthy(a, r[name])
                      when :upcase then Compat.enum(compat, a, r[name])
                      when :integer then (r[name].is_a?(String) && r[name].match?(%r{\A\d+\z})) ? Integer(r[name], 10) : r[name]
                      when :array then Compat.list(compat, a, r[name])
                      else NitroProvider.conceal(Compat.sensitive?(compat, a), r[name])
                      end
          end
        end
      end

      def set(context, changes)
        changes.each do |title, change|
          is = change[:is] || {}
          should = change[:should]
          warn_ignored(context, title, should)
          client = context.transport
          if should[:ensure].to_s != 'absent' && is[:ensure].to_s != 'present'
            context.creating(title) { create(client, should) }
          elsif should[:ensure].to_s != 'absent'
            context.updating(title) { update(client, is, should) }
          elsif is[:ensure].to_s == 'present'
            context.deleting(title) { nitro.delete(client, to_nitro(is)) }
          else
            next
          end
          ConfigSaver.changed(client)
        end
      end

      def create(client, should)
        nitro.create(client, to_nitro(should))
      end

      def update(client, is, should)
        nitro.update(client, to_nitro(is), to_nitro(should))
      end

      # The NITRO keys encoded in a title
      def title_keys(title)
        title = title[:name] if title.is_a?(Hash)
        return { nitro.key => title } unless compat[:title_pattern]

        m = compat[:title_pattern].match(title.to_s)
        return nil unless m

        m.names.to_h do |n|
          a = nitro.attribute(n)
          [n, (a && a['kind'] == 'integer') ? Integer(m[n], 10) : m[n]]
        end
      end

      def title_for(rec)
        return rec[nitro.key] unless compat[:title_format]

        format(compat[:title_format], **rec.transform_keys(&:to_sym))
      end

      def to_nitro(hash)
        keys = title_keys(hash[:name]) or raise ArgumentError, "#{hash[:name]} does not match #{compat[:title_format]}"
        compat[:attributes].each_with_object(keys) do |(name, a), rec|
          next if a[:ignored] || hash[name].nil?

          rec[a[:api]] = hash[name].respond_to?(:unwrap) ? hash[name].unwrap : hash[name]
        end
      end

      def from_nitro(rec)
        result = { ensure: 'present', name: title_for(rec) }
        compat[:attributes].each do |name, a|
          next if Compat.parameter?(compat, a) || rec[a[:api]].nil?

          value = (a[:kind] == :array) ? Compat.list(compat, a, rec[a[:api]]) : rec[a[:api]]
          result[name] = NitroProvider.conceal(Compat.sensitive?(compat, a), value)
        end
        result
      end

      private

      def warn_ignored(context, title, should)
        compat[:attributes].each do |name, a|
          context.warning(title, "`#{name}` is ignored: #{a[:ignored]}") if a[:ignored] && !should[name].nil?
        end
      end
    end
  end
end
