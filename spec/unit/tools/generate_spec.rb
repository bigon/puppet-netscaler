# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative '../../../tools/generate'

describe NitroGenerator do
  let(:oas_dir) { File.expand_path('../../fixtures/generator/oas', __dir__) }
  let(:rest_dir) { Dir.mktmpdir }
  let(:root) { File.expand_path('../../..', __dir__) }

  # The generator globs <dir>/<package>/<resource>.yaml
  let(:oas) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p(File.join(oas, 'pkg'))
    FileUtils.cp(Dir[File.join(oas_dir, '*.yaml')], File.join(oas, 'pkg'))
    FileUtils.mkdir_p(File.join(rest_dir, 'pkg'))
    FileUtils.cp(Dir[File.expand_path('../../fixtures/generator/rest/*.html', __dir__)], File.join(rest_dir, 'pkg'))
  end

  after do
    FileUtils.rm_rf(oas)
    FileUtils.rm_rf(rest_dir)
  end

  def spec_for(resource, cfg = {})
    described_class.build_spec(resource, described_class.load_oas(oas, resource), cfg, described_class.load_get_fields(rest_dir, resource))
  end

  describe '.load_get_fields' do
    it 'lists the attributes returned by GET, including the unquoted keys' do
      fields = described_class.load_get_fields(rest_dir, 'server')
      expect(fields).to include('name', 'ipaddress', 'domain', 'state', 'td', 'comment')
      expect(fields).not_to include('domainresolvenow', 'delay', 'newname')
    end

    it 'returns nil without a reference page' do
      expect(described_class.load_get_fields(rest_dir, 'nope')).to be_nil
    end
  end

  describe 'attributes GET does not return' do
    subject(:spec) { spec_for('service') }

    it 'become parameters' do
      expect(spec['attributes']['ip']).to include('behaviour' => 'parameter', 'create' => true)
      expect(spec['attributes']['monitor_name_svc']).to include('behaviour' => 'parameter')
    end

    it 'keeps state and create-required attributes comparable' do
      expect(spec['attributes']['state']['behaviour']).to be_nil
      expect(spec['attributes']['servicetype']['behaviour']).to eq('init_only')
    end
  end

  describe 'list attributes' do
    subject(:spec) { spec_for('service') }

    it 'types untyped items as bounded integers' do
      expect(spec['attributes']['idlist']).to include('kind' => 'array', 'items' => 'integer', 'type' => 'Optional[Array[Integer[1, 4294967295]]]')
    end

    it 'keeps typed items as strings' do
      expect(spec['attributes']['namelist']).to include('kind' => 'array', 'type' => 'Optional[Array[String]]')
      expect(spec['attributes']['namelist']).not_to have_key('items')
    end
  end

  describe '.parse_yaml' do
    it 'keeps YES/NO as strings' do
      expect(described_class.parse_yaml("a:\n  enum:\n    - YES\n    - NO\n  default: ON\n")).to eq('a' => { 'enum' => %w[YES NO], 'default' => 'ON' })
    end

    it 'resolves anchors' do
      expect(described_class.parse_yaml("a: &x\n  b: 1\nc: *x\n")).to eq('a' => { 'b' => 1 }, 'c' => { 'b' => 1 })
    end
  end

  describe 'an entity (server)' do
    subject(:spec) { spec_for('server') }

    it 'derives the key and kind' do
      expect(spec).to include('kind' => 'entity', 'key' => 'name', 'namevars' => ['name'], 'state_actions' => true)
    end

    it 'deletes with the args NITRO requires, not the optional ones' do
      expect(spec['delete_args']).to eq(['td'])
    end

    it 'sends companion attributes with an update' do
      expect(spec_for('server', 'update_with' => { 'comment' => ['td'] })['update_with']).to eq('comment' => ['td'])
    end

    it 'rejects update_with on unknown attributes' do
      expect { spec_for('server', 'update_with' => { 'comment' => ['nope'] }) }.to raise_error(ArgumentError, %r{unknown attributes nope})
    end

    it 'rejects rebind_exclude on an entity' do
      expect { spec_for('server', 'rebind_exclude' => ['comment']) }.to raise_error(ArgumentError, %r{only for bindings})
    end

    describe 'secrets' do
      subject(:spec) { spec_for('server', 'sensitive' => %w[comment ipaddress], 'write_only' => ['ipaddress']) }

      it 'accept Sensitive values' do
        expect(spec['attributes']['comment']).to include('sensitive' => true, 'type' => 'Optional[Variant[String, Sensitive[String]]]')
        expect(spec['attributes']['domain']).not_to have_key('sensitive')
      end

      it 'are redacted in events, but Puppet is not asked to redact parameters' do
        code = described_class.render_type(spec)
        expect(code).to include('super((sensitive_parameters - %i[ipaddress]) | %i[comment].select { |n| parameter(n) })')
        expect { RubyVM::InstructionSequence.compile(code) }.not_to raise_error
      end

      it 'must be strings' do
        expect { spec_for('server', 'sensitive' => ['td']) }.to raise_error(ArgumentError, %r{sensitive attribute td is not a string})
      end

      it 'must exist' do
        expect { spec_for('server', 'sensitive' => ['nope']) }.to raise_error(ArgumentError, %r{unknown attributes nope})
      end
    end

    it 'marks add-only attributes init_only' do
      expect(spec['attributes'].select { |_n, a| a['behaviour'] == 'init_only' }.keys).to match_array(%w[domain ipv6address querytype td])
    end

    it 'keeps state updatable through enable/disable' do
      expect(spec['attributes']['state']).to include('behaviour' => nil, 'create' => true, 'update' => true)
    end

    it 'turns disable options into parameters' do
      expect(spec['attributes']['delay']).to include('behaviour' => 'parameter', 'create' => false, 'disable_param' => true)
      expect(spec['attributes']['graceful']).to include('behaviour' => 'parameter', 'disable_param' => true)
    end

    it 'includes update-only attributes' do
      expect(spec['attributes']['domainresolvenow']).to include('create' => false, 'update' => true, 'kind' => 'boolean', 'behaviour' => 'parameter')
    end

    it 'skips readOnly and rename attributes' do
      expect(spec['attributes'].keys).not_to include('newname', 'statechangetimesec', 'Internal')
    end

    it 'renders a valid Resource API type' do
      code = described_class.render_type(spec)
      expect(code).to include("name: 'nitro_server'", 'type: "Optional[Integer[0, 4094]]"', %q(type: "Optional[Enum['YES', 'NO']]"))
      expect { RubyVM::InstructionSequence.compile(code) }.not_to raise_error
    end
  end

  describe 'a binding (lbvserver_service_binding)' do
    subject(:spec) { spec_for('lbvserver_service_binding', 'namevars' => %w[name servicename]) }

    it 'is a binding with composite namevars' do
      expect(spec).to include('kind' => 'binding', 'key' => 'name', 'namevars' => %w[name servicename], 'state_actions' => false)
    end

    it 'deletes using the other namevars as args' do
      expect(spec['delete_args']).to eq(['servicename'])
    end

    it 'keeps the attributes NITRO refuses on a bind out of a rebind' do
      expect(spec_for('lbvserver_service_binding', 'namevars' => %w[name servicename], 'rebind_exclude' => ['weight'])['rebind_exclude']).to eq(['weight'])
    end

    it 'autorequires both families of the referenced entities' do
      spec = spec_for('lbvserver_service_binding', 'namevars' => %w[name servicename], 'autorequire' => { 'name' => ['lbvserver'], 'servicename' => ['service'] })
      expect(spec['autorequire']).to eq(
        'nitro_lbvserver' => ['$name'], 'netscaler_lbvserver' => ['$name'],
        'nitro_service' => ['$servicename'], 'netscaler_service' => ['$servicename']
      )
    end

    it 'rejects autorequires on unknown attributes' do
      expect { spec_for('lbvserver_service_binding', 'namevars' => %w[name servicename], 'autorequire' => { 'nope' => ['lbvserver'] }) }
        .to raise_error(ArgumentError, %r{unknown attribute nope})
    end

    it 'builds the title back from the namevars' do
      expect(spec['title_format']).to eq('%{name}/%{servicename}')
    end

    it 'renders title patterns' do
      code = described_class.render_type(spec)
      expect(code).to include('%r{\A(?<name>[^/]+)/(?<servicename>[^/]+)\z}')
      expect { RubyVM::InstructionSequence.compile(code) }.not_to raise_error
    end

    it 'rejects a first namevar that is not the URL key' do
      expect { spec_for('lbvserver_service_binding', 'namevars' => %w[servicename name]) }.to raise_error(ArgumentError, %r{first namevar})
    end
  end

  describe '.run' do
    let(:out) { Dir.mktmpdir }
    let(:config) { File.join(out, 'resources.yaml') }

    before do
      File.write(config, "---\nserver: {}\nlbvserver_service_binding:\n  namevars: [name, servicename]\n")
      described_class.run(oas, rest_dir, config, out)
    end

    after { FileUtils.rm_rf(out) }

    it 'writes a type and a provider per resource, and the metadata' do
      %w[lib/puppet/type/nitro_server.rb lib/puppet/provider/nitro_server/nitro_server.rb
         lib/puppet/type/nitro_lbvserver_service_binding.rb lib/puppet_x/netscaler/specs.rb].each do |file|
        code = File.read(File.join(out, file))
        expect { RubyVM::InstructionSequence.compile(code) }.not_to raise_error, file
      end
    end

    it 'records the NITRO release' do
      expect(File.read(File.join(out, 'lib/puppet_x/netscaler/specs.rb'))).to include('NITRO_VERSION = "99.9-1.1"')
    end

    describe '.compare' do
      # A copy of the fixtures, as a "newer NITRO release" to compare with
      let(:newer) { Dir.mktmpdir }

      before do
        FileUtils.cp_r(File.join(oas, 'pkg'), newer)
      end

      after { FileUtils.rm_rf(newer) }

      def edit_server(&block)
        path = File.join(newer, 'pkg', 'server.yaml')
        File.write(path, block.call(File.read(path)))
      end

      it 'reports nothing for the same definitions' do
        expect(described_class.compare(oas, rest_dir, config, out)).to eq([])
      end

      it 'reports the NITRO release change' do
        edit_server { |y| y.gsub('v1-99.9-1.1', 'v1-99.10-2.2') }
        expect(described_class.compare(newer, rest_dir, config, out)).to eq(['NITRO definitions: 99.9-1.1 -> 99.10-2.2'])
      end

      it 'reports added, removed and changed attributes' do
        edit_server do |y|
          y.sub("          maximum: 4094\n", "          maximum: 8191\n")
           .sub("            - SRV\n", "            - SRV\n            - NS\n")
           .sub("        comment: &comment\n          description: Fixture comment.\n          type: string\n", '')
           .gsub("        comment: *comment\n", '')
           .sub("    update_operation:\n      properties:\n", "    update_operation:\n      properties:\n        td: *td\n        newflag:\n          type: boolean\n")
        end
        report = described_class.compare(newer, rest_dir, config, out)
        expect(report).to include(
          'server.newflag: added (Optional[Boolean], parameter)',
          'server.comment: removed',
          'server.td: type: "Optional[Integer[0, 4094]]" -> "Optional[Integer[0, 8191]]"',
          'server.td: behaviour: "init_only" -> nil',
          'server.td: update: false -> true',
          %q(server.querytype: type: "Optional[Enum['A', 'AAAA', 'SRV']]" -> "Optional[Enum['A', 'AAAA', 'SRV', 'NS']]"),
        )
        expect(report.first).to eq('NITRO definitions: 99.9-1.1 -> 99.9-1.1')
      end

      it 'reports resources missing from the new definitions' do
        FileUtils.rm(File.join(newer, 'pkg', 'lbvserver_service_binding.yaml'))
        expect(described_class.compare(newer, rest_dir, config, out)).to include(%r{\Albvserver_service_binding: cannot be built})
      end

      it 'reports resources configured but not generated yet' do
        File.write(config, "---\nserver: {}\nservice: {}\nlbvserver_service_binding:\n  namevars: [name, servicename]\n")
        expect(described_class.compare(oas, rest_dir, config, out)).to include('service: not generated yet')
      end
    end
  end
end
