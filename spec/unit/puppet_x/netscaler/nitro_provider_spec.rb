# frozen_string_literal: true

require 'spec_helper'
require 'puppet/transport/netscaler'
require 'puppet/type/nitro_server'
require 'puppet/type/nitro_servicegroup_servicegroupmember_binding'
require 'puppet/type/nitro_sslvserver'
require 'puppet/provider/nitro_server/nitro_server'
require 'puppet/provider/nitro_servicegroup_servicegroupmember_binding/nitro_servicegroup_servicegroupmember_binding'
require 'puppet/provider/nitro_sslvserver/nitro_sslvserver'

# End-to-end: provider -> NitroResource -> transport -> HTTP (webmock)
describe PuppetX::Netscaler::NitroProvider do
  let(:base) { 'https://ns/nitro/v1/config' }
  let(:transport) { Puppet::Transport::Netscaler.new(nil, host: 'ns', user: 'u', password: 'p', save_config: false, prefetch: false) }
  let(:type) { Puppet::Type.type(type_name) }
  let(:context) { Puppet::ResourceApi::PuppetContext.new(type.type_definition.definition) }
  let(:provider) { provider_class.new }

  before do
    allow(context).to receive(:transport).and_return(transport)
  end

  def json(body, status = 200)
    { status: status, body: JSON.generate(body) }
  end

  context 'with nitro_server' do
    let(:type_name) { :nitro_server }
    let(:provider_class) { Puppet::Provider::NitroServer::NitroServer }

    it 'returns NITRO entities as resources' do
      stub_request(:get, "#{base}/server").to_return(json('server' => [
                                                            { 'name' => 'web1', 'ipaddress' => '10.0.0.1', 'state' => 'ENABLED', 'td' => '0', 'ipv6address' => 'NO', 'statechangetimesec' => 'Mon' },
                                                          ]))
      expect(provider.get(context)).to eq([{ ensure: 'present', name: 'web1', ipaddress: '10.0.0.1', state: 'ENABLED', td: 0, ipv6address: 'NO' }])
    end

    it 'lists every resource when asked for an empty list of names' do
      prefetching = Puppet::Transport::Netscaler.new(nil, host: 'ns', user: 'u', password: 'p', save_config: false)
      allow(context).to receive(:transport).and_return(prefetching)
      stub_request(:get, "#{base}/server").to_return(json('server' => [{ 'name' => 'web1' }, { 'name' => 'web2' }]))
      expect(provider.get(context, [])).to eq([{ ensure: 'present', name: 'web1' }, { ensure: 'present', name: 'web2' }])
    end

    it 'lists every resource when asked for an empty list of names without prefetch' do
      stub_request(:get, "#{base}/server").to_return(json('server' => [{ 'name' => 'web1' }]))
      expect(provider.get(context, [])).to eq([{ ensure: 'present', name: 'web1' }])
    end

    it 'fetches only the requested names' do
      stub_request(:get, "#{base}/server/web1").to_return(json('server' => [{ 'name' => 'web1' }]))
      stub_request(:get, "#{base}/server/web2").to_return(json({ 'errorcode' => 258, 'message' => 'No such resource', 'severity' => 'ERROR' }, 404))
      expect(provider.get(context, %w[web1 web2])).to eq([{ ensure: 'present', name: 'web1' }])
    end

    it 'answers lookups from one listing per type with prefetch' do
      prefetching = Puppet::Transport::Netscaler.new(nil, host: 'ns', user: 'u', password: 'p', save_config: false)
      allow(context).to receive(:transport).and_return(prefetching)
      all = stub_request(:get, "#{base}/server").to_return(json('server' => [{ 'name' => 'web1' }, { 'name' => 'web2' }]))
      expect(provider.get(context, ['web1'])).to eq([{ ensure: 'present', name: 'web1' }])
      expect(provider.get(context, ['web2'])).to eq([{ ensure: 'present', name: 'web2' }])
      expect(provider.get(context, ['missing'])).to eq([])
      expect(all).to have_been_requested.once
    end

    it 'drops values that do not match the declared type' do
      stub_request(:get, "#{base}/server").to_return(json('server' => [{ 'name' => 'web1', 'querytype' => 'NEWTYPE' }]))
      expect(provider.get(context)).to eq([{ ensure: 'present', name: 'web1' }])
    end

    it 'creates' do
      stub = stub_request(:post, "#{base}/server").with(body: { 'server' => { 'name' => 'web1', 'ipaddress' => '10.0.0.1' } }).to_return(json({}, 201))
      provider.set(context, 'web1' => { is: { name: 'web1', ensure: 'absent' }, should: { name: 'web1', ensure: 'present', ipaddress: '10.0.0.1' } })
      expect(stub).to have_been_requested
    end

    it 'updates' do
      stub = stub_request(:put, "#{base}/server/web1").with(body: { 'server' => { 'name' => 'web1', 'comment' => 'hi' } }).to_return(json({}))
      provider.set(context, 'web1' => { is: { name: 'web1', ensure: 'present', comment: 'old' }, should: { name: 'web1', ensure: 'present', comment: 'hi' } })
      expect(stub).to have_been_requested
    end

    it 'deletes' do
      stub = stub_request(:delete, "#{base}/server/web1").to_return(json({}))
      provider.set(context, 'web1' => { is: { name: 'web1', ensure: 'present' }, should: { name: 'web1', ensure: 'absent' } })
      expect(stub).to have_been_requested
    end

    it 'does nothing for absent resources that should be absent' do
      provider.set(context, 'web1' => { is: nil, should: { name: 'web1', ensure: 'absent' } })
    end

    it 'reports NITRO errors through the context' do
      stub_request(:post, "#{base}/server").to_return(json({ 'errorcode' => 273, 'message' => 'Resource already exists', 'severity' => 'ERROR' }, 409))
      expect(context).to receive(:err).with(%r{Resource already exists})
      provider.set(context, 'web1' => { is: nil, should: { name: 'web1', ensure: 'present', ipaddress: '10.0.0.1' } })
      expect(context).to be_failed
    end

    it 'saves the configuration once at the end when enabled' do
      t = Puppet::Transport::Netscaler.new(nil, host: 'ns', user: 'u', password: 'p')
      allow(context).to receive(:transport).and_return(t)
      stub_request(:post, "#{base}/server").to_return(json({}, 201))
      save = stub_request(:post, "#{base}/nsconfig?action=save").to_return(json({}))
      allow(PuppetX::Netscaler::ConfigSaver).to receive(:at_exit)
      provider.set(context, 'a' => { is: nil, should: { name: 'a', ensure: 'present', ipaddress: '10.0.0.1' } },
                            'b' => { is: nil, should: { name: 'b', ensure: 'present', ipaddress: '10.0.0.2' } })
      expect(PuppetX::Netscaler::ConfigSaver).to be_pending(t)
      PuppetX::Netscaler::ConfigSaver.flush
      expect(save).to have_been_requested.once
      expect(PuppetX::Netscaler::ConfigSaver).not_to be_pending(t)
    end

    it 'does not save when disabled' do
      stub_request(:delete, "#{base}/server/a").to_return(json({}))
      provider.set(context, 'a' => { is: { name: 'a', ensure: 'present' }, should: { name: 'a', ensure: 'absent' } })
      expect(PuppetX::Netscaler::ConfigSaver).not_to be_pending(transport)
    end
  end

  context 'with nitro_lbmonitor' do
    let(:type_name) { :nitro_lbmonitor }
    let(:provider_class) { Puppet::Provider::NitroLbmonitor::NitroLbmonitor }

    it 'sorts NITRO lists it reads' do
      stub_request(:get, "#{base}/lbmonitor/m1").to_return(json('lbmonitor' => [{ 'monitorname' => 'm1', 'type' => 'HTTP', 'respcode' => %w[301 200] }]))
      expect(provider.get(context, ['m1'])).to eq([{ ensure: 'present', name: 'm1', type: 'HTTP', respcode: %w[200 301] }])
    end

    it 'sorts NITRO lists it is given' do
      expect(provider.canonicalize(context, [{ name: 'm1', respcode: %w[301 200], interval: 5 }]))
        .to eq([{ name: 'm1', respcode: %w[200 301], interval: 5 }])
    end

    def sensitive(value)
      Puppet::Pops::Types::PSensitiveType::Sensitive.new(value)
    end

    it 'reads secrets back as Sensitive values' do
      stub_request(:get, "#{base}/lbmonitor/m1").to_return(json('lbmonitor' => [{ 'monitorname' => 'm1', 'type' => 'SNMP', 'snmpcommunity' => 'c' }]))
      expect(provider.get(context, ['m1'])).to eq([{ ensure: 'present', name: 'm1', type: 'SNMP', snmpcommunity: sensitive('c') }])
    end

    it 'wraps the secrets it is given in Sensitive, once' do
      once = provider.canonicalize(context, [{ name: 'm1', snmpcommunity: 'c', password: sensitive('p') }])
      expect(once).to eq([{ name: 'm1', snmpcommunity: sensitive('c'), password: sensitive('p') }])
      expect(provider.canonicalize(context, once.map(&:dup))).to eq(once)
    end

    it 'sends the secrets unwrapped' do
      stub_request(:post, "#{base}/lbmonitor")
        .with(body: { 'lbmonitor' => { 'monitorname' => 'm1', 'type' => 'SNMP', 'snmpcommunity' => 'c', 'password' => 'p' } }).to_return(json({}, 201))
      provider.set(context, 'm1' => { is: nil, should: { ensure: 'present', name: 'm1', type: 'SNMP', snmpcommunity: sensitive('c'), password: sensitive('p') } })
      expect(a_request(:post, "#{base}/lbmonitor")).to have_been_made.once
    end
  end

  context 'with a binding with an integer namevar' do
    let(:type_name) { :nitro_servicegroup_servicegroupmember_binding }
    let(:provider_class) { Puppet::Provider::NitroServicegroupServicegroupmemberBinding::NitroServicegroupServicegroupmemberBinding }

    it 'looks up the bound-to entity and stringifies namevars' do
      stub_request(:get, "#{base}/servicegroup_servicegroupmember_binding/sg1")
        .to_return(json('servicegroup_servicegroupmember_binding' => [{ 'servicegroupname' => 'sg1', 'servername' => 'web1', 'port' => 80, 'weight' => '2' }]))
      expect(provider.get(context, [{ servicegroupname: 'sg1', servername: 'web1', port: '80' }])).to eq(
        [{ ensure: 'present', servicegroupname: 'sg1', servername: 'web1', port: '80', weight: 2, title: 'sg1/web1:80' }],
      )
    end

    it 'sends the port as an integer' do
      stub = stub_request(:put, "#{base}/servicegroup_servicegroupmember_binding")
             .with(body: { 'servicegroup_servicegroupmember_binding' => { 'servicegroupname' => 'sg1', 'servername' => 'web1', 'port' => 80, 'weight' => 3 } })
             .to_return(json({}))
      provider.set(context, { servicegroupname: 'sg1', servername: 'web1', port: '80' } => {
                     is: nil, should: { ensure: 'present', servicegroupname: 'sg1', servername: 'web1', port: '80', weight: 3 },
                   })
      expect(stub).to have_been_requested
    end
  end

  context 'with a binding' do
    let(:type_name) { :nitro_servicegroup_servicegroupmember_binding }
    let(:provider_class) { Puppet::Provider::NitroServicegroupServicegroupmemberBinding::NitroServicegroupServicegroupmemberBinding }

    it 'canonicalizes declared resources with their composite title' do
      expect(provider.canonicalize(context, [{ servicegroupname: 'sg1', servername: 'web1', port: '80', weight: 1 }]))
        .to eq([{ servicegroupname: 'sg1', servername: 'web1', port: '80', weight: 1, title: 'sg1/web1:80' }])
    end

    it 'does not add the title to the desired state Resource API flushes' do
      allow(provider).to receive(:flush_target_state?).and_return(true)
      expect(provider.canonicalize(context, [{ servicegroupname: 'sg1', servername: 'web1', port: '80', weight: 1 }]))
        .to eq([{ servicegroupname: 'sg1', servername: 'web1', port: '80', weight: 1 }])
    end

    it 'adds the composite title to the state it reached' do
      stub_request(:put, "#{base}/servicegroup_servicegroupmember_binding").to_return(json({}, 201))
      should = { ensure: 'present', servicegroupname: 'sg1', servername: 'web1', port: 80, weight: 1 }
      provider.set(context, { servicegroupname: 'sg1', servername: 'web1', port: 80 } => { is: nil, should: should })
      expect(should[:title]).to eq('sg1/web1:80')
    end

    it 'leaves incomplete resources alone' do
      expect(provider.canonicalize(context, [{ servicegroupname: 'sg1' }])).to eq([{ servicegroupname: 'sg1' }])
    end
  end

  context 'with a settings entity' do
    let(:type_name) { :nitro_sslvserver }
    let(:provider_class) { Puppet::Provider::NitroSslvserver::NitroSslvserver }

    it 'has no ensure' do
      stub_request(:get, "#{base}/sslvserver/vs").to_return(json('sslvserver' => [{ 'vservername' => 'vs', 'tls1' => 'ENABLED' }]))
      expect(provider.get(context, ['vs'])).to eq([{ name: 'vs', tls1: 'ENABLED' }])
    end

    it 'updates with a PUT' do
      stub = stub_request(:put, "#{base}/sslvserver/vs").with(body: { 'sslvserver' => { 'vservername' => 'vs', 'tls1' => 'DISABLED' } }).to_return(json({}))
      provider.set(context, 'vs' => { is: { name: 'vs', tls1: 'ENABLED' }, should: { name: 'vs', tls1: 'DISABLED' } })
      expect(stub).to have_been_requested
    end
  end
end
