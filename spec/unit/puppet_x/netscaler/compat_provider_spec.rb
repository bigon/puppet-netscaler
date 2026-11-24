# frozen_string_literal: true

require 'spec_helper'
require 'puppet/transport/netscaler'
%w[netscaler_server netscaler_lbvserver netscaler_lbmonitor netscaler_servicegroup_member netscaler_csvserver netscaler_cspolicy
   netscaler_lbvserver_service_binding netscaler_sslvserver netscaler_service].each do |t|
  require "puppet/type/#{t}"
  require "puppet/provider/#{t}/#{t}"
end

describe PuppetX::Netscaler::CompatProvider do
  let(:client) { instance_double(Puppet::Transport::Netscaler, save_config?: false) }
  let(:context) { Puppet::ResourceApi::PuppetContext.new(Puppet::Type.type(type_name).type_definition.definition) }
  let(:provider) { provider_class.new }

  before do
    allow(context).to receive(:transport).and_return(client)
  end

  def change(is, should)
    { should[:name] => { is: is, should: should } }
  end

  describe 'netscaler_lbvserver' do
    let(:type_name) { :netscaler_lbvserver }
    let(:provider_class) { Puppet::Provider::NetscalerLbvserver::NetscalerLbvserver }

    it 'translates NITRO records to the old attribute names' do
      allow(client).to receive(:get).with('lbvserver', 'lb1').and_return(
        'lbvserver' => [{ 'name' => 'lb1', 'servicetype' => 'HTTP', 'ipv46' => '10.0.0.10', 'port' => 80, 'lbmethod' => 'ROUNDROBIN',
                          'curstate' => 'OUT OF SERVICE', 'clttimeout' => '180', 'timeout' => '2', }],
      )
      expect(provider.get(context, ['lb1'])).to eq(
        [{ ensure: 'present', name: 'lb1', service_type: 'HTTP', ip_address: '10.0.0.10', port: 80, lb_method: 'ROUNDROBIN',
           state: 'DISABLED', client_timeout: 180, persistence_timeout: 2, }],
      )
    end

    it 'lists every resource when asked for an empty list of names' do
      allow(client).to receive(:get).with('lbvserver', nil, {}).and_return(
        'lbvserver' => [{ 'name' => 'lb1', 'servicetype' => 'HTTP' }, { 'name' => 'lb2', 'servicetype' => 'SSL' }],
      )
      expect(provider.get(context, []).map { |r| r[:name] }).to eq(%w[lb1 lb2])
    end

    it 'returns canonical values for mixed-case NITRO enums' do
      allow(client).to receive(:get).with('lbvserver', 'lb1').and_return('lbvserver' => [{ 'name' => 'lb1', 'skippersistency' => 'None' }])
      found = provider.get(context, ['lb1'])
      expect(found.first[:skip_persistency]).to eq('None')
      expect(provider.canonicalize(context, found.map(&:dup))).to eq(found)
    end

    it 'creates with NITRO names' do
      expect(client).to receive(:post).with('lbvserver', { 'name' => 'lb1', 'servicetype' => 'HTTP', 'ipv46' => '10.0.0.10', 'port' => 8080, 'state' => 'ENABLED' })
      provider.set(context, change({ ensure: 'absent', name: 'lb1' },
                                   ensure: 'present', name: 'lb1', service_type: 'HTTP', ip_address: '10.0.0.10', port: 8080, state: 'ENABLED'))
    end

    it 'enables/disables via actions' do
      expect(client).to receive(:action).with('lbvserver', 'disable', { 'name' => 'lb1' })
      provider.set(context, change({ ensure: 'present', name: 'lb1', state: 'ENABLED' }, ensure: 'present', name: 'lb1', state: 'DISABLED'))
    end

    it 'warns about and skips attributes NITRO no longer supports' do
      expect(context).to receive(:warning).with('lb1', %r{`sure_connect` is ignored})
      expect(client).to receive(:put).with('lbvserver', { 'name' => 'lb1', 'comment' => 'c' }, 'lb1')
      provider.set(context, change({ ensure: 'present', name: 'lb1' }, ensure: 'present', name: 'lb1', sure_connect: 'ON', comment: 'c'))
    end

    it 'deletes' do
      expect(client).to receive(:delete).with('lbvserver', 'lb1', {})
      provider.set(context, change({ ensure: 'present', name: 'lb1' }, ensure: 'absent', name: 'lb1'))
    end
  end

  describe 'netscaler_lbmonitor' do
    let(:type_name) { :netscaler_lbmonitor }
    let(:provider_class) { Puppet::Provider::NetscalerLbmonitor::NetscalerLbmonitor }

    it 'reports response codes as a sorted list' do
      allow(client).to receive(:get).with('lbmonitor', 'm1').and_return(
        'lbmonitor' => [{ 'monitorname' => 'm1', 'type' => 'HTTP', 'respcode' => %w[301 200] }],
      )
      expect(provider.get(context, ['m1'])).to eq([{ ensure: 'present', name: 'm1', type: 'HTTP', response_codes: %w[200 301] }])
    end

    it 'does not report secrets, even when NITRO returns them encrypted' do
      allow(client).to receive(:get).with('lbmonitor', 'm1').and_return(
        'lbmonitor' => [{ 'monitorname' => 'm1', 'type' => 'MYSQL-ECV', 'username' => 'u', 'password' => 'c2VjcmV0ZW5jcnlwdGVk' }],
      )
      expect(provider.get(context, ['m1'])).to eq([{ ensure: 'present', name: 'm1', type: 'MYSQL-ECV', user_name: 'u' }])
    end

    it 'still sends secrets on create' do
      expect(client).to receive(:post).with('lbmonitor', { 'monitorname' => 'm1', 'type' => 'MYSQL-ECV', 'username' => 'u', 'password' => 'pw' })
      provider.set(context, change(nil, ensure: 'present', name: 'm1', type: 'MYSQL-ECV', user_name: 'u', password: 'pw'))
    end

    it 'reads secrets back as Sensitive values, and wraps the ones it is given' do
      community = Puppet::Pops::Types::PSensitiveType::Sensitive.new('c')
      allow(client).to receive(:get).with('lbmonitor', 'm1').and_return('lbmonitor' => [{ 'monitorname' => 'm1', 'type' => 'SNMP', 'snmpcommunity' => 'c' }])
      expect(provider.get(context, ['m1'])).to eq([{ ensure: 'present', name: 'm1', type: 'SNMP', snmp_community: community }])
      expect(provider.canonicalize(context, [{ name: 'm1', snmp_community: 'c' }])).to eq([{ name: 'm1', snmp_community: community }])
    end

    it 'sends secrets unwrapped' do
      expect(client).to receive(:post).with('lbmonitor', { 'monitorname' => 'm1', 'type' => 'SNMP', 'snmpcommunity' => 'c' })
      provider.set(context, change(nil, ensure: 'present', name: 'm1', type: 'SNMP', snmp_community: Puppet::Pops::Types::PSensitiveType::Sensitive.new('c')))
    end

    it 'sends response codes as a list' do
      expect(client).to receive(:post).with('lbmonitor', { 'monitorname' => 'm1', 'type' => 'HTTP', 'respcode' => ['200'] })
      provider.set(context, change(nil, ensure: 'present', name: 'm1', type: 'HTTP', response_codes: ['200']))
    end
  end

  describe 'netscaler_server' do
    let(:type_name) { :netscaler_server }
    let(:provider_class) { Puppet::Provider::NetscalerServer::NetscalerServer }

    it 'creates IP based servers' do
      expect(client).to receive(:post).with('server', { 'name' => 's1', 'ipaddress' => '2001:db8::1', 'comment' => 'c' })
      provider.set(context, change(nil, ensure: 'present', name: 's1', address: '2001:db8::1', comments: 'c'))
    end

    it 'creates domain based servers' do
      expect(client).to receive(:post).with('server', { 'name' => 's1', 'domain' => 'www.example.com' })
      provider.set(context, change(nil, ensure: 'present', name: 's1', address: 'www.example.com'))
    end

    it 'reports the domain as address' do
      allow(client).to receive(:get).and_return('server' => [{ 'name' => 's1', 'domain' => 'www.example.com', 'ipaddress' => '' },
                                                             { 'name' => 's2', 'ipaddress' => '10.0.0.1', 'domain' => '' },])
      expect(provider.get(context).map { |r| r[:address] }).to eq(['www.example.com', '10.0.0.1'])
    end

    it 'drops values that do not fit the type, also through a subclass' do
      allow(client).to receive(:get).with('server', 's1').and_return('server' => [{ 'name' => 's1', 'domain' => 'www.example.com', 'state' => 'GONE' }])
      expect(context).to receive(:debug).with(%r{ignoring state="GONE" returned by NITRO})
      expect(provider.get(context, ['s1'])).to eq([{ ensure: 'present', name: 's1', address: 'www.example.com' }])
    end

    it 'compares IP addresses in the form NITRO returns, and leaves domains alone' do
      expect(provider.canonicalize(context, [{ name: 's1', address: '2001:DB8:0::1', translation_ip_address: '010.0.0.1' }, { name: 's2', address: 'WWW.example.com' }]))
        .to eq([{ name: 's1', address: '2001:db8::1', translation_ip_address: '10.0.0.1' }, { name: 's2', address: 'WWW.example.com' }])
    end

    it 'refuses to change the domain of a domain based server' do
      expect(context).to receive(:err).with(%r{domain cannot be changed})
      provider.set(context, change({ ensure: 'present', name: 's1', address: 'a.example.com' }, ensure: 'present', name: 's1', address: 'b.example.com'))
    end
  end

  describe 'netscaler_servicegroup_member' do
    let(:type_name) { :netscaler_servicegroup_member }
    let(:provider_class) { Puppet::Provider::NetscalerServicegroupMember::NetscalerServicegroupMember }

    it 'builds titles from the binding keys' do
      allow(client).to receive(:get).with('servicegroup_servicegroupmember_binding', 'sg1').and_return(
        'servicegroup_servicegroupmember_binding' => [{ 'servicegroupname' => 'sg1', 'servername' => 'web1', 'port' => 80, 'weight' => '5', 'state' => 'ENABLED' }],
      )
      expect(provider.get(context, ['sg1/web1:80'])).to eq([{ ensure: 'present', name: 'sg1/web1:80', weight: 5, state: 'ENABLED' }])
    end

    it 'binds members' do
      expect(client).to receive(:put).with('servicegroup_servicegroupmember_binding', { 'servicegroupname' => 'sg1', 'servername' => 'web1', 'port' => 80, 'weight' => 5 })
      provider.set(context, change(nil, ensure: 'present', name: 'sg1/web1:80', weight: 5))
    end

    it 'unbinds members' do
      expect(client).to receive(:delete).with('servicegroup_servicegroupmember_binding', 'sg1', { 'servername' => 'web1', 'port' => 80 })
      provider.set(context, change({ ensure: 'present', name: 'sg1/web1:80' }, ensure: 'absent', name: 'sg1/web1:80'))
    end

    it 'rejects malformed titles' do
      expect(context).to receive(:err).with(%r{garbage does not match})
      provider.set(context, change(nil, ensure: 'present', name: 'garbage'))
    end
  end

  describe 'netscaler_lbvserver_service_binding' do
    let(:type_name) { :netscaler_lbvserver_service_binding }
    let(:provider_class) { Puppet::Provider::NetscalerLbvserverServiceBinding::NetscalerLbvserverServiceBinding }

    it 'lists all bindings in bulk' do
      allow(client).to receive(:get).with('lbvserver_service_binding', nil, { 'bulkbindings' => 'yes' }).and_return(
        'lbvserver_service_binding' => [{ 'name' => 'lb1', 'servicename' => 'svc1', 'weight' => '100' }],
      )
      expect(provider.get(context)).to eq([{ ensure: 'present', name: 'lb1/svc1', weight: 100 }])
    end
  end

  describe 'netscaler_csvserver' do
    let(:type_name) { :netscaler_csvserver }
    let(:provider_class) { Puppet::Provider::NetscalerCsvserver::NetscalerCsvserver }

    it 'reads the default lbvserver from the binding' do
      allow(client).to receive(:get).with('csvserver', 'cs1').and_return('csvserver' => [{ 'name' => 'cs1', 'servicetype' => 'HTTP' }])
      allow(client).to receive(:get).with('csvserver_lbvserver_binding', 'cs1').and_return('csvserver_lbvserver_binding' => [{ 'name' => 'cs1', 'lbvserver' => 'lb1' }])
      expect(provider.get(context, ['cs1'])).to eq([{ ensure: 'present', name: 'cs1', service_type: 'HTTP', default_lbvserver: 'lb1' }])
    end

    [nil, []].each do |names|
      it "reads the default lbvservers of all csvservers from one binding listing when given #{names.inspect}" do
        allow(client).to receive(:get).with('csvserver', nil, {})
                                      .and_return('csvserver' => [{ 'name' => 'cs1', 'servicetype' => 'HTTP' }, { 'name' => 'cs2', 'servicetype' => 'HTTP' }])
        expect(client).to receive(:get).with('csvserver_lbvserver_binding', nil, { 'bulkbindings' => 'yes' }).once
                                       .and_return('csvserver_lbvserver_binding' => [{ 'name' => 'cs1', 'lbvserver' => 'lb1' }])
        expect(provider.get(context, names)).to eq(
          [
            { ensure: 'present', name: 'cs1', service_type: 'HTTP', default_lbvserver: 'lb1' },
            { ensure: 'present', name: 'cs2', service_type: 'HTTP' },
          ],
        )
      end
    end

    it 'drops a state update value the type does not accept' do
      allow(client).to receive(:get).with('csvserver', 'cs1')
                                    .and_return('csvserver' => [{ 'name' => 'cs1', 'servicetype' => 'HTTP', 'stateupdate' => 'UPDATEONBACKENDUPDATE' }])
      allow(client).to receive(:get).with('csvserver_lbvserver_binding', 'cs1').and_return('csvserver_lbvserver_binding' => [{ 'name' => 'cs1', 'lbvserver' => 'lb1' }])
      expect(context).to receive(:debug).with(%r{ignoring state_update="UPDATEONBACKENDUPDATE" returned by NITRO})
      expect(provider.get(context, ['cs1'])).to eq([{ ensure: 'present', name: 'cs1', service_type: 'HTTP', default_lbvserver: 'lb1' }])
    end

    it 'binds the default lbvserver on create' do
      expect(client).to receive(:post).with('csvserver', { 'name' => 'cs1', 'servicetype' => 'HTTP' }).ordered
      expect(client).to receive(:put).with('csvserver_lbvserver_binding', { 'name' => 'cs1', 'lbvserver' => 'lb1' }).ordered
      provider.set(context, change(nil, ensure: 'present', name: 'cs1', service_type: 'HTTP', default_lbvserver: 'lb1'))
    end

    it 'rebinds a changed default lbvserver' do
      expect(client).to receive(:delete).with('csvserver_lbvserver_binding', 'cs1', { 'lbvserver' => 'lb1' }).ordered
      expect(client).to receive(:put).with('csvserver_lbvserver_binding', { 'name' => 'cs1', 'lbvserver' => 'lb2' }).ordered
      provider.set(context, change({ ensure: 'present', name: 'cs1', default_lbvserver: 'lb1' }, ensure: 'present', name: 'cs1', default_lbvserver: 'lb2'))
    end
  end

  describe 'netscaler_cspolicy' do
    let(:type_name) { :netscaler_cspolicy }
    let(:provider_class) { Puppet::Provider::NetscalerCspolicy::NetscalerCspolicy }

    it 'keeps the rule required on update' do
      expect(client).to receive(:put).with('cspolicy', { 'policyname' => 'p', 'rule' => 'true', 'action' => 'a2' }, 'p')
      provider.set(context, change({ ensure: 'present', name: 'p', expression: 'true', action: 'a1' }, ensure: 'present', name: 'p', action: 'a2'))
    end
  end

  describe 'netscaler_sslvserver' do
    let(:type_name) { :netscaler_sslvserver }
    let(:provider_class) { Puppet::Provider::NetscalerSslvserver::NetscalerSslvserver }

    it 'reports the boolean flags NITRO returns' do
      allow(client).to receive(:get).with('sslvserver_sslcertkey_binding', 'vs1')
                                    .and_return('sslvserver_sslcertkey_binding' => [{ 'vservername' => 'vs1', 'certkeyname' => 'ck1', 'ca' => false, 'snicert' => false, 'skipcaname' => false }])
      found = provider.get(context, ['vs1/ck1'])
      expect(found).to eq([{ ensure: 'present', name: 'vs1/ck1', ca: false, snicert: false, skipcaname: false }])
      expect(provider.canonicalize(context, found.map(&:dup))).to eq(found)
      expect(Puppet::Type.type(:netscaler_sslvserver).type_definition.check_schema(found.first)).to be_nil
    end

    it 'sends truthy spellings as NITRO booleans' do
      expect(client).to receive(:put).with('sslvserver_sslcertkey_binding', { 'vservername' => 'vs1', 'certkeyname' => 'ck1', 'ca' => true })
      provider.set(context, change(nil, provider.canonicalize(context, [{ ensure: 'present', name: 'vs1/ck1', ca: 'yes' }]).first))
    end
  end

  describe 'netscaler_service' do
    let(:type_name) { :netscaler_service }
    let(:provider_class) { Puppet::Provider::NetscalerService::NetscalerService }

    it 'keeps the mixed-case spelling of a NITRO enum' do
      allow(client).to receive(:get).with('service', 's1').and_return('service' => [{ 'name' => 's1', 'servicetype' => 'RADIUSListener' }])
      found = provider.get(context, ['s1'])
      expect(found.first[:protocol]).to eq('RADIUSListener')
      expect(provider.canonicalize(context, found.map(&:dup))).to eq(found)
    end

    it 'sends a real cache type' do
      expect(client).to receive(:post).with('service', { 'name' => 's1', 'servername' => 'c1', 'servicetype' => 'HTTP', 'port' => 80, 'cachetype' => 'REVERSE' })
      provider.set(context, change(nil, ensure: 'present', name: 's1', server_name: 'c1', protocol: 'HTTP', port: 80, cache_type: 'REVERSE'))
    end

    it 'sends any case of an enum value in the NITRO spelling' do
      expect(client).to receive(:post).with('service', { 'name' => 's1', 'servicetype' => 'RADIUSListener', 'port' => 1812 })
      provider.set(context, change(nil, provider.canonicalize(context, [{ ensure: 'present', name: 's1', protocol: 'radiuslistener', port: 1812 }]).first))
    end
  end

  describe 'netscaler_servicegroup' do
    let(:type_name) { :netscaler_servicegroup }
    let(:provider_class) { Puppet::Provider::NetscalerServicegroup::NetscalerServicegroup }

    it 'leaves the cache type SERVER out of a create, as puppetlabs-netscaler did' do
      expect(client).to receive(:post).with('servicegroup', { 'servicegroupname' => 'sg1', 'servicetype' => 'HTTP' })
      provider.set(context, change(nil, ensure: 'present', name: 'sg1', protocol: 'HTTP', cache_type: 'SERVER'))
    end
  end
end
