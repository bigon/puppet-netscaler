# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/netscaler/specs'
require 'puppet_x/netscaler/compat_definitions'

# Registration checks for every generated nitro_* and compat netscaler_* type
describe 'netscaler types' do
  PuppetX::Netscaler::SPECS.each do |resource, spec|
    describe "nitro_#{resource}" do
      let(:type) { Puppet::Type.type(:"nitro_#{resource}") }
      let(:definition) { type.type_definition }

      it 'is registered' do
        expect(type).not_to be_nil
      end

      it 'declares every attribute of the spec' do
        expect(definition.attributes.keys.map(&:to_s)).to include(*spec['attributes'].keys)
      end

      it 'has a provider bound to the NITRO resource' do
        require "puppet/provider/nitro_#{resource}/nitro_#{resource}"
        cls = "nitro_#{resource}".split('_').map(&:capitalize).join
        expect(Puppet::Provider.const_get(cls).const_get(cls).nitro.resource).to eq(resource)
      end

      it 'is a remote resource' do
        expect(definition.feature?('remote_resource')).to be(true)
      end

      it 'canonicalizes (sorted NITRO lists, binding titles)' do
        expect(definition.feature?('canonicalize')).to be(true)
      end

      it "is #{'not ' if spec['kind'] == 'settings'}ensurable" do
        expect(definition.ensurable?).to be(spec['kind'] != 'settings')
      end

      it 'declares the NITRO keys as namevars' do
        expected = spec['attributes'].select { |_n, a| spec['namevars'].include?(a['api']) }.keys.map(&:to_sym)
        expect(definition.namevars).to match_array(expected)
      end

      spec['attributes'].each do |name, attr|
        next unless attr['behaviour']

        it "declares #{name} as #{attr['behaviour']}" do
          expect(definition.attributes[name.to_sym][:behaviour]).to eq(attr['behaviour'].to_sym)
        end
      end

      next unless spec['kind'] == 'binding'

      it 'splits a composite title into its namevars' do
        nvs = definition.namevars
        values = nvs.map { |nv| definition.attributes[nv][:type].start_with?('Pattern') ? '8080' : "x#{nv}" }
        title = spec['title_pattern'] ? 'xsg/x.example.com:8080' : values.join('/')
        resource = type.new(title: title)
        expected = spec['title_pattern'] ? %w[xsg x.example.com 8080] : values
        expect(nvs.map { |nv| resource[nv] }).to eq(expected)
      end
    end
  end

  PuppetX::Netscaler::COMPAT.each do |name, compat|
    describe name do
      let(:type) { Puppet::Type.type(name.to_sym) }

      it 'is registered with a single namevar' do
        expect(type.type_definition.namevars).to eq([:name])
      end

      it "targets an existing NITRO resource (#{compat[:nitro]})" do
        expect(PuppetX::Netscaler::SPECS).to include(compat[:nitro])
      end

      it 'maps every attribute onto a NITRO attribute or marks it ignored' do
        apis = PuppetX::Netscaler::SPECS[compat[:nitro]]['attributes'].values.map { |a| a['api'] }
        # csvserver default_lbvserver is handled by the provider (binding)
        compat[:attributes].each do |attr, a|
          next if a[:ignored] || (name == 'netscaler_csvserver' && attr == :default_lbvserver)

          expect(apis).to include(a[:api]), "#{name}.#{attr} maps to unknown NITRO attribute #{a[:api]}"
        end
      end

      it 'parses titles' do
        if compat[:title_pattern]
          expect(compat[:title_pattern]).to match(compat[:title_format].gsub(%r{%\{\w+\}}, 'x1').sub(%r{:x1\z}, ':80'))
        else
          expect(type.new(title: 'obj1')[:name]).to eq('obj1')
        end
      end
    end
  end

  # Resource API >= 2.0 keeps a get() cache on the type class for the whole
  # process; the transport caches per device instead (1.9.x has no such cache)
  describe 'Resource API get cache' do
    (PuppetX::Netscaler::SPECS.keys.map { |r| "nitro_#{r}" } + PuppetX::Netscaler::COMPAT.keys).each do |name|
      it "is not kept by #{name}" do
        type = Puppet::Type.type(name.to_sym)
        skip 'Resource API < 2.0 has no get cache' unless type.respond_to?(:rsapi_provider_get_cache)

        type.rsapi_provider_get_cache.add('x', ensure: 'present')
        expect(type.rsapi_provider_get_cache.get('x')).to be_nil
      end
    end
  end

  describe 'generated compat type files' do
    require_relative '../../../../tools/generate_compat'

    PuppetX::Netscaler::COMPAT.each_key do |name|
      it "lib/puppet/type/#{name}.rb is up to date (rake generate:compat)" do
        expect(File.read(File.expand_path("../../../../lib/puppet/type/#{name}.rb", __dir__))).to eq(CompatGenerator.render(name))
      end
    end
  end

  describe 'compat value munging' do
    it 'accepts all puppetlabs-netscaler truthy spellings' do
      %w[yes true enabled on YES ENABLED ON].each do |v|
        expect(Puppet::Type.type(:netscaler_lbvserver).new(title: 'lb', state: v)[:state]).to eq('ENABLED')
      end
      %w[no false disabled off NO DISABLED OFF].each do |v|
        expect(Puppet::Type.type(:netscaler_lbvserver).new(title: 'lb', state: v)[:state]).to eq('DISABLED')
      end
      expect(Puppet::Type.type(:netscaler_lbvserver).new(title: 'lb', state: true)[:state]).to eq('ENABLED')
    end

    it 'maps truthy values to the NITRO pair of each attribute' do
      r = Puppet::Type.type(:netscaler_service).new(title: 's', sure_connect: 'on', use_source_ip: true, appflow_logging: 'yes')
      expect([r[:use_source_ip], r[:appflow_logging]]).to eq(%w[YES ENABLED])
    end

    it 'maps truthy values onto NITRO booleans' do
      expect(Puppet::Type.type(:netscaler_servicegroup_lbmonitor_binding).new(title: 'sg/mon', passive: 'yes')[:passive].to_s).to eq('true')
    end

    it 'converts numeric strings and upcases enums' do
      r = Puppet::Type.type(:netscaler_lbvserver).new(title: 'lb', port: '8080', service_type: 'http', lb_method: 'roundrobin')
      expect([r[:port], r[:service_type], r[:lb_method]]).to eq([8080, 'HTTP', 'ROUNDROBIN'])
    end

    it 'spells enums as NITRO does, whatever the case given' do
      expect(Puppet::Type.type(:netscaler_service).new(title: 's', protocol: 'radiuslistener')[:protocol]).to eq('RADIUSListener')
      expect(Puppet::Type.type(:netscaler_servicegroup).new(title: 'sg', protocol: 'RADIUSLISTENER')[:protocol]).to eq('RADIUSListener')
    end

    it 'never compares secrets NITRO does not return' do
      definition = Puppet::Type.type(:netscaler_lbmonitor).type_definition
      %i[password secondary_password radius_key].each do |attr|
        expect(definition.attributes[attr][:behaviour]).to eq(:parameter)
      end
      expect(Puppet::Type.type(:netscaler_sslcertkey).type_definition.attributes[:passplain][:behaviour]).to eq(:parameter)
    end

    it 'keeps disable options as parameters without calling them write-only' do
      %i[netscaler_server netscaler_service netscaler_servicegroup].each do |type|
        attr = Puppet::Type.type(type).type_definition.attributes[:graceful_shutdown]
        expect(attr[:behaviour]).to eq(:parameter)
        expect(attr[:desc]).not_to include('Write-only')
      end
      expect(Puppet::Type.type(:netscaler_lbmonitor).type_definition.attributes[:password][:desc]).to include('Write-only')
    end

    it 'turns single values into sorted NITRO lists' do
      expect(Puppet::Type.type(:netscaler_lbmonitor).new(title: 'm', response_codes: 200)[:response_codes]).to eq(['200'])
      expect(Puppet::Type.type(:netscaler_lbmonitor).new(title: 'm', response_codes: [301, '200'])[:response_codes]).to eq(%w[200 301])
    end

    it 'rejects garbage' do
      expect { Puppet::Type.type(:netscaler_lbvserver).new(title: 'lb', state: 'maybe') }.to raise_error(Puppet::ResourceError)
      expect { Puppet::Type.type(:netscaler_lbvserver).new(title: 'lb', port: 'eighty') }.to raise_error(Puppet::ResourceError)
    end
  end
end
