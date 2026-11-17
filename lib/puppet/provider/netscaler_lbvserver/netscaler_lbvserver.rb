# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_lbvserver
module Puppet::Provider::NetscalerLbvserver
  # puppetlabs-netscaler compatible netscaler_lbvserver on top of NITRO
  class NetscalerLbvserver < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_lbvserver'
    end
  end
end
