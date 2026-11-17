# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_sslcertkey
module Puppet::Provider::NetscalerSslcertkey
  # puppetlabs-netscaler compatible netscaler_sslcertkey on top of NITRO
  class NetscalerSslcertkey < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_sslcertkey'
    end
  end
end
