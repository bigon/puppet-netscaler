# frozen_string_literal: true

require 'spec_helper'
require 'puppet/transport/netscaler'
require 'puppet_x/netscaler/nitro_resource'

describe PuppetX::Netscaler::NitroResource do
  let(:client) { instance_double(Puppet::Transport::Netscaler) }

  def res(name)
    described_class.for(name)
  end

  describe '.for' do
    it 'raises for unknown resources' do
      expect { res('nope') }.to raise_error(KeyError)
    end
  end

  describe '#list' do
    it 'fetches all entities' do
      expect(client).to receive(:get).with('server', nil, {}).and_return('server' => [{ 'name' => 'a', 'ipaddress' => '10.0.0.1', 'statechangetimesec' => 'x' }])
      expect(res('server').list(client)).to eq([{ 'name' => 'a', 'ipaddress' => '10.0.0.1' }])
    end

    it 'fetches named entities one by one and skips missing ones' do
      expect(client).to receive(:get).with('server', 'a').and_return('server' => [{ 'name' => 'a' }])
      expect(client).to receive(:get).with('server', 'b').and_return(nil)
      expect(res('server').list(client, %w[a b a])).to eq([{ 'name' => 'a' }])
    end

    it 'uses bulkbindings to list all bindings' do
      expect(client).to receive(:get).with('lbvserver_service_binding', nil, { 'bulkbindings' => 'yes' })
                                     .and_return('lbvserver_service_binding' => [{ 'name' => 'vs', 'servicename' => 'svc', 'weight' => '10', 'curstate' => 'UP' }])
      expect(res('lbvserver_service_binding').list(client)).to eq([{ 'name' => 'vs', 'servicename' => 'svc', 'weight' => 10 }])
    end

    it 'handles an empty answer' do
      allow(client).to receive(:get).and_return({ 'errorcode' => 0 })
      expect(res('lbvserver').list(client)).to eq([])
    end
  end

  describe '#normalize' do
    it 'coerces values to their declared kind' do
      rec = res('lbmonitor').normalize(
        'monitorname' => 'm', 'interval' => '5', 'respcode' => '200', 'lrtm' => 'ENABLED', 'Snmpoid' => 1.3,
      )
      expect(rec).to include('interval' => 5, 'respcode' => ['200'], 'lrtm' => 'ENABLED', 'Snmpoid' => '1.3')
    end

    it 'coerces booleans' do
      expect(res('server').normalize('name' => 's', 'domainresolvenow' => 'true')).to include('domainresolvenow' => true)
    end

    it 'derives state from the runtime state' do
      expect(res('service').normalize('name' => 's', 'svrstate' => 'OUT OF SERVICE')).to include('state' => 'DISABLED')
      expect(res('lbvserver').normalize('name' => 'v', 'curstate' => 'DOWN')).to include('state' => 'ENABLED')
    end

    it 'keeps the configured state when reported' do
      expect(res('server').normalize('name' => 's', 'state' => 'DISABLED', 'svrstate' => 'UP')).to include('state' => 'DISABLED')
    end
  end

  describe '#create' do
    it 'POSTs the create attributes of an entity' do
      expect(client).to receive(:post).with('server', { 'name' => 'web1', 'ipaddress' => '10.0.0.1', 'state' => 'DISABLED' })
      res('server').create(client, 'name' => 'web1', 'ipaddress' => '10.0.0.1', 'state' => 'DISABLED')
    end

    it 'checks the attributes NITRO requires' do
      expect { res('service').create(client, 'name' => 'svc') }.to raise_error(ArgumentError, %r{missing required attribute\(s\) servicetype, port})
    end

    it 'sets update-only attributes with a PUT after creation' do
      expect(client).to receive(:post).with('service', { 'name' => 'svc', 'servicetype' => 'HTTP', 'port' => 80, 'servername' => 'web1' })
      expect(client).to receive(:put).with('service', { 'name' => 'svc', 'weight' => 5 }, 'svc')
      res('service').create(client, 'name' => 'svc', 'servicetype' => 'HTTP', 'port' => 80, 'servername' => 'web1', 'weight' => 5)
    end

    it 'runs actions for action-only attributes' do
      expect(client).to receive(:post).with('sslcertkey', { 'certkey' => 'c', 'cert' => '/nsconfig/ssl/c.pem' })
      expect(client).to receive(:action).with('sslcertkey', 'link', { 'certkey' => 'c', 'linkcertkeyname' => 'ca' })
      res('sslcertkey').create(client, 'certkey' => 'c', 'cert' => '/nsconfig/ssl/c.pem', 'linkcertkeyname' => 'ca')
    end

    it 'adds bindings with a PUT' do
      expect(client).to receive(:put).with('lbvserver_service_binding', { 'name' => 'vs', 'servicename' => 'svc', 'weight' => 10 })
      res('lbvserver_service_binding').create(client, 'name' => 'vs', 'servicename' => 'svc', 'weight' => 10)
    end

    it 'updates settings entities instead of creating them' do
      expect(client).to receive(:put).with('sslvserver', { 'vservername' => 'vs', 'tls1' => 'DISABLED' }, 'vs')
      res('sslvserver').create(client, 'vservername' => 'vs', 'tls1' => 'DISABLED')
    end
  end

  describe '#update' do
    let(:is) { { 'name' => 'web1', 'ipaddress' => '10.0.0.1', 'comment' => 'old', 'state' => 'ENABLED', 'td' => 0 } }

    it 'does nothing when in sync' do
      res('server').update(client, is, 'name' => 'web1', 'comment' => 'old')
    end

    it 'only PUTs changed attributes' do
      expect(client).to receive(:put).with('server', { 'name' => 'web1', 'comment' => 'new' }, 'web1')
      res('server').update(client, is, 'name' => 'web1', 'comment' => 'new', 'ipaddress' => '10.0.0.1')
    end

    it 'includes the attributes NITRO requires on update' do
      expect(client).to receive(:put).with('lbmonitor', { 'monitorname' => 'm', 'type' => 'HTTP', 'interval' => 10 }, 'm')
      res('lbmonitor').update(client, { 'monitorname' => 'm', 'type' => 'HTTP', 'interval' => 5 }, 'monitorname' => 'm', 'interval' => 10)
    end

    it 'never compares write-only attributes' do
      res('lbmonitor').update(client, { 'monitorname' => 'm', 'type' => 'LDAP' }, 'monitorname' => 'm', 'password' => 'secret')
    end

    it 'disables with the disable parameters' do
      expect(client).to receive(:action).with('server', 'disable', { 'name' => 'web1', 'delay' => 30, 'graceful' => 'YES' })
      res('server').update(client, is, 'name' => 'web1', 'state' => 'DISABLED', 'delay' => 30, 'graceful' => 'YES')
    end

    it 'enables' do
      expect(client).to receive(:action).with('server', 'enable', { 'name' => 'web1' })
      res('server').update(client, is.merge('state' => 'DISABLED'), 'name' => 'web1', 'state' => 'ENABLED')
    end

    it 'refuses to change init-only attributes' do
      expect { res('server').update(client, is, 'name' => 'web1', 'td' => 3) }.to raise_error(ArgumentError, %r{td cannot be changed after creation})
    end

    it 'updates certificates through the update action' do
      expect(client).to receive(:action).with('sslcertkey', 'update', { 'certkey' => 'c', 'cert' => 'new.pem', 'key' => 'new.key', 'passplain' => 'pw' })
      expect(client).to receive(:put).with('sslcertkey', { 'certkey' => 'c', 'expirymonitor' => 'ENABLED' }, 'c')
      res('sslcertkey').update(
        client,
        { 'certkey' => 'c', 'cert' => 'old.pem', 'key' => 'new.key', 'expirymonitor' => 'DISABLED' },
        'certkey' => 'c', 'cert' => 'new.pem', 'key' => 'new.key', 'passplain' => 'pw', 'expirymonitor' => 'ENABLED',
      )
    end

    it 'compares arrays without ordering' do
      res('lbmonitor').update(client, { 'monitorname' => 'm', 'respcode' => %w[200 301] }, 'monitorname' => 'm', 'respcode' => %w[301 200])
    end

    it 'sends the expiry monitor along with a new notification period' do
      expect(client).to receive(:put).with('sslcertkey', { 'certkey' => 'c', 'notificationperiod' => 20, 'expirymonitor' => 'ENABLED' }, 'c')
      res('sslcertkey').update(client, { 'certkey' => 'c', 'expirymonitor' => 'ENABLED', 'notificationperiod' => 30 }, 'certkey' => 'c', 'notificationperiod' => 20)
    end

    it 'rebinds without the attributes NITRO refuses on a bind' do
      is = { 'servicegroupname' => 'sg', 'servername' => 'web1', 'port' => 80, 'ip' => '10.0.0.1', 'weight' => 5, 'state' => 'DISABLED', 'hashid' => 0 }
      expect(client).to receive(:delete).with('servicegroup_servicegroupmember_binding', 'sg', { 'servername' => 'web1', 'port' => 80 }).ordered
      expect(client).to receive(:put).with('servicegroup_servicegroupmember_binding',
                                           { 'servicegroupname' => 'sg', 'servername' => 'web1', 'port' => 80, 'weight' => 6, 'state' => 'DISABLED', 'hashid' => 0 }).ordered
      res('servicegroup_servicegroupmember_binding').update(client, is, 'servicegroupname' => 'sg', 'servername' => 'web1', 'port' => 80, 'weight' => 6)
    end

    it 'rebinds changed bindings' do
      is = { 'name' => 'vs', 'servicename' => 'svc', 'weight' => 1, 'order' => 2 }
      expect(client).to receive(:delete).with('lbvserver_service_binding', 'vs', { 'servicename' => 'svc' }).ordered
      expect(client).to receive(:put).with('lbvserver_service_binding', { 'name' => 'vs', 'servicename' => 'svc', 'weight' => 50, 'order' => 2 }).ordered
      res('lbvserver_service_binding').update(client, is, 'name' => 'vs', 'servicename' => 'svc', 'weight' => 50)
    end
  end

  describe '#delete' do
    it 'deletes entities by key' do
      expect(client).to receive(:delete).with('server', 'web1', {})
      res('server').delete(client, 'name' => 'web1', 'ipaddress' => '10.0.0.1')
    end

    it 'passes the args NITRO requires to delete an entity' do
      expect(client).to receive(:delete).with('lbmonitor', 'm', { 'type' => 'HTTP' })
      res('lbmonitor').delete(client, 'monitorname' => 'm', 'type' => 'HTTP')
    end

    it 'passes the binding namevars and extra delete args' do
      expect(client).to receive(:delete).with('csvserver_cspolicy_binding', 'cs', { 'policyname' => 'p', 'bindpoint' => 'REQUEST', 'priority' => 10 })
      res('csvserver_cspolicy_binding').delete(client, 'name' => 'cs', 'policyname' => 'p', 'bindpoint' => 'REQUEST', 'priority' => 10, 'invoke' => false)
    end

    it 'deletes servicegroup members by server and port' do
      expect(client).to receive(:delete).with('servicegroup_servicegroupmember_binding', 'sg', { 'servername' => 'web1', 'port' => 80 })
      res('servicegroup_servicegroupmember_binding').delete(client, 'servicegroupname' => 'sg', 'servername' => 'web1', 'port' => 80, 'weight' => 1)
    end

    it 'cannot delete settings entities' do
      expect { res('sslvserver').delete(client, 'vservername' => 'vs') }.to raise_error(ArgumentError)
    end
  end
end
