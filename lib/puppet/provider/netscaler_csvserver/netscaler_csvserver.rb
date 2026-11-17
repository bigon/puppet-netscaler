# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_csvserver
module Puppet::Provider::NetscalerCsvserver
  # puppetlabs-netscaler compatible netscaler_csvserver. `default_lbvserver` is
  # managed as a csvserver_lbvserver_binding.
  class NetscalerCsvserver < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_csvserver'
    end

    def binding
      PuppetX::Netscaler::NitroResource.for('csvserver_lbvserver_binding')
    end

    def get(context, names = nil)
      resources = super
      return resources if resources.empty?

      parents = names.nil? ? nil : resources.map { |r| r[:name] }
      defaults = binding.list(context.transport, parents).to_h { |b| [b['name'], b['lbvserver']] }
      resources.each do |r|
        r[:default_lbvserver] = defaults[r[:name]] if defaults[r[:name]]
      end
    end

    def to_nitro(hash)
      super.tap { |rec| rec.delete('defaultlbvserver') }
    end

    def create(client, should)
      super
      bind(client, should[:name], should[:default_lbvserver]) if should[:default_lbvserver]
    end

    def update(client, is, should)
      super
      return if should[:default_lbvserver].nil? || should[:default_lbvserver] == is[:default_lbvserver]

      binding.delete(client, 'name' => is[:name], 'lbvserver' => is[:default_lbvserver]) if is[:default_lbvserver]
      bind(client, should[:name], should[:default_lbvserver])
    end

    private

    def bind(client, vserver, lbvserver)
      binding.create(client, 'name' => vserver, 'lbvserver' => lbvserver)
    end
  end
end
