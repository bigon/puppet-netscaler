# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/netscaler/specs'

# Ordering between NetScaler entities, without explicit require
describe 'netscaler autorequires' do
  let(:catalog) { Puppet::Resource::Catalog.new }

  def add(type, title, params = {})
    Puppet::Type.type(type).new(params.merge(title: title)).tap { |r| catalog.add_resource(r) }
  end

  def required_by(resource)
    resource.autorequire(catalog).map { |rel| rel.source.ref }
  end

  it 'orders a compat service after its server' do
    add(:netscaler_server, 'web1', address: '10.0.0.1')
    service = add(:netscaler_service, 'svc1', server_name: 'web1', port: '80', protocol: 'HTTP')
    expect(required_by(service)).to eq(['Netscaler_server[web1]'])
  end

  it 'orders a compat binding after both sides, read from its title' do
    add(:netscaler_lbvserver, 'vs1')
    add(:netscaler_service, 'svc1')
    binding = add(:netscaler_lbvserver_service_binding, 'vs1/svc1')
    expect(required_by(binding)).to contain_exactly('Netscaler_lbvserver[vs1]', 'Netscaler_service[svc1]')
  end

  it 'orders a compat servicegroup member after its group and server' do
    add(:netscaler_servicegroup, 'sg1')
    add(:netscaler_server, 'web1')
    member = add(:netscaler_servicegroup_member, 'sg1/web1:80')
    expect(required_by(member)).to contain_exactly('Netscaler_servicegroup[sg1]', 'Netscaler_server[web1]')
  end

  it 'orders a compat monitor binding after its service and monitor' do
    add(:netscaler_service, 'svc1')
    add(:netscaler_lbmonitor, 'probe1')
    binding = add(:netscaler_service_lbmonitor_binding, 'svc1/probe1')
    expect(required_by(binding)).to contain_exactly('Netscaler_service[svc1]', 'Netscaler_lbmonitor[probe1]')
  end

  it 'orders a nitro binding after nitro entities' do
    add(:nitro_lbvserver, 'vs1', servicetype: 'HTTP')
    add(:nitro_service, 'svc1')
    binding = add(:nitro_lbvserver_service_binding, 'vs1/svc1')
    expect(required_by(binding)).to contain_exactly('Nitro_lbvserver[vs1]', 'Nitro_service[svc1]')
  end

  it 'orders across families, for manifests mixing them' do
    add(:netscaler_lbvserver, 'vip_x-443')
    binding = add(:nitro_sslvserver_sslciphersuite_binding, 'vip_x-443/CUSTOM-CIPHERS')
    expect(required_by(binding)).to eq(['Netscaler_lbvserver[vip_x-443]'])
  end

  it 'orders a compat binding after nitro entities too' do
    add(:nitro_lbvserver, 'vs1', servicetype: 'HTTP')
    add(:netscaler_service, 'svc1')
    binding = add(:netscaler_lbvserver_service_binding, 'vs1/svc1')
    expect(required_by(binding)).to contain_exactly('Nitro_lbvserver[vs1]', 'Netscaler_service[svc1]')
  end

  it 'does not confuse netscaler_sslvserver (a certificate binding) with an SSL vserver' do
    add(:netscaler_sslvserver, 'vs1/cert1')
    binding = add(:nitro_sslvserver_sslciphersuite_binding, 'vs1/C')
    expect(required_by(binding)).to be_empty
    expect(Puppet::Type.type(:nitro_sslvserver_sslciphersuite_binding).type_definition.definition[:autorequire].keys).not_to include(:netscaler_sslvserver)
  end

  it 'requires nothing when the referenced entities are not managed' do
    expect(required_by(add(:netscaler_lbvserver_service_binding, 'vs1/svc1'))).to be_empty
    expect(required_by(add(:netscaler_service, 'svc1', server_name: 'web1'))).to be_empty
  end

  it 'only autorequires existing types' do
    PuppetX::Netscaler::SPECS.each do |resource, spec|
      spec['autorequire'].each_key do |type|
        expect(Puppet::Type.type(type.to_sym)).not_to be_nil, "nitro_#{resource} autorequires unknown type #{type}"
      end
    end
  end
end
