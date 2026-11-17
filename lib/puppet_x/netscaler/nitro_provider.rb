# frozen_string_literal: true

require 'puppet/resource_api'
require_relative 'nitro_resource'

module PuppetX
  module Netscaler
    # Behaviour shared by all providers: save the configuration once the run
    # is over, rather than after each change.
    module ConfigSaver
      module_function

      def changed(transport)
        return unless transport.respond_to?(:save_config?) && transport.save_config?

        @pending ||= {}.compare_by_identity
        first = @pending.empty?
        @pending[transport] = true
        at_exit { flush } if first && !@at_exit_registered
        @at_exit_registered = true
      end

      def pending?(transport)
        (@pending || {}).key?(transport)
      end

      def flush
        (@pending || {}).each_key do |transport|
          transport.save
          Puppet.notice('NetScaler: running configuration saved')
        rescue StandardError => e
          Puppet.err("NetScaler: saving the running configuration failed: #{e.message}")
        end
        @pending = {}.compare_by_identity
      end
    end

    # Base class of the generated nitro_* providers. Puppet attribute names
    # map 1:1 to NITRO names, except the namevar of plain entities which is
    # always `name` in Puppet.
    class NitroProvider
      def self.nitro
        @nitro ||= NitroResource.for(nitro_resource)
      end

      def nitro
        self.class.nitro
      end

      # Resource API asks for every resource with names = [] (simple_get_filter),
      # e.g. `puppet device --resource`: treat it like nil. Resource API 1.9
      # (Debian's ruby-puppet-resource-api) passes [], 2.0 passes nil.
      def get(context, names = nil)
        names = nil if names && names.empty?
        parents = names&.map { |n| parent_of(n) }
        nitro.list(context.transport, parents).map { |rec| to_puppet(context, rec) }
      end

      def set(context, changes)
        changes.each do |title, change|
          is = change[:is] || {}
          should = change[:should]
          # Resource API keeps `should` as the state after the change and
          # strict-checks it on a later lookup, which needs the composite
          # :title (see canonicalize for why it is not there yet)
          add_title(should)
          is_present = nitro.settings? || is[:ensure].to_s == 'present'
          should_present = nitro.settings? || should[:ensure].to_s != 'absent'
          client = context.transport

          if should_present && !is_present
            context.creating(title) { nitro.create(client, to_nitro(should)) }
          elsif should_present
            context.updating(title) { nitro.update(client, to_nitro(is), to_nitro(should)) }
          elsif is_present
            context.deleting(title) { nitro.delete(client, to_nitro(is)) }
          else
            next
          end
          ConfigSaver.changed(client)
        end
      end

      # Puppet attribute name => spec attribute
      def attributes
        nitro.spec['attributes']
      end

      def to_nitro(hash)
        hash.each_with_object({}) do |(k, v), rec|
          a = attributes[k.to_s]
          next if a.nil? || v.nil?

          v = v.unwrap if v.respond_to?(:unwrap)
          v = Integer(v, 10) if a['kind'] == 'integer' && v.is_a?(String) && v.match?(%r{\A-?\d+\z})
          rec[a['api']] = v
        end
      end

      def to_puppet(context, rec)
        result = nitro.settings? ? {} : { ensure: 'present' }
        attributes.each do |name, a|
          next if a['behaviour'] == 'parameter' || !rec.key?(a['api'])

          value = rec[a['api']]
          value = value.to_s if a['behaviour'] == 'namevar'
          next unless valid?(context, name, value)

          result[name.to_sym] = conceal(a, sort_list(a, value))
        end
        add_title(result)
      end

      # NITRO lists (response codes, IP addresses, ...) are unordered sets:
      # sort them so a different order is not reported as a change.
      #
      # Bindings also get their composite :title: Resource API canonicalizes
      # the declared attributes when it builds the resource, and that :title
      # becomes the Puppet title. Without it, a binding whose first namevar is
      # `name` would be titled after that namevar alone (vs1/svc1 and vs1/svc2
      # both become "vs1" and collide in the catalog).
      #
      # Not for the desired state flush compares and passes to set: Resource
      # API (1.9 and 2.0) looks up every key of that hash as a type attribute
      # when it enforces init_only attributes, and crashes on :title
      # (undefined method `[]' for nil). set adds the title afterwards.
      def canonicalize(_context, resources)
        for_flush = flush_target_state?
        resources.each do |r|
          attributes.each do |name, a|
            r[name.to_sym] = conceal(a, sort_list(a, r[name.to_sym])) if r.key?(name.to_sym)
          end
          add_title(r) unless for_flush
        end
      end

      def sort_list(attr, value)
        (attr['kind'] == 'array' && value.is_a?(Array)) ? value.sort_by(&:to_s) : value
      end

      # Secrets stay wrapped on both sides, the desired value (also when the
      # manifest passed a plain String) and the one NITRO returns: Sensitive
      # values compare by content, and are redacted in logs and reports.
      # to_nitro unwraps them.
      def self.conceal(sensitive, value)
        (sensitive && value.is_a?(String)) ? Puppet::Pops::Types::PSensitiveType::Sensitive.new(value) : value
      end

      def conceal(attr, value)
        self.class.conceal(attr['sensitive'], value)
      end

      # Composite namevars: Resource API checks that the title parses back
      # into the same namevars
      def add_title(resource)
        format_string = nitro.spec['title_format']
        return resource unless format_string

        values = nitro.spec['namevars'].to_h do |api|
          name = attributes.find { |_n, a| a['api'] == api }.first.to_sym
          [name, resource[name]]
        end
        resource[:title] = format(format_string, **values) unless values.value?(nil)
        resource
      end

      private

      # Called by Resource API's rsapi_canonicalized_target_state (see canonicalize)
      def flush_target_state?
        caller_locations(2, 3).any? { |l| l.label.to_s.end_with?('rsapi_canonicalized_target_state') }
      end

      def parent_of(name)
        key_attr = attributes.find { |_n, a| a['api'] == nitro.key }.first
        name.is_a?(Hash) ? name[key_attr.to_sym] : name
      end

      # Drop values the appliance returns that do not fit the declared data
      # type (e.g. enum values added in a newer firmware), instead of failing
      # the whole type in strict mode.
      def valid?(context, name, value)
        @types ||= {}
        type = context.type.attributes.dig(name.to_sym, :type)
        return true if type.nil?

        @types[name] ||= Puppet::ResourceApi::DataTypeHandling.parse_puppet_type(name, type)
        err = Puppet::ResourceApi::DataTypeHandling.try_validate(@types[name], value, '')
        context.debug("ignoring #{name}=#{value.inspect} returned by NITRO: #{err}") if err
        err.nil?
      end
    end
  end
end
