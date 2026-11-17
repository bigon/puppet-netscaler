# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_csvserver_cspolicy_binding
module Puppet::Provider::NetscalerCsvserverCspolicyBinding
  # puppetlabs-netscaler compatible netscaler_csvserver_cspolicy_binding on top of NITRO
  class NetscalerCsvserverCspolicyBinding < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_csvserver_cspolicy_binding'
    end
  end
end
