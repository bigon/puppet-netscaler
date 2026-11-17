# frozen_string_literal: true

require 'uri'
require 'puppet/util/network_device'
require 'puppet/resource_api/transport/wrapper'
require_relative '../../../transport/schema/netscaler'

module Puppet::Util::NetworkDevice::Netscaler
  # `puppet device` entry point (device.conf: `type netscaler`).
  #
  # Accepts the Resource API style `url file:///path/to/credentials.conf`
  # (HOCON/JSON with the transport connection_info keys), and, for
  # compatibility with puppetlabs-netscaler, the legacy
  # `url https://user:password@host[:port]/nitro/v1/` form.
  class Device < Puppet::ResourceApi::Transport::Wrapper
    def initialize(url_or_config, _options = {})
      super('netscaler', self.class.legacy_url_to_config(url_or_config))
    end

    def self.legacy_url_to_config(url_or_config)
      return url_or_config unless url_or_config.is_a?(String) && url_or_config.match?(%r{\Ahttps?://}i)

      uri = URI.parse(url_or_config)
      query = URI.decode_www_form(uri.query.to_s).to_h
      config = {
        host: uri.host,
        port: uri.port,
        ssl: uri.scheme.casecmp('https').zero?,
        user: URI.decode_www_form_component(uri.user.to_s),
        password: URI.decode_www_form_component(uri.password.to_s),
      }
      %w[ssl_verify save_config prefetch].each do |option|
        config[option.to_sym] = !%w[false no 0].include?(query[option].to_s.downcase) if query.key?(option)
      end
      config
    end
  end
end
