# frozen_string_literal: true

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
      attr_reader :spec

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
      # and every later lookup, including "does not exist", is answered from
      # that listing. Without it, one GET per requested parent.
      def list(client, parents = nil)
        rows = if parents.nil?
                 fetch_all(client)
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

          h[k] = coerce(a['kind'], v)
        end
        # Some entities (service, lbvserver, ...) only report their runtime
        # state; a disabled entity is always OUT OF SERVICE.
        if spec['state_actions'] && !rec.key?('state') && (runtime = row['svrstate'] || row['curstate'])
          rec['state'] = runtime.to_s.casecmp('OUT OF SERVICE').zero? ? 'DISABLED' : 'ENABLED'
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
        return current.map(&:to_s).sort == desired.map(&:to_s).sort if attr['kind'] == 'array' && current.is_a?(Array) && desired.is_a?(Array)

        current == desired
      end

      def coerce(kind, value)
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
          value.is_a?(Array) ? value : [value]
        else
          value.is_a?(String) ? value : value.to_s
        end
      end
    end
  end
end
