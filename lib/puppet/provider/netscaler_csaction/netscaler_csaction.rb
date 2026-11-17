# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_csaction
module Puppet::Provider::NetscalerCsaction
  # puppetlabs-netscaler compatible netscaler_csaction on top of NITRO
  class NetscalerCsaction < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_csaction'
    end
  end
end
