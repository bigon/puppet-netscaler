# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_servicegroup_lbmonitor_binding
module Puppet::Provider::NetscalerServicegroupLbmonitorBinding
  # puppetlabs-netscaler compatible netscaler_servicegroup_lbmonitor_binding on top of NITRO
  class NetscalerServicegroupLbmonitorBinding < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_servicegroup_lbmonitor_binding'
    end
  end
end
