# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'puppet/util/network_device/netscaler/device'

# Full Puppet runs through the Resource API glue (retrieve, strict checks,
# insync?, flush) against a mocked NITRO API: apply once to converge, apply
# again with the converged state and expect no change at all.
describe 'applying netscaler resources', type: :integration do
  let(:base) { 'https://ns.example.com/nitro/v1/config' }
  let(:prefetch) { true }
  let(:device) do
    Puppet::Util::NetworkDevice::Netscaler::Device.new(host: 'ns.example.com', user: 'nsroot', password: 'pw', save_config: false, prefetch: prefetch)
  end

  let(:vardir) { Dir.mktmpdir }

  before do
    Puppet[:vardir] = vardir
    Puppet[:strict] = :error
    allow(Puppet::Util::NetworkDevice).to receive(:current).and_return(device)
  end

  after { FileUtils.rm_rf(vardir) }

  def not_found
    nitro_error(258, 'No such resource', 404)
  end

  # Resource API >= 2.0 would cache get() results on the type class for the
  # whole process; the types opt out of it, so nothing is cleared between runs
  def apply(type, title, params)
    catalog = Puppet::Resource::Catalog.new
    catalog.host_config = false
    resource = Puppet::Type.type(type).new(params.merge(title: title))
    catalog.add_resource(resource)
    report = Puppet.override(network_device: true) { catalog.apply.report }
    failed = report.resource_statuses.values.select(&:failed)
    errors = report.logs.select { |l| %i[err crit alert emerg].include?(l.level) }.map(&:message)
    expect(failed).to be_empty, "failed: #{errors.join("\n")}"
    expect(errors).to be_empty
    report.resource_statuses.values.first
  end

  # Like apply, through a catalog resource so Sensitive values are marked as
  # such, the way the compiler does it; returns the whole report
  def apply_catalog(type, title, params, sensitive)
    catalog = Puppet::Resource::Catalog.new
    catalog.host_config = false
    catalog.add_resource(Puppet::Resource.new(type, title, parameters: params, sensitive_parameters: sensitive).to_ral)
    report = Puppet.override(network_device: true) { catalog.apply.report }
    expect(report.resource_statuses.values.select(&:failed)).to be_empty
    report
  end

  # The GET each mode makes to look up <parent> of <resource>: the whole type
  # with prefetch, the object itself without
  def stub_lookup(resource, parent)
    url = if !prefetch then "#{base}/#{resource}/#{parent}"
          elsif resource.end_with?('_binding') then "#{base}/#{resource}?bulkbindings=yes"
          else "#{base}/#{resource}"
          end
    stub_request(:get, url)
  end

  def no_writes
    expect(a_request(:post, %r{#{base}})).not_to have_been_made
    expect(a_request(:put, %r{#{base}})).not_to have_been_made
    expect(a_request(:delete, %r{#{base}})).not_to have_been_made
  end

  shared_examples 'puppet runs' do
    it 'creates an entity and is idempotent' do
      stub_lookup('server', 'web1').to_return(not_found)
      create = stub_request(:post, "#{base}/server")
               .with(body: { 'server' => { 'name' => 'web1', 'ipaddress' => '10.0.0.1', 'comment' => 'web' } }).to_return(json({}, 201))
      expect(apply(:nitro_server, 'web1', ipaddress: '10.0.0.1', comment: 'web')).to be_changed
      expect(create).to have_been_requested.once

      WebMock.reset!
      stub_lookup('server', 'web1')
        .to_return(json('server' => [{ 'name' => 'web1', 'ipaddress' => '10.0.0.1', 'comment' => 'web', 'state' => 'ENABLED', 'td' => '0' }]))
      expect(apply(:nitro_server, 'web1', ipaddress: '10.0.0.1', comment: 'web')).not_to be_changed
      no_writes
    end

    it 'does not compare attributes NITRO never returns' do
      stub_lookup('service', 'svc1')
        .to_return(json('service' => [{ 'name' => 'svc1', 'servicetype' => 'HTTP', 'port' => 80, 'ipaddress' => '10.0.0.1', 'svrstate' => 'UP' }]))
      status = apply(:nitro_service, 'svc1', ip: '10.0.0.1', servicetype: 'HTTP', port: 80, state: 'ENABLED')
      expect(status).not_to be_changed
      no_writes
    end

    it 'disables an entity with an action' do
      stub_lookup('lbvserver', 'vs1')
        .to_return(json('lbvserver' => [{ 'name' => 'vs1', 'servicetype' => 'HTTP', 'curstate' => 'UP' }]))
      disable = stub_request(:post, "#{base}/lbvserver?action=disable").with(body: { 'lbvserver' => { 'name' => 'vs1' } }).to_return(json({}))
      expect(apply(:nitro_lbvserver, 'vs1', servicetype: 'HTTP', state: 'DISABLED')).to be_changed
      expect(disable).to have_been_requested.once
    end

    it 'refuses to change an init_only attribute' do
      stub_lookup('lbvserver', 'vs1')
        .to_return(json('lbvserver' => [{ 'name' => 'vs1', 'servicetype' => 'HTTP', 'port' => 80 }]))
      catalog = Puppet::Resource::Catalog.new
      catalog.host_config = false
      catalog.add_resource(Puppet::Type.type(:nitro_lbvserver).new(title: 'vs1', servicetype: 'HTTP', port: 8080))
      report = Puppet.override(network_device: true) { catalog.apply.report }
      expect(report.logs.map(&:message).join("\n")).to include('init_only attribute')
      no_writes
    end

    it 'creates a binding and is idempotent' do
      stub_lookup('lbvserver_service_binding', 'vs1').to_return(json({ 'errorcode' => 0 }))
      bind = stub_request(:put, "#{base}/lbvserver_service_binding")
             .with(body: { 'lbvserver_service_binding' => { 'name' => 'vs1', 'servicename' => 'svc1', 'weight' => 10 } }).to_return(json({}, 201))
      expect(apply(:nitro_lbvserver_service_binding, 'vs1/svc1', weight: 10)).to be_changed
      expect(bind).to have_been_requested.once

      WebMock.reset!
      stub_lookup('lbvserver_service_binding', 'vs1')
        .to_return(json('lbvserver_service_binding' => [{ 'name' => 'vs1', 'servicename' => 'svc1', 'weight' => '10', 'curstate' => 'UP' },
                                                        { 'name' => 'vs1', 'servicename' => 'svc2', 'weight' => '1' },]))
      expect(apply(:nitro_lbvserver_service_binding, 'vs1/svc1', weight: 10)).not_to be_changed
      no_writes
    end

    it 'changes an attribute of a binding by binding it again' do
      stub_lookup('lbvserver_service_binding', 'vs1')
        .to_return(json('lbvserver_service_binding' => [{ 'name' => 'vs1', 'servicename' => 'svc1', 'weight' => '5' }]))
      unbind = stub_request(:delete, "#{base}/lbvserver_service_binding/vs1?args=servicename:svc1").to_return(json({}))
      bind = stub_request(:put, "#{base}/lbvserver_service_binding")
             .with(body: { 'lbvserver_service_binding' => { 'name' => 'vs1', 'servicename' => 'svc1', 'weight' => 6 } }).to_return(json({}, 201))
      expect(apply(:nitro_lbvserver_service_binding, 'vs1/svc1', weight: 6)).to be_changed
      expect(unbind).to have_been_requested.once
      expect(bind).to have_been_requested.once
    end

    it 'reads the next device of the same `puppet device` run again' do
      stub_lookup('lbvserver_servicegroup_binding', 'vs1').to_return(json({}))
      bind = stub_request(:put, "#{base}/lbvserver_servicegroup_binding").to_return(json({}, 201))
      expect(apply(:nitro_lbvserver_servicegroup_binding, 'vs1/sg1', weight: 3)).to be_changed

      # same process and type classes, new Device: the binding is still absent there
      other = Puppet::Util::NetworkDevice::Netscaler::Device.new(host: 'ns.example.com', user: 'nsroot', password: 'pw',
                                                                 save_config: false, prefetch: prefetch)
      allow(Puppet::Util::NetworkDevice).to receive(:current).and_return(other)
      expect(apply(:nitro_lbvserver_servicegroup_binding, 'vs1/sg1', weight: 3)).to be_changed
      expect(bind).to have_been_requested.twice
    end

    it 'manages servicegroup members with an integer port in the title' do
      stub_lookup('servicegroup_servicegroupmember_binding', 'sg1').to_return(json({}))
      bind = stub_request(:put, "#{base}/servicegroup_servicegroupmember_binding")
             .with(body: { 'servicegroup_servicegroupmember_binding' => { 'servicegroupname' => 'sg1', 'servername' => '2001:db8::1', 'port' => 80, 'weight' => 5 } })
             .to_return(json({}, 201))
      expect(apply(:nitro_servicegroup_servicegroupmember_binding, 'sg1/2001:db8::1:80', weight: 5)).to be_changed
      expect(bind).to have_been_requested.once

      WebMock.reset!
      stub_lookup('servicegroup_servicegroupmember_binding', 'sg1')
        .to_return(json('servicegroup_servicegroupmember_binding' => [{ 'servicegroupname' => 'sg1', 'servername' => '2001:db8::1', 'ip' => '2001:db8::1', 'port' => 80, 'weight' => '5' }]))
      expect(apply(:nitro_servicegroup_servicegroupmember_binding, 'sg1/2001:db8::1:80', weight: 5)).not_to be_changed
      no_writes
    end

    it 'removes a binding' do
      stub_lookup('service_lbmonitor_binding', 'svc1')
        .to_return(json('service_lbmonitor_binding' => [{ 'name' => 'svc1', 'monitor_name' => 'ping', 'weight' => 1 }]))
      unbind = stub_request(:delete, "#{base}/service_lbmonitor_binding/svc1?args=monitor_name:ping").to_return(json({}))
      expect(apply(:nitro_service_lbmonitor_binding, 'svc1/ping', ensure: 'absent')).to be_changed
      expect(unbind).to have_been_requested.once
    end

    it 'changes a servicegroup member without sending back the IP address NITRO reports' do
      stub_lookup('servicegroup_servicegroupmember_binding', 'sg1')
        .to_return(json('servicegroup_servicegroupmember_binding' => [{ 'servicegroupname' => 'sg1', 'servername' => 'web1', 'ip' => '10.0.0.1', 'port' => 80,
                                                                        'weight' => '5', 'state' => 'ENABLED', 'customserverid' => 'None', }]))
      unbind = stub_request(:delete, "#{base}/servicegroup_servicegroupmember_binding/sg1?args=servername:web1,port:80").to_return(json({}))
      bind = stub_request(:put, "#{base}/servicegroup_servicegroupmember_binding")
             .with(body: { 'servicegroup_servicegroupmember_binding' => { 'servicegroupname' => 'sg1', 'servername' => 'web1', 'port' => 80, 'weight' => 6,
                                                                          'state' => 'ENABLED', 'customserverid' => 'None', } })
             .to_return(json({}, 201))
      expect(apply(:nitro_servicegroup_servicegroupmember_binding, 'sg1/web1:80', weight: 6)).to be_changed
      expect(unbind).to have_been_requested.once
      expect(bind).to have_been_requested.once
    end

    it 'changes the notification period of a certificate together with its expiry monitor' do
      stub_lookup('sslcertkey', 'ck1').to_return(json('sslcertkey' => [{ 'certkey' => 'ck1', 'cert' => 'ck1.pem', 'expirymonitor' => 'ENABLED', 'notificationperiod' => 30 }]))
      update = stub_request(:put, "#{base}/sslcertkey/ck1")
               .with(body: { 'sslcertkey' => { 'certkey' => 'ck1', 'notificationperiod' => 20, 'expirymonitor' => 'ENABLED' } }).to_return(json({}))
      expect(apply(:nitro_sslcertkey, 'ck1', notificationperiod: 20)).to be_changed
      expect(update).to have_been_requested.once
    end

    { nitro_lbmonitor: 'm1', netscaler_lbmonitor: 'm1' }.each do |type, title|
      it "removes a monitor with #{type}, passing its type" do
        stub_lookup('lbmonitor', 'm1').to_return(json('lbmonitor' => [{ 'monitorname' => 'm1', 'type' => 'HTTP' }]))
        remove = stub_request(:delete, "#{base}/lbmonitor/m1?args=type:HTTP").to_return(json({}))
        expect(apply(type, title, ensure: 'absent')).to be_changed
        expect(remove).to have_been_requested.once
      end
    end

    { nitro_lbmonitor: :snmpcommunity, netscaler_lbmonitor: :snmp_community }.each do |type, community|
      [[:Sensitive, [community, :password]], [:plain, []]].each do |how, sensitive|
        it "redacts the secrets of #{type} given as #{how} values, and is idempotent" do
          stub_lookup('lbmonitor', 'm1').to_return(json('lbmonitor' => [{ 'monitorname' => 'm1', 'type' => 'SNMP', 'snmpcommunity' => 'oldsecret' }]))
          update = stub_request(:put, "#{base}/lbmonitor/m1")
                   .with(body: { 'lbmonitor' => { 'monitorname' => 'm1', 'type' => 'SNMP', 'snmpcommunity' => 'newsecret' } }).to_return(json({}))
          params = { type: 'SNMP', community => 'newsecret', password: 'newpass' }
          report = apply_catalog(type, 'm1', params, sensitive)
          expect(update).to have_been_requested.once
          events = report.resource_statuses.values.flat_map(&:events)
          expect(events.map(&:redacted)).to eq([true])
          reported = JSON.generate(events.map(&:to_data_hash)) + report.logs.map(&:message).join("\n")
          expect(reported).not_to match(%r{oldsecret|newsecret|newpass})
          expect(report.logs.map(&:message)).not_to include(%r{Unable to mark})

          WebMock.reset!
          stub_lookup('lbmonitor', 'm1').to_return(json('lbmonitor' => [{ 'monitorname' => 'm1', 'type' => 'SNMP', 'snmpcommunity' => 'newsecret' }]))
          expect(apply_catalog(type, 'm1', params, sensitive).resource_statuses.values.first).not_to be_changed
          no_writes
        end
      end
    end

    %w[sslvserver_sslciphersuite_binding].each do |resource|
      it "binds a cipher group with nitro_#{resource} and is idempotent" do
        stub_lookup(resource, 'ssl_vs1').to_return(json({}))
        bind = stub_request(:put, "#{base}/#{resource}")
               .with(body: { resource => { 'vservername' => 'ssl_vs1', 'ciphername' => 'CUSTOM-CIPHERS' } }).to_return(json({}, 201))
        expect(apply(:"nitro_#{resource}", 'ssl_vs1/CUSTOM-CIPHERS', {})).to be_changed
        expect(bind).to have_been_requested.once

        WebMock.reset!
        stub_lookup(resource, 'ssl_vs1')
          .to_return(json(resource => [{ 'vservername' => 'ssl_vs1', 'ciphername' => 'CUSTOM-CIPHERS', 'description' => 'x' }]))
        expect(apply(:"nitro_#{resource}", 'ssl_vs1/CUSTOM-CIPHERS', {})).not_to be_changed
        no_writes
      end

      it "unbinds the DEFAULT cipher group with nitro_#{resource}" do
        stub_lookup(resource, 'ssl_vs1')
          .to_return(json(resource => [{ 'vservername' => 'ssl_vs1', 'ciphername' => 'DEFAULT' }]))
        unbind = stub_request(:delete, "#{base}/#{resource}/ssl_vs1?args=ciphername:DEFAULT").to_return(json({}))
        expect(apply(:"nitro_#{resource}", 'ssl_vs1/DEFAULT', ensure: 'absent')).to be_changed
        expect(unbind).to have_been_requested.once
      end
    end

    it 'updates a settings entity and is idempotent' do
      stub_lookup('sslvserver', 'vs1').to_return(json('sslvserver' => [{ 'vservername' => 'vs1', 'tls1' => 'ENABLED', 'tls13' => 'DISABLED' }]))
      update = stub_request(:put, "#{base}/sslvserver/vs1")
               .with(body: { 'sslvserver' => { 'vservername' => 'vs1', 'tls1' => 'DISABLED', 'tls13' => 'ENABLED' } }).to_return(json({}))
      expect(apply(:nitro_sslvserver, 'vs1', tls1: 'DISABLED', tls13: 'ENABLED')).to be_changed
      expect(update).to have_been_requested.once

      WebMock.reset!
      stub_lookup('sslvserver', 'vs1').to_return(json('sslvserver' => [{ 'vservername' => 'vs1', 'tls1' => 'DISABLED', 'tls13' => 'ENABLED' }]))
      expect(apply(:nitro_sslvserver, 'vs1', tls1: 'DISABLED', tls13: 'ENABLED')).not_to be_changed
      no_writes
    end

    it 'runs a puppetlabs-netscaler manifest and is idempotent' do
      params = { service_type: 'http', ip_address: '10.0.0.10', port: '8080', state: true, lb_method: 'roundrobin' }
      stub_lookup('lbvserver', 'lb1').to_return(not_found)
      create = stub_request(:post, "#{base}/lbvserver")
               .with(body: { 'lbvserver' => { 'name' => 'lb1', 'servicetype' => 'HTTP', 'ipv46' => '10.0.0.10', 'port' => 8080, 'state' => 'ENABLED', 'lbmethod' => 'ROUNDROBIN' } })
               .to_return(json({}, 201))
      expect(apply(:netscaler_lbvserver, 'lb1', params)).to be_changed
      expect(create).to have_been_requested.once

      WebMock.reset!
      stub_lookup('lbvserver', 'lb1')
        .to_return(json('lbvserver' => [{ 'name' => 'lb1', 'servicetype' => 'HTTP', 'ipv46' => '10.0.0.10', 'port' => 8080, 'curstate' => 'UP', 'lbmethod' => 'ROUNDROBIN' }]))
      expect(apply(:netscaler_lbvserver, 'lb1', params)).not_to be_changed
      no_writes
    end

    it 'ignores a value NITRO returns that the compat type does not accept' do
      stub_lookup('csvserver', 'cs1')
        .to_return(json('csvserver' => [{ 'name' => 'cs1', 'servicetype' => 'HTTP', 'stateupdate' => 'UPDATEONBACKENDUPDATE', 'curstate' => 'UP' }]))
      stub_lookup('csvserver_lbvserver_binding', 'cs1').to_return(json({ 'errorcode' => 0 }))
      expect(apply(:netscaler_csvserver, 'cs1', service_type: 'HTTP')).not_to be_changed
      no_writes
    end

    it 'manages a monitor declared with puppetlabs-netscaler style values' do
      params = { type: 'HTTP', http_request: 'GET /app/status', response_codes: 200, destination_port: '8080', secure: 'NO' }
      stub_lookup('lbmonitor', 'probe_app').to_return(not_found)
      create = stub_request(:post, "#{base}/lbmonitor")
               .with(body: { 'lbmonitor' => { 'monitorname' => 'probe_app', 'type' => 'HTTP', 'httprequest' => 'GET /app/status',
                                              'respcode' => ['200'], 'destport' => 8080, 'secure' => 'NO', } })
               .to_return(json({}, 201))
      expect(apply(:netscaler_lbmonitor, 'probe_app', params)).to be_changed
      expect(create).to have_been_requested.once

      WebMock.reset!
      stub_lookup('lbmonitor', 'probe_app')
        .to_return(json('lbmonitor' => [{ 'monitorname' => 'probe_app', 'type' => 'HTTP', 'httprequest' => 'GET /app/status',
                                          'respcode' => ['200'], 'destport' => 8080, 'secure' => 'NO', }]))
      expect(apply(:netscaler_lbmonitor, 'probe_app', params)).not_to be_changed
      no_writes
    end

    it 'ignores the order of NITRO lists' do
      stub_lookup('lbmonitor', 'probe_web')
        .to_return(json('lbmonitor' => [{ 'monitorname' => 'probe_web', 'type' => 'HTTP', 'respcode' => %w[200 301 302] }]))
      expect(apply(:nitro_lbmonitor, 'probe_web', type: 'HTTP', respcode: %w[302 200 301])).not_to be_changed
      no_writes
    end

    # NITRO returns lists of integers as strings
    { nitro_lbmonitor: :acctapplicationid, netscaler_lbmonitor: :account_application_ids }.each do |type, attr|
      it "compares the integer lists of #{type} with what NITRO returns" do
        stub_lookup('lbmonitor', 'probe_dia')
          .to_return(json('lbmonitor' => [{ 'monitorname' => 'probe_dia', 'type' => 'DIAMETER', 'acctapplicationid' => %w[3 10] }]))
        expect(apply(type, 'probe_dia', type: 'DIAMETER', attr => [10, 3])).not_to be_changed
        no_writes
      end
    end

    { nitro_lbmonitor: { acctapplicationid: [10, 3] }, netscaler_lbmonitor: { account_application_ids: %w[10 3] } }.each do |type, list|
      it "sends the integer lists of #{type} as numbers" do
        stub_lookup('lbmonitor', 'probe_dia')
          .to_return(json('lbmonitor' => [{ 'monitorname' => 'probe_dia', 'type' => 'DIAMETER', 'acctapplicationid' => %w[3] }]))
        update = stub_request(:put, "#{base}/lbmonitor/probe_dia")
                 .with(body: { 'lbmonitor' => { 'monitorname' => 'probe_dia', 'type' => 'DIAMETER', 'acctapplicationid' => [3, 10] } }).to_return(json({}))
        expect(apply(type, 'probe_dia', type: 'DIAMETER', **list)).to be_changed
        expect(update).to have_been_requested
      end
    end

    # persistavpno lists nested AVP numbers from parent to child
    { nitro_lbvserver: :persistavpno, netscaler_lbvserver: :persist_avp_no }.each do |type, attr|
      it "keeps the order of the ordered lists of #{type}" do
        stub_lookup('lbvserver', 'vs_dia')
          .to_return(json('lbvserver' => [{ 'name' => 'vs_dia', 'servicetype' => 'DIAMETER', 'persistavpno' => %w[5 300] }]))
        update = stub_request(:put, "#{base}/lbvserver/vs_dia")
                 .with(body: { 'lbvserver' => { 'name' => 'vs_dia', 'persistavpno' => [300, 5] } }).to_return(json({}))
        expect(apply(type, 'vs_dia', attr => [300, 5])).to be_changed
        expect(update).to have_been_requested
      end
    end

    it 'does not rewrite a MYSQL-ECV monitor password on every run' do
      params = { type: 'MYSQL-ECV', user_name: 'monitor', password: 'pw', database: 'app', sql_query: 'select 1', destination_port: '3306' }
      stub_lookup('lbmonitor', 'probe_db')
        .to_return(json('lbmonitor' => [{ 'monitorname' => 'probe_db', 'type' => 'MYSQL-ECV', 'username' => 'monitor', 'password' => 'ZW5jcnlwdGVk',
                                          'database' => 'app', 'sqlquery' => 'select 1', 'destport' => 3306, }]))
      expect(apply(:netscaler_lbmonitor, 'probe_db', params)).not_to be_changed
      no_writes
    end

    it 'runs a puppetlabs-netscaler binding manifest idempotently' do
      stub_lookup('servicegroup_servicegroupmember_binding', 'sg1')
        .to_return(json('servicegroup_servicegroupmember_binding' => [{ 'servicegroupname' => 'sg1', 'servername' => 'web1', 'port' => 80, 'weight' => '5', 'state' => 'ENABLED' }]))
      expect(apply(:netscaler_servicegroup_member, 'sg1/web1:80', weight: '5', state: 'yes')).not_to be_changed
      no_writes
    end
  end

  context 'with prefetch (default)' do
    it_behaves_like 'puppet runs'

    def apply_all(resources)
      catalog = Puppet::Resource::Catalog.new
      catalog.host_config = false
      resources.each do |type, title, params|
        catalog.add_resource(Puppet::Type.type(type).new(params.merge(title: title)))
      end
      report = Puppet.override(network_device: true) { catalog.apply.report }
      expect(report.resource_statuses.values.select(&:failed)).to be_empty
      report
    end

    it 'keeps the composite title of bindings declared through a catalog' do
      catalog = Puppet::Resource::Catalog.new
      %w[svc1 svc2].each do |svc|
        catalog.add_resource(Puppet::Resource.new(:nitro_lbvserver_service_binding, "vs1/#{svc}", parameters: { weight: 1 }))
      end
      ral = catalog.to_ral
      expect(ral.resources.map(&:ref)).to contain_exactly('Nitro_lbvserver_service_binding[vs1/svc1]', 'Nitro_lbvserver_service_binding[vs1/svc2]')
    end

    it 'lists each type once per run, whatever the number of resources' do
      servers = stub_request(:get, "#{base}/server")
                .to_return(json('server' => (1..3).map { |i| { 'name' => "web#{i}", 'ipaddress' => "10.0.0.#{i}" } }))
      bindings = stub_request(:get, "#{base}/lbvserver_service_binding?bulkbindings=yes")
                 .to_return(json('lbvserver_service_binding' => [{ 'name' => 'vs1', 'servicename' => 'svc1', 'weight' => '1' },
                                                                 { 'name' => 'vs2', 'servicename' => 'svc2', 'weight' => '1' },]))
      report = apply_all([[:nitro_server, 'web1', { ipaddress: '10.0.0.1' }],
                          [:nitro_server, 'web2', { ipaddress: '10.0.0.2' }],
                          [:nitro_server, 'web3', { ipaddress: '10.0.0.3' }],
                          [:nitro_lbvserver_service_binding, 'vs1/svc1', { weight: 1 }],
                          [:nitro_lbvserver_service_binding, 'vs2/svc2', { weight: 1 }],])
      expect(report.resource_statuses.values.count(&:changed)).to eq(0)
      expect(servers).to have_been_requested.once
      expect(bindings).to have_been_requested.once
      no_writes
    end

    it 'answers "does not exist yet" from the listing' do
      servers = stub_request(:get, "#{base}/server").to_return(json('server' => [{ 'name' => 'web1', 'ipaddress' => '10.0.0.1' }]))
      stub_request(:post, "#{base}/server").to_return(json({}, 201))
      apply_all([[:nitro_server, 'new1', { ipaddress: '10.0.0.8' }], [:nitro_server, 'new2', { ipaddress: '10.0.0.9' }]])
      expect(a_request(:get, %r{#{base}/server/})).not_to have_been_made
      # each creation makes the listing stale: listed again for the next lookup
      expect(servers).to have_been_requested.twice
    end

    it 'lists the bindings again after deleting the entity they belong to' do
      stub_request(:get, "#{base}/lbvserver").to_return(json('lbvserver' => [{ 'name' => 'vs1', 'servicetype' => 'HTTP' }]))
      bindings = stub_request(:get, "#{base}/lbvserver_service_binding?bulkbindings=yes")
                 .to_return(json('lbvserver_service_binding' => [{ 'name' => 'vs1', 'servicename' => 'svc1', 'weight' => '1' },
                                                                 { 'name' => 'vs2', 'servicename' => 'svc2', 'weight' => '1' },]))
                 .then.to_return(json('lbvserver_service_binding' => [{ 'name' => 'vs2', 'servicename' => 'svc2', 'weight' => '1' }]))
      remove = stub_request(:delete, "#{base}/lbvserver/vs1").to_return(json({}))
      # vs2/svc2 lists the bindings before vs1 goes; NITRO removes the bindings of vs1 with it
      apply_all([[:nitro_lbvserver_service_binding, 'vs2/svc2', { weight: 1 }],
                 [:nitro_lbvserver, 'vs1', { ensure: 'absent' }],
                 [:nitro_lbvserver_service_binding, 'vs1/svc1', { ensure: 'absent' }],])
      expect(remove).to have_been_requested.once
      expect(bindings).to have_been_requested.twice
      expect(a_request(:delete, %r{lbvserver_service_binding})).not_to have_been_made
    end

    it 'falls back to one GET per object when the NITRO user may not list the type' do
      stub_request(:get, "#{base}/server").to_return(nitro_error(1, 'Not authorized', 403))
      one = stub_request(:get, "#{base}/server/web1").to_return(json('server' => [{ 'name' => 'web1', 'ipaddress' => '10.0.0.1' }]))
      apply_all([[:nitro_server, 'web1', { ipaddress: '10.0.0.1' }]])
      expect(one).to have_been_requested.once
      no_writes
    end
  end

  context 'without prefetch' do
    let(:prefetch) { false }

    it_behaves_like 'puppet runs'
  end
end
