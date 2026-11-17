# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_service_lbmonitor_binding
module Puppet::Provider::NetscalerServiceLbmonitorBinding
  # puppetlabs-netscaler compatible netscaler_service_lbmonitor_binding on top of NITRO
  class NetscalerServiceLbmonitorBinding < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_service_lbmonitor_binding'
    end
  end
end
