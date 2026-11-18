#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate nitro_* Resource API types and providers from the NITRO OpenAPI
# specification (the `config` directory of the nitro-oas tarball) and the
# NITRO REST reference (the `html/config` directory of the nitro-rest tarball,
# used to learn which attributes a GET returns).
#
#   ruby tools/generate.rb <oas/config dir> <rest/html/config dir> tools/resources.yaml <module root>
#
# Compare a (newer) NITRO release with what is committed, without writing:
#
#   ruby tools/generate.rb --diff <oas/config dir> <rest/html/config dir> tools/resources.yaml <module root>
#
# Outputs:
#   lib/puppet_x/netscaler/specs.rb          runtime metadata for all resources
#   lib/puppet/type/nitro_<res>.rb              Resource API type
#   lib/puppet/provider/nitro_<res>/nitro_<res>.rb  thin provider
require 'yaml'
require 'fileutils'
require 'cgi/escape'
require_relative '../lib/puppet_x/netscaler/compat_definitions'

module NitroGenerator
  # Puppet::ResourceApi refuses these attribute names
  RESERVED = %w[title provider alias audit before consume export loglevel noop notify require schedule stage subscribe tag ensure].freeze
  # Attributes that are never managed (rename target, transient flags)
  SKIP = %w[newname].freeze

  # NITRO definitions or resources.yaml settings a type cannot be built from
  # (as opposed to a bug in the generator)
  class DefinitionError < ArgumentError; end

  module_function

  def load_oas(dir, resource)
    path = Dir.glob(File.join(dir, '*', "#{resource}.yaml")).first
    raise DefinitionError, "No OAS file for #{resource} in #{dir}" unless path

    text = File.read(path, encoding: 'UTF-8')
    raise DefinitionError, "#{resource}: #{path} is not valid UTF-8" unless text.valid_encoding?

    parse_yaml(text)
  end

  # Attribute names listed in the "get (all)" response payload of the NITRO
  # REST reference, or nil when the page is missing.
  def load_get_fields(dir, resource)
    path = Dir.glob(File.join(dir, '*', "#{resource}.html")).first
    return nil unless path

    html = File.read(path, encoding: 'UTF-8')
    raise DefinitionError, "#{resource}: #{path} is not valid UTF-8" unless html.valid_encoding?

    text = CGI.unescapeHTML(html.gsub(%r{<[^>]+>}, ' ')).gsub(%r{\s+}, ' ')
    start = text.index('get (all)') || text.index('get URL') or return nil
    payload = text.index('Response Payload', start) or return nil
    segment = text[payload, 30_000]
    segment = segment[0, segment.index(']}') || segment.size]
    # keys are quoted, except the entity keys listed first
    segment.scan(%r{"?(\w+)"?\s*:\s*<}).flatten.uniq
  end

  # The NITRO spec is YAML 1.1: unquoted YES/NO/ON/OFF in enums and
  # defaults would be read as booleans. Keep them as the strings NITRO expects.
  def parse_yaml(text)
    text = text.gsub(%r{^(\s*(?:- |default: ))(YES|NO|Yes|No|yes|no|ON|OFF|On|Off|on|off|Y|N|y|n)[ \t]*$}) { "#{Regexp.last_match(1)}'#{Regexp.last_match(2)}'" }
    YAML.safe_load(text, aliases: true, permitted_classes: [Symbol])
  end

  def puppet_name(api)
    n = api.downcase.gsub(%r{[^a-z0-9_]}, '_')
    n = "nitro_#{n}" if RESERVED.include?(n) || n.match?(%r{\A[^a-z]})
    n
  end

  def clean_desc(text)
    return '' if text.nil?

    text.sub(%r{\A\|\s*\n?}, '').gsub(%r{^\t}, '').strip
  end

  # Terminator of the non-interpolating heredoc (<<-'EOS', <<~'EOS') that
  # holds a free text in a generated file, so backslashes and #{ stay
  # literal: EOS, or EOS1, EOS2... when a line of the text would end it early
  # (Ruby skips any whitespace before the terminator of <<- and <<~, but
  # none after it)
  def heredoc_terminator(text)
    lines = text.lines.map { |line| line.chomp.lstrip }
    terminator = 'EOS'
    count = 0
    terminator = "EOS#{count += 1}" while lines.include?(terminator)
    terminator
  end

  # The NITRO release goes into comments of the generated files: refuse what
  # would break out of them
  def nitro_version(oas, resource)
    version = oas.dig('info', 'version').to_s.delete_prefix('v1-')
    raise DefinitionError, "#{resource}: NITRO version #{version.inspect} does not fit in a comment" if version.match?(%r{[[:cntrl:]]})

    version
  end

  def body_required(operation)
    schema = operation&.dig('requestBody', 'content', 'application/json', 'schema', 'properties')
    return [] unless schema

    schema.values.first.fetch('allOf', []).flat_map { |a| a['required'] || [] }
  end

  def attr_kind(schema)
    case schema['type']
    when 'integer' then 'integer'
    when 'number' then 'number'
    when 'boolean' then 'boolean'
    when 'array' then 'array'
    else 'string'
    end
  end

  # Kind of the elements of an array attribute. Among the attributes that
  # can be set, NITRO lists of integers (Integer[] in the REST reference) are
  # the only ones whose OAS items carry no type, e.g. lbmonitor
  # acctapplicationid: `items: {}`. (Read-only lists such as Double[] ones
  # share that form, but are never generated.)
  def item_kind(schema)
    return nil unless schema['type'] == 'array'

    (schema['items'].is_a?(Hash) && schema['items']['type'].nil?) ? 'integer' : 'string'
  end

  def integer_type(schema)
    if schema['maximum']
      "Integer[#{schema['minimum'] ? schema['minimum'].to_i : 'default'}, #{schema['maximum'].to_i}]"
    elsif schema['minimum']
      "Integer[#{schema['minimum'].to_i}]"
    else
      'Integer'
    end
  end

  def puppet_type(schema)
    enum = schema['enum'] || schema.dig('items', 'enum')
    base = case schema['type']
           when 'integer' then integer_type(schema)
           when 'number' then 'Numeric'
           when 'boolean' then 'Boolean'
           when 'array'
             # The bounds of an integer list apply to its elements
             item = if enum then "Enum[#{enum.map { |e| quote(e) }.join(', ')}]"
                    elsif item_kind(schema) == 'integer' then integer_type(schema)
                    else 'String'
                    end
             "Array[#{item}]"
           else
             enum ? "Enum[#{enum.map { |e| quote(e) }.join(', ')}]" : 'String'
           end
    "Optional[#{base}]"
  end

  def quote(val)
    "'#{val.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")}'"
  end

  # Build the runtime spec for one resource
  def build_spec(resource, oas, cfg, get_fields = nil)
    schemas = oas.dig('components', 'schemas')
    paths = oas['paths']
    coll = paths["/#{resource}"] || {}
    item_path, item = paths.find { |p, _| p.start_with?("/#{resource}/{") }
    raise DefinitionError, "#{resource}: no item path" unless item_path

    key = item_path[%r{\{(.+)\}}, 1]
    actions = oas.dig('components', 'parameters', 'action', 'schema', 'enum') || []
    actions = oas.dig('components', 'parameters', "#{resource}_post_action", 'schema', 'enum') || [] if actions.empty?

    add = schemas.dig('add_operation', 'properties') || {}
    upd = schemas.dig('update_operation', 'properties') || {}
    dis = schemas.dig('disable_operation', 'properties') || {}
    main = schemas.dig(resource, 'properties') || {}

    kind = if cfg['kind'] == 'settings' then 'settings'
           elsif resource.end_with?('_binding') then 'binding'
           else 'entity'
           end
    state_actions = kind == 'entity' && actions.include?('enable') && actions.include?('disable')
    action_updates = cfg.fetch('action_updates', {})
    action_attrs = action_updates.values.flatten
    write_only = cfg.fetch('write_only', [])
    sensitive = cfg.fetch('sensitive', [])
    ordered = cfg.fetch('ordered', [])
    ip_addresses = cfg.fetch('ip_addresses', [])
    init_only_extra = cfg.fetch('init_only', [])

    namevars = cfg['namevars'] || [key]
    raise DefinitionError, "#{resource}: first namevar must be #{key}" unless namevars.first == key

    post = coll['post'] || {}
    create_required = body_required(post) - [key]

    api_attrs = (add.keys + upd.keys + action_attrs + (state_actions ? dis.keys : [])).uniq - SKIP
    attributes = {}
    api_attrs.each do |api|
      schema = add[api] || upd[api] || dis[api] || main[api]
      next if schema.nil? || schema['readOnly']

      pname = if kind == 'binding' || kind == 'settings' || api != key
                puppet_name(api)
              else
                'name'
              end
      pname = 'name' if kind != 'binding' && api == key
      create = kind == 'binding' || add.key?(api)
      update = kind == 'binding' || upd.key?(api) || action_attrs.include?(api) || (state_actions && api == 'state')
      # Attributes GET never returns cannot be compared: send them, never check them
      not_echoed = get_fields && !get_fields.include?(api) && api != 'state' && !create_required.include?(api)
      behaviour = if namevars.include?(api)
                    'namevar'
                  elsif write_only.include?(api) || not_echoed || (state_actions && dis.key?(api) && !add.key?(api) && !upd.key?(api))
                    'parameter'
                  elsif init_only_extra.include?(api) || (kind == 'entity' && create && !update)
                    'init_only'
                  end
      type = puppet_type(schema)
      if sensitive.include?(api)
        raise DefinitionError, "#{resource}: sensitive attribute #{api} is not a string" unless type == 'Optional[String]'

        type = 'Optional[Variant[String, Sensitive[String]]]'
      end
      if behaviour == 'namevar'
        # Title patterns only yield strings, Resource API does not munge them
        type = (attr_kind(schema) == 'integer') ? 'Pattern[/\A\d+\z/]' : type.sub(%r{\AOptional\[(.*)\]\z}, '\1')
      end
      attributes[pname] = {
        'api' => api,
        'kind' => attr_kind(schema),
        'type' => type,
        'desc' => clean_desc(schema['description']),
        'behaviour' => behaviour,
        'create' => create && !(state_actions && dis.key?(api) && !add.key?(api)),
        'update' => update,
        'disable_param' => state_actions && dis.key?(api) && api != key,
      }
      attributes[pname]['items'] = 'integer' if item_kind(schema) == 'integer'
      attributes[pname]['sensitive'] = true if sensitive.include?(api)
      if ip_addresses.include?(api)
        raise DefinitionError, "#{resource}: ip_addresses attribute #{api} is not a string or a list" unless %w[string array].include?(attr_kind(schema))

        attributes[pname]['ip_address'] = true
      end
      next unless ordered.include?(api)
      raise DefinitionError, "#{resource}: ordered attribute #{api} is not a list" unless attr_kind(schema) == 'array'

      attributes[pname]['ordered'] = true
    end
    namevars.each do |nv|
      raise DefinitionError, "#{resource}: namevar #{nv} is not an attribute" unless attributes.values.any? { |a| a['api'] == nv }
    end

    put = item['put'] || coll['put'] || {}
    # DELETE ?args=: required ones are written ` name `, optional ones ***name***
    args_desc = (item.dig('delete', 'parameters') || []).select { |p| p['name'] == 'args' }.map { |p| p['description'].to_s }.join("\n")
    required_delete_args = args_desc.scan(%r{`\s*(\w+)\s*`}).flatten
    delete_args = args_desc.scan(%r{\*\*\*(\w+)\*\*\*}).flatten + required_delete_args
    configured_delete_args = (kind == 'binding') ? (namevars - [key]) + cfg.fetch('delete_args', []) : cfg.fetch('delete_args', [])
    rebind_exclude = cfg.fetch('rebind_exclude', [])
    update_with = cfg.fetch('update_with', {})
    unknown = (rebind_exclude + sensitive + ordered + ip_addresses + update_with.keys + update_with.values.flatten).reject { |a| attributes.values.any? { |at| at['api'] == a } }
    raise DefinitionError, "#{resource}: rebind_exclude/sensitive/ordered/ip_addresses/update_with name unknown attributes #{unknown.join(', ')}" unless unknown.empty?
    raise DefinitionError, "#{resource}: rebind_exclude is only for bindings" if kind != 'binding' && !rebind_exclude.empty?

    {
      'resource' => resource,
      'kind' => kind,
      'key' => key,
      'namevars' => namevars,
      'title_pattern' => cfg['title_pattern'],
      'title_format' => (kind == 'binding') ? (cfg['title_format'] || namevars.map { |n| "%{#{puppet_name(n)}}" }.join('/')) : nil,
      'state_actions' => state_actions,
      'create_required' => create_required,
      'update_required' => body_required(put) - [key],
      'delete_args' => ((configured_delete_args.uniq & (delete_args + namevars)) + required_delete_args).uniq,
      'rebind_exclude' => rebind_exclude,
      'update_with' => update_with,
      'action_updates' => action_updates,
      'autorequire' => autorequires(resource, cfg, attributes),
      'doc' => clean_desc(oas.dig('tags', 0, 'description')),
      'nitro_version' => nitro_version(oas, resource),
      'attributes' => attributes,
    }
  end

  # autorequire: { <NITRO attribute> => [<NITRO resource>, ...] } becomes
  # { 'nitro_<res>' => [...], 'netscaler_<res>' => [...] } of '$<puppet attr>'
  # references, so both families are ordered whatever the manifest mixes.
  def autorequires(resource, cfg, attributes)
    cfg.fetch('autorequire', {}).each_with_object({}) do |(api, targets), result|
      pname = attributes.find { |_n, a| a['api'] == api }&.first
      raise DefinitionError, "#{resource}: autorequire on unknown attribute #{api}" unless pname

      Array(targets).each do |target|
        types = ["nitro_#{target}"]
        # only compat types really backed by that NITRO resource
        # (netscaler_sslvserver is an sslvserver_sslcertkey_binding)
        types << "netscaler_#{target}" if PuppetX::Netscaler::COMPAT.dig("netscaler_#{target}", :nitro) == target
        types.each { |type| (result[type] ||= []) << "$#{pname}" }
      end
    end
  end

  def class_name(type)
    type.split('_').map(&:capitalize).join
  end

  def render_type(spec)
    type = "nitro_#{spec['resource']}"
    lines = []
    lines << '# frozen_string_literal: true'
    lines << ''
    lines << "# This file is generated by tools/generate.rb from the NetScaler NITRO API definitions #{spec['nitro_version']}"
    lines << '# (nitro-oas.tgz and nitro-rest.tgz, downloaded from a NetScaler VPX appliance). Do not edit.'
    lines << "require 'puppet/resource_api'"
    lines << ''
    lines << 'Puppet::ResourceApi.register_type('
    lines << "  name: '#{type}',"
    docs = []
    docs << "@summary Manages NITRO `#{spec['resource']}` resources (#{spec['kind']})."
    docs << ''
    docs << "#{spec['doc']} Attributes map 1:1 onto the NITRO `#{spec['resource']}` API, see the NITRO reference."
    docs << ' Only attributes set in the manifest are managed.'
    docs << ''
    docs << if spec['kind'] == 'binding'
              "The title is split into #{spec['namevars'].map { |n| "`#{n}`" }.join(', ')}."
            elsif spec['kind'] == 'settings'
              'This entity cannot be created or deleted; it exists together with its parent and only its settings are managed.'
            else
              "The title is the NITRO `#{spec['key']}`."
            end
    docs = docs.join("\n")
    terminator = heredoc_terminator(docs)
    lines << "  docs: <<-'#{terminator}',"
    lines << docs
    lines << "  #{terminator}"
    # canonicalize sorts NITRO lists, and adds the composite :title of bindings
    lines << "  features: ['remote_resource', 'simple_get_filter', 'canonicalize'],"
    if spec['kind'] == 'binding'
      nvs = spec['namevars'].map { |n| NitroGenerator.puppet_name(n) }
      pattern = spec['title_pattern'] || "\\A#{nvs.map { |n| "(?<#{n}>[^/]+)" }.join('/')}\\z"
      lines << '  title_patterns: ['
      lines << "    { pattern: %r{#{pattern}}, desc: 'Composite title' },"
      lines << "    { pattern: %r{\\A(?<#{nvs.first}>.*)\\z}, desc: 'Only the #{nvs.first}' },"
      lines << '  ],'
    end
    unless spec['autorequire'].empty?
      lines << '  autorequire: {'
      spec['autorequire'].each { |target_type, refs| lines << "    #{target_type}: #{(refs.size == 1) ? quote(refs.first) : "[#{refs.map { |r| quote(r) }.join(', ')}]"}," }
      lines << '  },'
    end
    lines << '  attributes: {'
    unless spec['kind'] == 'settings'
      lines << '    ensure: {'
      lines << "      type: 'Enum[present, absent]',"
      lines << "      desc: 'Whether this resource should be present or absent on the NetScaler.',"
      lines << "      default: 'present',"
      lines << '    },'
    end
    spec['attributes'].sort_by { |n, a| [(a['behaviour'] == 'namevar') ? 0 : 1, spec['namevars'].index(a['api']) || 0, n] }.each do |name, a|
      desc = a['desc'].empty? ? "NITRO attribute `#{a['api']}`." : a['desc']
      desc += " (NITRO: `#{a['api']}`)" if name != a['api']
      lines << "    #{name}: {"
      lines << "      type: #{a['type'].inspect},"
      lines << "      desc: #{desc.inspect},"
      lines << "      behaviour: :#{a['behaviour']}," if a['behaviour']
      lines << '    },'
    end
    lines << '  },'
    lines << ')'
    lines.concat(render_sensitive(type, spec['attributes']))
    lines.concat(render_get_cache(type))
    "#{lines.join("\n")}\n"
  end

  # Resource API >= 2.0 keeps a get() cache on the type class for the whole
  # process, never cleared: in one `puppet device` run, a device would see the
  # state cached for the previous one, and writes do not invalidate it. The
  # transport already keeps one listing per type and device, so the types
  # opt out of it and behave like on Resource API 1.9 (OpenVox 8).
  def render_get_cache(type)
    [
      '',
      '# The transport caches the NITRO listings per device; no Resource API get cache',
      "if Puppet::Type.type(:#{type}).respond_to?(:rsapi_provider_get_cache)",
      "  Puppet::Type.type(:#{type}).define_singleton_method(:rsapi_provider_get_cache) { Puppet::ResourceApi::ProviderGetCache.new }",
      'end',
    ]
  end

  # Secrets: Puppet redacts the events of the properties, also when the
  # manifest passes a plain String. Parameters never show up in events, so
  # Puppet is not asked to redact them (it would warn on every run).
  def render_sensitive(type, attributes)
    secrets = attributes.select { |_n, a| a['sensitive'] }
    return [] if secrets.empty?

    params, props = secrets.keys.sort.partition { |n| secrets[n]['behaviour'] == 'parameter' }
    symbols = ->(names) { "%i[#{names.join(' ')}]" }
    [
      '',
      '# Redact the secrets in events, also when given as a plain String',
      "Puppet::Type.type(:#{type}).class_eval do",
      '  def set_sensitive_parameters(sensitive_parameters)',
      "    super((sensitive_parameters - #{symbols.call(params)}) | #{symbols.call(props)}.select { |n| parameter(n) })",
      '  end',
      'end',
    ]
  end

  def render_provider(spec)
    type = "nitro_#{spec['resource']}"
    cls = class_name(type)
    <<~RUBY
      # frozen_string_literal: true

      # This file is generated by tools/generate.rb from the NetScaler NITRO API definitions #{spec['nitro_version']}
      # (nitro-oas.tgz and nitro-rest.tgz, downloaded from a NetScaler VPX appliance). Do not edit.
      require_relative '../../../puppet_x/netscaler/nitro_provider'

      # Provider for #{type}
      module Puppet::Provider::#{cls}
        # Implementation for the #{type} type using the NITRO REST API
        class #{cls} < PuppetX::Netscaler::NitroProvider
          def self.nitro_resource
            '#{spec['resource']}'
          end
        end
      end
    RUBY
  end

  # What a NITRO change can affect, per resource and per attribute
  SPEC_FIELDS = %w[kind key namevars create_required update_required delete_args rebind_exclude update_with state_actions action_updates title_format autorequire].freeze
  ATTRIBUTE_FIELDS = %w[api kind items ordered ip_address type behaviour create update disable_param].freeze

  def build_all(oas_dir, rest_dir, config_file)
    config = YAML.safe_load_file(config_file) || {}
    config.map do |res, cfg|
      fields = load_get_fields(rest_dir, res)
      warn "#{res}: no NITRO REST reference page, every attribute is compared" unless fields
      build_spec(res, load_oas(oas_dir, res), cfg || {}, fields)
    end
  end

  # The committed metadata, with the data types read back from the committed
  # type files (specs.rb does not keep them). Evaluated in a throw-away module
  # so it never clashes with a loaded PuppetX::Netscaler.
  def committed_specs(root)
    sandbox = Module.new
    sandbox.module_eval(File.read(File.join(root, 'lib/puppet_x/netscaler/specs.rb')))
    netscaler = sandbox.const_get(:PuppetX).const_get(:Netscaler)
    version = netscaler.const_defined?(:NITRO_VERSION) ? netscaler.const_get(:NITRO_VERSION) : nil
    specs = netscaler.const_get(:SPECS).to_h do |resource, spec|
      type_file = File.join(root, "lib/puppet/type/nitro_#{resource}.rb")
      types = File.exist?(type_file) ? File.read(type_file).scan(%r{^    (\w+): \{\n      type: ("(?:[^"\\]|\\.)*"),}).to_h { |n, t| [n, t.undump] } : {}
      attributes = spec['attributes'].to_h { |name, a| [name, a.merge('type' => types[name])] }
      [resource, spec.merge('attributes' => attributes)]
    end
    [version, specs]
  end

  # Human-readable differences between the committed definitions and the ones
  # built from another NITRO release. Empty when nothing changed.
  def compare(oas_dir, rest_dir, config_file, root)
    old_version, committed = committed_specs(root)
    config = YAML.safe_load_file(config_file) || {}
    report = []
    fresh = config.filter_map do |res, cfg|
      build_spec(res, load_oas(oas_dir, res), cfg || {}, load_get_fields(rest_dir, res))
    rescue DefinitionError => e
      report << "#{res}: cannot be built from these definitions (#{e.message})"
      nil
    end
    new_version = fresh.first&.fetch('nitro_version')
    fresh.each do |spec|
      old = committed[spec['resource']]
      if old.nil?
        report << "#{spec['resource']}: not generated yet"
        next
      end
      report.concat(diff_spec(old, spec))
    end
    (committed.keys - config.keys).each { |res| report << "#{res}: generated but no longer in #{File.basename(config_file)}" }
    report.unshift("NITRO definitions: #{old_version || 'unknown'} -> #{new_version || 'unknown'}") unless report.empty? && old_version == new_version
    report
  end

  def diff_spec(old, new)
    res = new['resource']
    lines = SPEC_FIELDS.reject { |f| old[f] == new[f] }.map { |f| "#{res}: #{f}: #{old[f].inspect} -> #{new[f].inspect}" }
    old_attrs = old['attributes']
    new_attrs = new['attributes']
    (new_attrs.keys - old_attrs.keys).sort.each { |a| lines << "#{res}.#{a}: added (#{new_attrs[a]['type']}, #{new_attrs[a]['behaviour'] || 'property'})" }
    (old_attrs.keys - new_attrs.keys).sort.each { |a| lines << "#{res}.#{a}: removed" }
    (old_attrs.keys & new_attrs.keys).sort.each do |a|
      ATTRIBUTE_FIELDS.each do |f|
        lines << "#{res}.#{a}: #{f}: #{old_attrs[a][f].inspect} -> #{new_attrs[a][f].inspect}" unless old_attrs[a][f] == new_attrs[a][f]
      end
    end
    lines
  end

  def render_specs(specs)
    body = specs.map do |s|
      clean = s.merge('attributes' => s['attributes'].transform_values { |a| a.except('desc', 'type') })
      "    #{s['resource'].inspect} => #{deep_freeze_literal(clean, 4)},"
    end
    <<~RUBY
      # frozen_string_literal: true

      # This file is generated by tools/generate.rb from the NetScaler NITRO API definitions #{specs.first&.fetch('nitro_version')}
      # (nitro-oas.tgz and nitro-rest.tgz, downloaded from a NetScaler VPX appliance). Do not edit.
      module PuppetX
        module Netscaler
          # NITRO release the definitions were generated from
          NITRO_VERSION = #{specs.first&.fetch('nitro_version').inspect}

          # Runtime metadata of every generated NITRO resource
          SPECS = {
      #{body.join("\n")}
          }.freeze
        end
      end
    RUBY
  end

  def deep_freeze_literal(obj, indent)
    pad = ' ' * (indent + 2)
    case obj
    when Hash
      return '{}.freeze' if obj.empty?

      inner = obj.map { |k, v| "#{pad}#{k.inspect} => #{deep_freeze_literal(v, indent + 2)}," }
      "{\n#{inner.join("\n")}\n#{' ' * indent}}.freeze"
    when Array
      "#{obj.inspect}.freeze"
    else
      obj.inspect
    end
  end

  def run(oas_dir, rest_dir, config_file, root)
    specs = build_all(oas_dir, rest_dir, config_file)
    # Render everything first, so a render error writes nothing
    files = { 'lib/puppet_x/netscaler/specs.rb' => render_specs(specs) }
    specs.each do |spec|
      type = "nitro_#{spec['resource']}"
      files["lib/puppet/type/#{type}.rb"] = render_type(spec)
      files["lib/puppet/provider/#{type}/#{type}.rb"] = render_provider(spec)
    end
    files.keys.map { |path| File.dirname(File.join(root, path)) }.uniq.each { |dir| FileUtils.mkdir_p(dir) }
    files.each { |path, content| File.write(File.join(root, path), content) }
    specs
  end
end

if $PROGRAM_NAME == __FILE__
  diff = ARGV.delete('--diff')
  abort "usage: #{$PROGRAM_NAME} [--diff] <oas config dir> <rest html config dir> <resources.yaml> <module root>" unless ARGV.size == 4
  if diff
    report = NitroGenerator.compare(*ARGV)
    puts report.empty? ? 'No difference with the committed definitions' : report
    exit(report.empty? ? 0 : 1)
  end
  specs = NitroGenerator.run(*ARGV)
  puts "Generated #{specs.size} types"
end
