# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_cspolicy
module Puppet::Provider::NetscalerCspolicy
  # puppetlabs-netscaler compatible netscaler_cspolicy on top of NITRO
  class NetscalerCspolicy < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_cspolicy'
    end
  end
end
