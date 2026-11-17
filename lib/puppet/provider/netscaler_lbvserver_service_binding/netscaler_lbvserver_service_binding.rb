# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_lbvserver_service_binding
module Puppet::Provider::NetscalerLbvserverServiceBinding
  # puppetlabs-netscaler compatible netscaler_lbvserver_service_binding on top of NITRO
  class NetscalerLbvserverServiceBinding < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_lbvserver_service_binding'
    end
  end
end
