# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'puppet/util/network_device/netscaler/device'

# Compiled catalogs (Stage, classes) applied as on a network device
describe 'nsconfig_save' do
  let(:base) { 'https://ns.example.com/nitro/v1/config' }
  let(:device) { Puppet::Util::NetworkDevice::Netscaler::Device.new(host: 'ns.example.com', user: 'nsroot', password: 'pw') }
  let(:save) { "#{base}/nsconfig?action=save" }

  let(:vardir) { Dir.mktmpdir }

  before do
    Puppet[:vardir] = vardir
    Puppet[:strict] = :error
    allow(Puppet::Util::NetworkDevice).to receive(:current).and_return(device)
    stub_request(:get, "#{base}/server").to_return(json('errorcode' => 0))
    stub_request(:post, "#{base}/server").to_return(json({}, 201))
    stub_request(:post, save).to_return(json({}))
  end

  after do
    Puppet[:noop] = false
    FileUtils.remove_entry(vardir)
  end

  # host_config catalogs honour noop and tags; they need the state directory
  def apply(code, host_config: false, tags: nil, noop: false)
    Puppet[:code] = code
    catalog = Puppet::Parser::Compiler.compile(Puppet::Node.new('ns.example.com')).to_ral
    catalog.host_config = host_config
    FileUtils.mkdir_p(Puppet[:statedir]) if host_config
    Puppet[:noop] = noop
    report = Puppet.override(network_device: true) { catalog.apply(tags: tags).report }
    report.finalize_report
    report
  end

  def saves
    WebMock::RequestRegistry.instance.times_executed(WebMock::RequestPattern.new(:post, save))
  end

  it 'saves once after a change, from another class' do
    report = apply(<<~PP)
      class a { nitro_server { 'web1': ipaddress => '10.0.0.1' } nitro_server { 'web2': ipaddress => '10.0.0.2' } }
      class b { nsconfig_save { 'running': } }
      include a
      include b
    PP
    expect(saves).to eq(1)
    expect(report.status).to eq('changed')
  end

  it 'saves after a change of a netscaler_* type' do
    apply("netscaler_server { 'web1': address => '10.0.0.1' }\nnsconfig_save { 'running': }")
    expect(saves).to eq(1)
  end

  it 'does not save without a change' do
    stub_request(:get, "#{base}/server").to_return(json('server' => [{ 'name' => 'web1', 'ipaddress' => '10.0.0.1' }]))
    apply("nitro_server { 'web1': ipaddress => '10.0.0.1' }\nnsconfig_save { 'running': }")
    expect(saves).to eq(0)
  end

  it 'never saves without the resource' do
    apply("nitro_server { 'web1': ipaddress => '10.0.0.1' }")
    expect(saves).to eq(0)
  end

  context 'when something fails on the device' do
    it 'does not save after a change NITRO refused' do
      stub_request(:post, "#{base}/server").to_return(nitro_error(273, 'Resource already exists', 409))
      stub_request(:get, "#{base}/lbvserver").to_return(json('errorcode' => 0))
      stub_request(:post, "#{base}/lbvserver").to_return(json({}, 201))
      report = apply("nitro_server { 'web1': ipaddress => '10.0.0.1' }\nnitro_lbvserver { 'vs1': servicetype => 'HTTP', port => 80 }\nnsconfig_save { 'running': }")
      expect(saves).to eq(0)
      expect(report.exit_status).to eq(6)
    end

    it 'does not save after a change the Resource API refused before calling the provider' do
      stub_request(:get, "#{base}/lbvserver").to_return(json('lbvserver' => [{ 'name' => 'vs1', 'servicetype' => 'HTTP', 'port' => 80 }]))
      apply("nitro_server { 'web1': ipaddress => '10.0.0.1' }\nnitro_lbvserver { 'vs1': servicetype => 'HTTP', port => 8080 }\nnsconfig_save { 'running': }")
      expect(saves).to eq(0)
    end

    it 'does not save after a failed lookup' do
      stub_request(:get, %r{\A#{Regexp.escape(base)}/lbvserver}).to_return(nitro_error(1, 'boom', 500))
      apply("nitro_server { 'web1': ipaddress => '10.0.0.1' }\nnitro_lbvserver { 'vs1': servicetype => 'HTTP', port => 80 }\nnsconfig_save { 'running': }")
      expect(saves).to eq(0)
    end
  end

  it 'fails, in the report, when NITRO refuses the save' do
    stub_request(:post, save).to_return(nitro_error(1, 'boom', 500))
    report = apply("nitro_server { 'web1': ipaddress => '10.0.0.1' }\nnsconfig_save { 'running': }")
    expect(report.status).to eq('failed')
    expect(report.exit_status).to eq(6)
    expect(report.logs.map(&:message).join("\n")).to include('boom')
  end

  it 'does not save in noop mode' do
    apply("nitro_server { 'web1': ipaddress => '10.0.0.1' }\nnsconfig_save { 'running': }", host_config: true, noop: true)
    expect(saves).to eq(0)
    expect(a_request(:post, "#{base}/server")).not_to have_been_made
  end

  it 'does not save when tags leave it out' do
    apply("nitro_server { 'web1': ipaddress => '10.0.0.1', tag => 'only' }\nnsconfig_save { 'running': }", host_config: true, tags: ['only'])
    expect(saves).to eq(0)
  end

  it 'saves with an explicit ~>' do
    apply("nitro_server { 'web1': ipaddress => '10.0.0.1' }\n~> nsconfig_save { 'running': }")
    expect(saves).to eq(1)
  end

  it 'refuses an explicit -> that would lose the subscription, before changing anything' do
    logs = []
    Puppet::Util::Log.with_destination(Puppet::Test::LogCollector.new(logs)) do
      expect { apply("nitro_server { 'web1': ipaddress => '10.0.0.1' }\n-> nsconfig_save { 'running': }") }
        .to raise_error(Puppet::Error, %r{pre-run checks failed})
    end
    expect(logs.map(&:message).join("\n")).to include('must not be ordered with ->, require, before, or notify/subscribe towards them, against Nitro_server[web1]')
    expect(a_request(:post, "#{base}/server")).not_to have_been_made
    expect(saves).to eq(0)
  end

  [
    "nitro_server { 'web1': ipaddress => '10.0.0.1' }\nnsconfig_save { 'running': notify => Nitro_server['web1'] }",
    "nitro_server { 'web1': ipaddress => '10.0.0.1', subscribe => Nsconfig_save['running'] }\nnsconfig_save { 'running': }",
  ].each do |code|
    it "refuses a refresh from it to a managed resource: #{code.lines.last.strip}" do
      logs = []
      Puppet::Util::Log.with_destination(Puppet::Test::LogCollector.new(logs)) do
        expect { apply(code) }.to raise_error(Puppet::Error, %r{pre-run checks failed})
      end
      expect(logs.map(&:message).join("\n")).to include('against Nitro_server[web1]')
      expect(a_request(:post, "#{base}/server")).not_to have_been_made
    end
  end

  it 'refuses a second nsconfig_save' do
    logs = []
    Puppet::Util::Log.with_destination(Puppet::Test::LogCollector.new(logs)) do
      expect { apply("nitro_server { 'web1': ipaddress => '10.0.0.1' }\nnsconfig_save { ['a', 'b']: }") }
        .to raise_error(Puppet::Error, %r{pre-run checks failed})
    end
    expect(logs.map(&:message).join("\n")).to include('must be the only nsconfig_save of the catalog')
    expect(saves).to eq(0)
  end

  it 'accepts ordering between the classes that contain them' do
    apply(<<~PP)
      class a { nitro_server { 'web1': ipaddress => '10.0.0.1' } }
      class b { nsconfig_save { 'running': } }
      include a
      include b
      Class['a'] -> Class['b']
    PP
    expect(saves).to eq(1)
  end

  it 'lists nothing' do
    expect(Puppet::Type.type(:nsconfig_save).instances).to eq([])
  end
end
