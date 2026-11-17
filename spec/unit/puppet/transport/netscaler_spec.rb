# frozen_string_literal: true

require 'spec_helper'
require 'puppet/transport/netscaler'

describe Puppet::Transport::Netscaler do
  subject(:transport) { described_class.new(nil, connection_info) }

  let(:base) { 'https://ns.example.com/nitro/v1/config' }
  let(:password) { Puppet::Pops::Types::PSensitiveType::Sensitive.new('s3cr3t') }
  let(:connection_info) { { host: 'ns.example.com', user: 'nsroot', password: password } }
  let(:auth_headers) { { 'X-NITRO-USER' => 'nsroot', 'X-NITRO-PASS' => 's3cr3t' } }

  def json(body, status = 200)
    { status: status, body: JSON.generate(body), headers: { 'Content-Type' => 'application/json' } }
  end

  describe 'defaults' do
    it 'uses HTTPS on port 443' do
      expect(transport.port).to eq(443)
    end

    it 'uses port 80 without SSL' do
      expect(described_class.new(nil, connection_info.merge(ssl: false)).port).to eq(80)
    end

    it 'saves the configuration by default' do
      expect(transport.save_config?).to be(true)
    end

    it 'prefetches by default' do
      expect(transport.prefetch?).to be(true)
      expect(described_class.new(nil, connection_info.merge(prefetch: false)).prefetch?).to be(false)
    end
  end

  describe '#snapshot' do
    it 'computes a listing once per connection' do
      calls = 0
      2.times { transport.snapshot('server') { calls += 1 } }
      expect(calls).to eq(1)
    end

    it 'remembers failed listings (nil) too' do
      calls = 0
      2.times do
        transport.snapshot('server') do
          calls += 1
          nil
        end
      end
      expect(calls).to eq(1)
    end

    it 'recomputes after invalidate' do
      calls = 0
      transport.snapshot('server') { calls += 1 }
      transport.invalidate('server')
      transport.snapshot('server') { calls += 1 }
      expect(calls).to eq(2)
    end
  end

  describe '#get' do
    it 'authenticates with the X-NITRO headers and unwraps the sensitive password' do
      stub = stub_request(:get, "#{base}/server/web1").with(headers: auth_headers)
                                                      .to_return(json('errorcode' => 0, 'server' => [{ 'name' => 'web1' }]))
      expect(transport.get('server', 'web1')).to include('server' => [{ 'name' => 'web1' }])
      expect(stub).to have_been_requested
    end

    it 'url-encodes the entity name' do
      stub = stub_request(:get, "#{base}/server/my%20server%2Fx").to_return(json('server' => []))
      transport.get('server', 'my server/x')
      expect(stub).to have_been_requested
    end

    it 'passes query parameters' do
      stub = stub_request(:get, "#{base}/lbvserver_service_binding?bulkbindings=yes").to_return(json({}))
      transport.get('lbvserver_service_binding', nil, 'bulkbindings' => 'yes')
      expect(stub).to have_been_requested
    end

    it 'returns nil on HTTP 404' do
      stub_request(:get, "#{base}/server/nope")
        .to_return(json({ 'errorcode' => 258, 'message' => 'No such resource [name, nope]', 'severity' => 'ERROR' }, 404))
      expect(transport.get('server', 'nope')).to be_nil
    end

    it 'returns nil on a "no such resource" error code' do
      stub_request(:get, "#{base}/server/nope")
        .to_return(json({ 'errorcode' => 258, 'message' => 'No such resource', 'severity' => 'ERROR' }, 599))
      expect(transport.get('server', 'nope')).to be_nil
    end

    it 'raises on other errors' do
      stub_request(:get, "#{base}/server")
        .to_return(json({ 'errorcode' => 354, 'message' => 'Invalid username or password', 'severity' => 'ERROR' }, 401))
      expect { transport.get('server') }.to raise_error(described_class::Error, %r{HTTP 401, errorcode 354\): Invalid username or password}) { |e|
        expect(e.errorcode).to eq(354)
        expect(e.status).to eq(401)
      }
    end

    it 'handles non JSON error bodies' do
      stub_request(:get, "#{base}/server").to_return(status: 502, body: 'Bad Gateway')
      expect { transport.get('server') }.to raise_error(described_class::Error, %r{Bad Gateway})
    end
  end

  describe 'write operations' do
    it 'POSTs the payload wrapped in the resource name' do
      stub = stub_request(:post, "#{base}/server")
             .with(body: { 'server' => { 'name' => 'web1', 'ipaddress' => '10.0.0.1' } }, headers: auth_headers.merge('Content-Type' => 'application/json'))
             .to_return(json({ 'errorcode' => 0 }, 201))
      transport.post('server', 'name' => 'web1', 'ipaddress' => '10.0.0.1')
      expect(stub).to have_been_requested
    end

    it 'raises when NITRO reports an error' do
      stub_request(:post, "#{base}/server")
        .to_return(json({ 'errorcode' => 273, 'message' => 'Resource already exists', 'severity' => 'ERROR' }, 409))
      expect { transport.post('server', 'name' => 'web1') }.to raise_error(described_class::Error, %r{Resource already exists})
    end

    it 'PUTs updates to the entity URL' do
      stub = stub_request(:put, "#{base}/server/web1").with(body: { 'server' => { 'name' => 'web1', 'comment' => 'x' } }).to_return(json({}))
      transport.put('server', { 'name' => 'web1', 'comment' => 'x' }, 'web1')
      expect(stub).to have_been_requested
    end

    it 'PUTs bindings to the collection URL' do
      stub = stub_request(:put, "#{base}/lbvserver_service_binding").to_return(json({}))
      transport.put('lbvserver_service_binding', 'name' => 'vs', 'servicename' => 'svc')
      expect(stub).to have_been_requested
    end

    it 'DELETEs with NITRO args' do
      stub = stub_request(:delete, "#{base}/servicegroup_servicegroupmember_binding/sg1?args=servername:web%201,port:80").to_return(json({}))
      transport.delete('servicegroup_servicegroupmember_binding', 'sg1', 'servername' => 'web 1', 'port' => 80)
      expect(stub).to have_been_requested
    end

    it 'runs actions' do
      stub = stub_request(:post, "#{base}/server?action=disable").with(body: { 'server' => { 'name' => 'web1' } }).to_return(json({}))
      transport.action('server', 'disable', 'name' => 'web1')
      expect(stub).to have_been_requested
    end

    it 'saves the configuration' do
      stub = stub_request(:post, "#{base}/nsconfig?action=save").with(body: { 'nsconfig' => {} }).to_return(json({}))
      transport.save
      expect(stub).to have_been_requested
    end
  end

  describe '#verify' do
    it 'succeeds when the API answers' do
      stub_request(:get, "#{base}/nsversion").to_return(json('nsversion' => { 'version' => 'NS14.1' }))
      expect(transport.verify(nil)).to be(true)
    end

    it 'fails on bad credentials' do
      stub_request(:get, "#{base}/nsversion").to_return(json({ 'errorcode' => 354, 'message' => 'Invalid username or password' }, 401))
      expect { transport.verify(nil) }.to raise_error(described_class::Error)
    end
  end

  describe '#facts' do
    let(:stat) { 'https://ns.example.com/nitro/v1/stat' }

    def stub_facts(hardware: json('nshardware' => [{ 'hwdescription' => 'NetScaler Virtual Appliance', 'serialno' => 'ABC' }]))
      stub_request(:get, "#{base}/nsversion")
        .to_return(json('nsversion' => { 'installedversion' => false, 'version' => 'NetScaler NS14.1: Build 73.58.nc, Date: Oct  4 2025, 10:10:10   (64-bit)' }))
      stub_request(:get, "#{base}/nshostname").to_return(json('nshostname' => [{ 'hostname' => 'ns01' }]))
      stub_request(:get, "#{base}/nshardware").to_return(hardware)
      stub_request(:get, "#{base}/nsconfig").to_return(json('nsconfig' => {
                                                              'ipaddress' => '10.0.0.5', 'netmask' => '255.255.255.0', 'systemtype' => 'Stand-alone',
                                                              'primaryip' => '10.0.0.5', 'timezone' => 'CoordinatedUniversalTime', 'lastconfigchangedtime' => 'Mon Nov 17 10:00:00 2026',
                                                              'lastconfigsavetime' => 'Mon Nov 17 09:00:00 2026', 'systemtime' => 1_763_373_600,
                                                            }))
      stub_request(:get, "#{stat}/ns").to_return(json('ns' => { 'cpuusage' => '3', 'memuseinmb' => '1024', 'numcpus' => '2', 'starttime' => 'Mon Nov 10 08:00:00 2026' }))
      stub_request(:get, "#{base}/Interface")
        .to_return(json('Interface' => [{ 'id' => 'LO/1', 'mac' => '00:00:00:00:00:00' }, { 'id' => '0/1', 'mac' => '52:54:00:12:34:56' }]))
    end

    it 'reports Puppet 8 structured facts' do
      stub_facts
      expect(transport.facts(nil)).to include(
        'os' => { 'name' => 'NetScaler', 'family' => 'NetScaler', 'release' => { 'full' => '14.1-73.58', 'major' => '14', 'minor' => '1' } },
        'networking' => { 'hostname' => 'ns01', 'ip' => '10.0.0.5', 'netmask' => '255.255.255.0', 'mac' => '52:54:00:12:34:56' },
        'netscaler' => {
          'version' => 'NetScaler NS14.1: Build 73.58.nc, Date: Oct  4 2025, 10:10:10   (64-bit)',
          'hardware' => 'NetScaler Virtual Appliance', 'serialnumber' => 'ABC', 'systemtype' => 'Stand-alone',
          'primaryip' => '10.0.0.5', 'timezone' => 'CoordinatedUniversalTime',
        },
      )
    end

    it 'reports the flat facts of puppetlabs-netscaler, with its spelling' do
      stub_facts
      facts = transport.facts(nil)
      expect(facts).to include(
        'operatingsystem' => 'Netscaler', 'version' => %r{\ANetScaler NS14\.1}, 'macaddress' => '52:54:00:12:34:56',
        'ipaddress' => '10.0.0.5', 'netmask' => '255.255.255.0', 'systemtype' => 'Stand-alone', 'primaryip' => '10.0.0.5',
        'timezone' => 'CoordinatedUniversalTime', 'lastconfigchangedtime' => 'Mon Nov 17 10:00:00 2026',
        'lastconfigsavetime' => 'Mon Nov 17 09:00:00 2026', 'systemtime' => 1_763_373_600,
        'cpuusage' => '3', 'memuseinmb' => '1024', 'numcpus' => '2', 'starttime' => 'Mon Nov 10 08:00:00 2026'
      )
    end

    it 'reports no facts beyond upstream puppetlabs-netscaler' do
      stub_facts
      expect(transport.facts(nil).keys).not_to include('osfamily', 'operatingsystemmajrelease', 'operatingsystemrelease', 'role')
    end

    it 'tolerates sources the NITRO user cannot read' do
      stub_facts(hardware: json({ 'errorcode' => 1, 'message' => 'Not authorized', 'severity' => 'ERROR' }, 403))
      stub_request(:get, "#{stat}/ns").to_return(json({ 'errorcode' => 1, 'message' => 'Not authorized', 'severity' => 'ERROR' }, 403))
      facts = transport.facts(nil)
      expect(facts['netscaler']).not_to include('hardware', 'serialnumber')
      expect(facts).not_to include('cpuusage')
      expect(facts).to include('operatingsystem' => 'Netscaler', 'ipaddress' => '10.0.0.5')
    end

    it 'fails when the appliance cannot be queried at all' do
      stub_request(:get, "#{base}/nsversion").to_return(json({ 'errorcode' => 354, 'message' => 'Invalid username or password', 'severity' => 'ERROR' }, 401))
      expect { transport.facts(nil) }.to raise_error(described_class::Error)
    end
  end

  describe '.parse_release' do
    it 'parses NITRO version strings' do
      expect(described_class.parse_release('NetScaler NS13.1: Build 58.21.nc, Date: May  5 2025')).to eq('full' => '13.1-58.21', 'major' => '13', 'minor' => '1')
    end

    it 'returns nil for unknown formats' do
      expect(described_class.parse_release('something else')).to be_nil
    end
  end

  describe 'TLS' do
    it 'verifies certificates by default' do
      http = instance_double(Net::HTTP, started?: true)
      allow(Net::HTTP).to receive(:new).with('ns.example.com', 443).and_return(http)
      expect(http).to receive(:use_ssl=).with(true)
      expect(http).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER)
      allow(http).to receive_messages(:open_timeout= => nil, :read_timeout= => nil, start: http)
      allow(http).to receive(:request).and_return(instance_double(Net::HTTPOK, body: '{}', code: '200', message: 'OK'))
      transport.get('nsversion')
    end

    it 'can skip verification and use a CA file' do
      t = described_class.new(nil, connection_info.merge(ssl_verify: false, ca_file: '/etc/ca.pem'))
      http = instance_double(Net::HTTP, started?: true)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      expect(http).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_NONE)
      expect(http).to receive(:ca_file=).with('/etc/ca.pem')
      allow(http).to receive_messages(:open_timeout= => nil, :read_timeout= => nil, start: http)
      allow(http).to receive(:request).and_return(instance_double(Net::HTTPOK, body: '{}', code: '200', message: 'OK'))
      t.get('nsversion')
    end
  end
end
