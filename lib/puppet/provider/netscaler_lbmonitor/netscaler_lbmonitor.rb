# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_lbmonitor
module Puppet::Provider::NetscalerLbmonitor
  # puppetlabs-netscaler compatible netscaler_lbmonitor on top of NITRO
  class NetscalerLbmonitor < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_lbmonitor'
    end
  end
end
