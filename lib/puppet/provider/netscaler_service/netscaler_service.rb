# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_service
module Puppet::Provider::NetscalerService
  # puppetlabs-netscaler compatible netscaler_service on top of NITRO
  class NetscalerService < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_service'
    end
  end
end
