# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_sslvserver
module Puppet::Provider::NetscalerSslvserver
  # puppetlabs-netscaler compatible netscaler_sslvserver on top of NITRO
  class NetscalerSslvserver < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_sslvserver'
    end
  end
end
