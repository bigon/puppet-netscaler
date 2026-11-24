# frozen_string_literal: true

require 'ipaddr'
require_relative 'specs'
require_relative '../../puppet/transport/netscaler'

module PuppetX
  module Netscaler
    # CRUD logic for one NITRO resource, driven by its generated spec.
    #
    # Records are Hashes keyed by NITRO attribute names (Strings). Only
    # attributes present in the desired record are managed: nothing is unset
    # behind the user's back.
    class NitroResource
      # Runtime states (svrstate/curstate) of a disabled entity, including
      # the transition of a graceful or delayed disable: reading those as
      # ENABLED would send the disable again, which can restart the delay.
      DISABLED_RUNTIME_STATES = [
        'OUT OF SERVICE', 'GOING OUT OF SERVICE', 'DOWN WHEN GOING OUT OF SERVICE', 'DISABLED',
      ].freeze

      attr_reader :spec

      # NITRO lists are sets, compared and sent sorted (numbers by value,
      # anything else as text), unless the attribute is ordered
      def self.canonical_list(attr, value)
        return value unless attr['kind'] == 'array' && value.is_a?(Array) && !attr['ordered']

        value.sort_by { |v| v.is_a?(Numeric) ? [0, v, ''] : [1, 0, v.to_s] }
      end

      # The value in the form compared with what NITRO returns: IP
      # addresses normalised (see canonical_ip) when the attribute holds
      # them, lists sorted (see canonical_list)
      def self.canonical(attr, value)
        value = canonical_ip(value) if attr['ip_address']
        canonical_list(attr, value)
      end

      IPV4 = %r{\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z}.freeze
      IPV6 = %r{\A[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*\z}.freeze

      # An IP address in the form NITRO returns it: IPv6 compressed and in
      # lower case (2001:DB8:0::1 => 2001:db8::1), IPv4 without leading
      # zeros, which NITRO reads as decimal (010.0.0.1 => 10.0.0.1). The
      # address is the same, so both forms are accepted by NITRO, but only
      # the canonical one compares equal to what it returns. Anything else
      # (domain names, '*', prefixes, zone ids) is returned untouched.
      def self.canonical_ip(value)
        return value.map { |v| canonical_ip(v) } if value.is_a?(Array)
        return value unless value.is_a?(String)

        if (m = IPV4.match(value))
          octets = m.captures.map { |o| Integer(o, 10) }
          return (octets.all? { |o| o <= 255 }) ? octets.join('.') : value
        end
        return value unless value.match?(IPV6)

        IPAddr.new(value).to_s
      rescue IPAddr::Error
        value
      end

      def self.for(resource)
        @cache ||= {}
        @cache[resource] ||= new(SPECS.fetch(resource))
      end

      def initialize(spec)
        @spec = spec
        @by_api = spec['attributes'].values.to_h { |a| [a['api'], a] }
      end

      def resource
        spec['resource']
      end

      def key
        spec['key']
      end

      def kind
        spec['kind']
      end

      def binding?
        kind == 'binding'
      end

      def settings?
        kind == 'settings'
      end

      def attribute(api)
        @by_api[api]
      end

      # Fetch records. `parents` restricts the lookup to those values of the
      # URL key (entity names, or bound-to entity for bindings).
      #
      # With prefetch (the default), the whole type is fetched once per run
      # and every later lookup, including "does not exist" and a full
      # listing, is answered from that listing. Without it, one GET per
      # requested parent.
      def list(client, parents = nil)
        rows = if parents.nil?
                 prefetched(client) || fetch_all(client)
               elsif (all = prefetched(client))
                 wanted = parents.compact.map(&:to_s)
                 all.select { |row| wanted.include?(row[key].to_s) }
               else
                 parents.compact.uniq.flat_map { |p| extract(client.get(resource, p)) }
               end
        rows.map { |row| normalize(row) }
      end

      def find(client, keys)
        list(client, [keys[key]]).find { |rec| spec['namevars'].all? { |nv| rec[nv] == keys[nv] } }
      end

      def create(client, rec)
        create_record(client, rec)
      ensure
        forget(client)
      end

      def update(client, is, should)
        update_record(client, is, should)
      ensure
        forget(client)
      end

      def delete(client, rec)
        delete_record(client, rec)
      ensure
        forget(client)
        dependents.each { |dependent| dependent.forget(client) }
      end

      # The resources that reference this one (from their autorequires), e.g.
      # the bindings of an lbvserver: deleting an object may remove or change
      # their rows on the appliance, so their listings are stale too
      def dependents
        @dependents ||= SPECS.filter_map do |name, s|
          NitroResource.for(name) if name != resource && s['autorequire'].key?("nitro_#{resource}")
        end
      end

      def create_record(client, rec)
        return update_record(client, {}, rec) if settings?

        if binding?
          client.put(resource, rec.select { |k, v| attribute(k) && !v.nil? })
          return
        end

        missing = spec['create_required'].reject { |k| rec.key?(k) }
        raise ArgumentError, "#{resource} #{rec[key]}: missing required attribute(s) #{missing.join(', ')}" unless missing.empty?

        payload = rec.select { |k, v| !v.nil? && attribute(k)&.fetch('create') }
        client.post(resource, payload)

        action_attrs = spec['action_updates'].values.flatten
        later = rec.select do |k, v|
          a = attribute(k)
          !v.nil? && a && !a['create'] && a['update'] && !a['disable_param'] && !action_attrs.include?(k) && a['behaviour'] != 'parameter'
        end
        later = later.except('state') if spec['state_actions']
        put(client, rec, {}, later) unless later.empty?
        set_state(client, rec) if spec['state_actions'] && rec['state'] && !attribute('state')['create']
        # Attributes only settable through an action (e.g. sslcertkey link)
        spec['action_updates'].each do |action, attrs|
          pending = attrs.select { |a| !rec[a].nil? && !attribute(a)['create'] && attribute(a)['behaviour'] != 'parameter' }
          client.action(resource, action, { key => rec[key] }.merge(rec.slice(*pending))) unless pending.empty?
        end
      end

      def update_record(client, is, should)
        changed = changes(is, should)
        return if changed.empty?

        if binding?
          # NITRO bindings cannot be modified in place: unbind and bind again,
          # keeping the current attributes except those NITRO refuses on a bind
          delete_record(client, is)
          create_record(client, is.except(*spec['rebind_exclude']).merge(should).select { |k, _| attribute(k) })
          return
        end

        if spec['state_actions'] && changed.key?('state')
          set_state(client, should)
          changed.delete('state')
        end

        spec['action_updates'].each do |action, attrs|
          next unless attrs.any? { |a| changed.key?(a) }

          payload = { key => should[key] }.merge(should.slice(*attrs).compact)
          client.action(resource, action, payload)
          attrs.each { |a| changed.delete(a) }
        end

        frozen = changed.keys.reject { |k| attribute(k)['update'] }
        raise ArgumentError, "#{resource} #{should[key]}: #{frozen.join(', ')} cannot be changed after creation (recreate the resource)" unless frozen.empty?

        put(client, should, is, with_companions(changed, is, should)) unless changed.empty?
      end

      def delete_record(client, rec)
        raise ArgumentError, "#{resource} cannot be deleted" if settings?

        args = spec['delete_args'].each_with_object({}) { |a, h| h[a] = rec[a] unless rec[a].nil? }
        client.delete(resource, rec[key], args)
      end

      # Attributes NITRO only accepts together with others (update_with): add
      # those, at their desired value or else the current one
      def with_companions(changed, is, should)
        spec['update_with'].each_with_object(changed.dup) do |(attr, companions), attrs|
          next unless changed.key?(attr)

          companions.each { |c| attrs[c] = should[c].nil? ? is[c] : should[c] unless attrs.key?(c) }
        end
      end

      # Managed attributes whose desired value differs from the current one
      def changes(is, should)
        should.select do |k, v|
          a = attribute(k)
          next false if a.nil? || v.nil? || k == key || spec['namevars'].include?(k)
          next false if a['behaviour'] == 'parameter' || a['disable_param']

          !same?(a, is[k], v)
        end
      end

      def normalize(row)
        rec = row.each_with_object({}) do |(k, v), h|
          a = attribute(k)
          next if a.nil? || v.nil?

          h[k] = coerce(a['kind'], v, a['items'])
        end
        # Some entities (service, lbvserver, ...) only report their runtime
        # state, from which the configured one is derived.
        if spec['state_actions'] && !rec.key?('state') && (runtime = row['svrstate'] || row['curstate'])
          rec['state'] = DISABLED_RUNTIME_STATES.include?(runtime.to_s.upcase) ? 'DISABLED' : 'ENABLED'
        end
        rec
      end

      private

      # create/update/delete without invalidating the per-run listing
      private :create_record, :update_record, :delete_record, :with_companions

      def fetch_all(client)
        query = binding? ? { 'bulkbindings' => 'yes' } : {}
        extract(client.get(resource, nil, query))
      end

      # The per-run listing of this type, or nil when prefetch is disabled or
      # the NITRO user may not list the whole type (then: one GET per object)
      def prefetched(client)
        return nil unless client.respond_to?(:prefetch?) && client.prefetch?

        client.snapshot(resource) do
          fetch_all(client)
        rescue Puppet::Transport::Netscaler::Error => e
          Puppet.debug("NetScaler: cannot list #{resource} (#{e.message}), fetching objects one by one")
          nil
        end
      end

      # Puppet changed this type: the listing is stale
      def forget(client)
        client.invalidate(resource) if client.respond_to?(:invalidate)
      end
      # called on the dependents of a deleted resource
      protected :forget

      def extract(body)
        return [] if body.nil?

        Array(body[resource])
      end

      def put(client, should, is, attrs)
        payload = { key => should[key] }
        spec['update_required'].each do |r|
          payload[r] = should.key?(r) ? should[r] : is[r]
        end
        client.put(resource, payload.merge(attrs).compact, should[key])
      end

      def set_state(client, rec)
        if rec['state'] == 'DISABLED'
          params = rec.select { |k, v| !v.nil? && attribute(k)&.fetch('disable_param') }
          client.action(resource, 'disable', { key => rec[key] }.merge(params))
        else
          client.action(resource, 'enable', { key => rec[key] })
        end
      end

      def same?(attr, current, desired)
        return false if current.nil?

        if attr['kind'] == 'array' && current.is_a?(Array) && desired.is_a?(Array)
          # as text: compat lists may hold strings where NITRO has numbers
          current, desired = [current, desired].map { |list| attr['ordered'] ? list.map(&:to_s) : list.map(&:to_s).sort }
        end

        current == desired
      end

      # NITRO returns numbers and booleans as strings, also inside lists
      # (acctapplicationid => ["3", "1"])
      def coerce(kind, value, items = nil)
        case kind
        when 'integer'
          (value.is_a?(String) && value.match?(%r{\A-?\d+\z})) ? Integer(value, 10) : value
        when 'number'
          (value.is_a?(String) && value.match?(%r{\A-?\d+(\.\d+)?\z})) ? Float(value) : value
        when 'boolean'
          case value.to_s.downcase
          when 'true', 'yes' then true
          when 'false', 'no' then false
          else value
          end
        when 'array'
          list = value.is_a?(Array) ? value : [value]
          items ? list.map { |v| coerce(items, v) } : list
        else
          value.is_a?(String) ? value : value.to_s
        end
      end
    end
  end
end
