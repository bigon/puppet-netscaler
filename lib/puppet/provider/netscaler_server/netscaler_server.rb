# frozen_string_literal: true

require 'ipaddr'
require_relative '../../../puppet_x/netscaler/compat_provider'

# Provider for netscaler_server
module Puppet::Provider::NetscalerServer
  # puppetlabs-netscaler compatible netscaler_server. `address` is either an
  # IP address (NITRO `ipaddress`) or a domain name (NITRO `domain`).
  class NetscalerServer < PuppetX::Netscaler::CompatProvider
    def self.compat_type
      'netscaler_server'
    end

    def self.ip?(value)
      IPAddr.new(value.to_s)
      true
    rescue IPAddr::Error
      false
    end

    def to_nitro(hash)
      rec = super
      address = rec.delete('ipaddress')
      return rec if address.nil?

      if self.class.ip?(address)
        rec['ipaddress'] = address
      else
        rec['domain'] = address
      end
      rec
    end

    def from_nitro(rec)
      result = super
      domain = rec['domain'].to_s
      result[:address] = domain unless domain.empty?
      result
    end
  end
end
