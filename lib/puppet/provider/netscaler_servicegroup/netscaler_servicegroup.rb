# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_servicegroup
module Puppet::Provider::NetscalerServicegroup
  # puppetlabs-netscaler compatible netscaler_servicegroup on top of NITRO
  class NetscalerServicegroup < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_servicegroup'
    end
  end
end
