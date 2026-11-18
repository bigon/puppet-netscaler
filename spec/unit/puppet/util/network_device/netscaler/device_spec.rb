# frozen_string_literal: true

require 'spec_helper'
require 'puppet/transport/netscaler'
require 'puppet/util/network_device/netscaler/device'

describe Puppet::Util::NetworkDevice::Netscaler::Device do
  describe '.legacy_url_to_config' do
    it 'converts the puppetlabs-netscaler device.conf URL' do
      expect(described_class.legacy_url_to_config('https://nsroot:p%40ss@10.1.1.1/nitro/v1/')).to eq(
        host: '10.1.1.1', port: 443, ssl: true, user: 'nsroot', password: 'p@ss',
      )
    end

    it 'keeps a literal + in the user and password' do
      expect(described_class.legacy_url_to_config('https://ns+root:p+ss@ns/nitro/v1/')).to include(user: 'ns+root', password: 'p+ss')
    end

    it 'percent-decodes the user and password' do
      expect(described_class.legacy_url_to_config('https://ns%2Broot:p%2Bs%3As%40@ns/nitro/v1/')).to include(user: 'ns+root', password: 'p+s:s@')
    end

    it 'handles http, custom ports and options' do
      expect(described_class.legacy_url_to_config('http://admin:pw@ns:8080/nitro/v1?ssl_verify=false&save_config=no')).to eq(
        host: 'ns', port: 8080, ssl: false, user: 'admin', password: 'pw', ssl_verify: false, save_config: false,
      )
    end

    it 'accepts prefetch=false' do
      expect(described_class.legacy_url_to_config('https://admin:pw@ns/nitro/v1/?prefetch=false')).to include(prefetch: false)
    end

    it 'leaves file:// URLs and hashes alone' do
      expect(described_class.legacy_url_to_config('file:///etc/puppetlabs/ns.conf')).to eq('file:///etc/puppetlabs/ns.conf')
      expect(described_class.legacy_url_to_config(host: 'x')).to eq(host: 'x')
    end
  end

  it 'connects the netscaler transport from a legacy URL' do
    transport = instance_double(Puppet::Transport::Netscaler)
    expect(Puppet::ResourceApi::Transport).to receive(:connect)
      .with('netscaler', hash_including(host: 'ns.example.com', user: 'nsroot', password: 'pw')).and_return(transport)
    device = described_class.new('https://nsroot:pw@ns.example.com/nitro/v1/')
    expect(device.transport).to eq(transport)
  end
end
