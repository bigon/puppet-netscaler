# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_lbvserver_servicegroup_binding
module Puppet::Provider::NetscalerLbvserverServicegroupBinding
  # puppetlabs-netscaler compatible netscaler_lbvserver_servicegroup_binding on top of NITRO
  class NetscalerLbvserverServicegroupBinding < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_lbvserver_servicegroup_binding'
    end
  end
end
