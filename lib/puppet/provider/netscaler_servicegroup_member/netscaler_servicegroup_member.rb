# frozen_string_literal: true

require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_servicegroup_member
module Puppet::Provider::NetscalerServicegroupMember
  # puppetlabs-netscaler compatible netscaler_servicegroup_member on top of NITRO
  class NetscalerServicegroupMember < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_servicegroup_member'
    end
  end
end
