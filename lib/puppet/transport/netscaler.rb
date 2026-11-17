# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'erb'

module Puppet::Transport
  # NITRO REST client. Only depends on the Ruby standard library so it runs
  # inside the openvox agent on the proxy host.
  class Netscaler
    # Raised for any NITRO error response
    class Error < StandardError
      attr_reader :status, :errorcode

      def initialize(message, status: nil, errorcode: nil)
        super(message)
        @status = status
        @errorcode = errorcode
      end
    end

    # NITRO error codes meaning "the entity you asked for does not exist"
    # (see errorlisting.html in the NITRO REST reference): No such resource,
    # No Service, No such server/Vserver/service/serviceGroup, No such LB
    # vserver, Certificate does not exist
    NOT_FOUND_CODES = [258, 344, 351, 461, 462, 463, 1367, 1540].freeze
    BASE_PATH = '/nitro/v1/config'
    STAT_PATH = '/nitro/v1/stat'
    # Flat facts reported by puppetlabs-netscaler, by NITRO source
    LEGACY_CONFIG_FACTS = %w[ipaddress netmask systemtype primaryip timezone lastconfigchangedtime lastconfigsavetime systemtime].freeze
    LEGACY_STAT_FACTS = %w[cpuusage memuseinmb numcpus starttime].freeze

    attr_reader :host, :port

    def initialize(_context, connection_info)
      @host = connection_info[:host]
      @ssl = connection_info.fetch(:ssl, true)
      @port = connection_info[:port] || (@ssl ? 443 : 80)
      @ssl_verify = connection_info.fetch(:ssl_verify, true)
      @ca_file = connection_info[:ca_file]
      @user = connection_info[:user]
      @password = unwrap(connection_info[:password])
      @timeout = connection_info.fetch(:timeout, 60)
      @save_config = connection_info.fetch(:save_config, true)
      @prefetch = connection_info.fetch(:prefetch, true)
      @http = nil
      @snapshots = {}
    end

    def prefetch?
      @prefetch
    end

    # Full listing of a NITRO resource type, fetched once per connection (one
    # Puppet run against this device) by the given block
    def snapshot(resource)
      return @snapshots[resource] if @snapshots.key?(resource)

      @snapshots[resource] = yield
    end

    # Forget a listing after Puppet changed that resource type
    def invalidate(resource)
      @snapshots.delete(resource)
    end

    def save_config?
      @save_config
    end

    def verify(_context)
      get('nsversion')
      true
    end

    # Facts of the appliance. Puppet 8 style structured facts, plus the
    # flat facts puppetlabs-netscaler reported (deprecated, kept so existing
    # manifests such as `$facts['operatingsystem'] == 'Netscaler'` still work).
    # No other legacy facts (osfamily, operatingsystemrelease, ...) are
    # reported. Only nsversion is mandatory: the other sources are skipped
    # when the NITRO user cannot read them.
    def facts(_context)
      version = first_entity(get('nsversion'), 'nsversion')['version'].to_s
      config = optional_entity('nsconfig') { get('nsconfig') }
      stats = optional_entity('ns') { get_stat('ns') }
      hardware = optional_entity('nshardware') { get('nshardware') }
      hostname = optional_entity('nshostname') { get('nshostname') }['hostname']
      mac = primary_mac

      structured_facts(version, config, hardware, hostname, mac).merge(legacy_facts(version, config, stats, mac))
    end

    def close(_context = nil)
      @http&.finish if @http&.started?
      @http = nil
    end

    # GET /nitro/v1/config/<resource>[/<key>]. Returns the parsed body or nil
    # when the entity does not exist.
    def get(resource, key = nil, query = {})
      request(:get, path(resource, key), query: query)
    rescue Error => e
      return nil if e.status == 404 || NOT_FOUND_CODES.include?(e.errorcode)

      raise
    end

    # GET /nitro/v1/stat/<resource>
    def get_stat(resource)
      request(:get, "#{STAT_PATH}/#{resource}")
    end

    def post(resource, payload, query = {})
      request(:post, path(resource), query: query, body: { resource => payload })
    end

    def put(resource, payload, key = nil)
      request(:put, path(resource, key), body: { resource => payload })
    end

    def delete(resource, key, args = {})
      query = args.empty? ? {} : { 'args' => format_args(args) }
      request(:delete, path(resource, key), query: query)
    end

    # POST /config/<resource>?action=<action>
    def action(resource, action, payload)
      post(resource, payload, 'action' => action)
    end

    def save
      action('nsconfig', 'save', {})
    end

    # "NetScaler NS14.1: Build 73.58.nc, Date: ..." => 14.1-73.58
    def self.parse_release(version)
      m = version.match(%r{NS(\d+)\.(\d+):?\s*Build\s+(\d+(?:\.\d+)*)}i)
      return nil unless m

      { 'full' => "#{m[1]}.#{m[2]}-#{m[3]}", 'major' => m[1], 'minor' => m[2] }
    end

    def self.escape(value)
      ERB::Util.url_encode(value.to_s)
    end

    def path(resource, key = nil)
      p = "#{BASE_PATH}/#{resource}"
      p += "/#{self.class.escape(key)}" unless key.nil?
      p
    end

    # NITRO "args"/"filter" format: key:value,key:value with url-encoded values
    def format_args(args)
      args.map { |k, v| "#{k}:#{self.class.escape(v)}" }.join(',')
    end

    private

    # Singleton entities come back either as an object or a one element list
    def first_entity(body, resource)
      value = (body || {})[resource]
      value = value.first if value.is_a?(Array)
      value.is_a?(Hash) ? value : {}
    end

    def structured_facts(version, config, hardware, hostname, mac)
      {
        'os' => { 'name' => 'NetScaler', 'family' => 'NetScaler', 'release' => self.class.parse_release(version) }.compact,
        'networking' => { 'hostname' => hostname, 'ip' => config['ipaddress'], 'netmask' => config['netmask'], 'mac' => mac }.compact,
        'netscaler' => {
          'version' => version,
          'hardware' => hardware['hwdescription'],
          'serialnumber' => hardware['serialno'],
          'systemtype' => config['systemtype'],
          'primaryip' => config['primaryip'],
          'timezone' => config['timezone'],
        }.compact,
      }
    end

    def legacy_facts(version, config, stats, mac)
      facts = LEGACY_CONFIG_FACTS.to_h { |f| [f, config[f]] }
      facts.merge!(LEGACY_STAT_FACTS.to_h { |f| [f, stats[f]] })
      facts.merge('version' => version, 'macaddress' => mac, 'operatingsystem' => 'Netscaler').compact
    end

    # MAC address of the first data interface (skips loopback LO/x)
    def primary_mac
      interfaces = Array(get('Interface')&.fetch('Interface', nil))
      interface = interfaces.find { |i| !i['id'].to_s.start_with?('LO') && !i['mac'].to_s.empty? } || interfaces.first
      interface&.fetch('mac', nil)
    rescue Error => e
      Puppet.debug("NetScaler facts: cannot read Interface: #{e.message}")
      nil
    end

    # Optional facts sources: a NITRO user without access to one of them
    # still gets the other facts
    def optional_entity(resource)
      first_entity(yield, resource)
    rescue Error => e
      Puppet.debug("NetScaler facts: cannot read #{resource}: #{e.message}")
      {}
    end

    def unwrap(value)
      value.respond_to?(:unwrap) ? value.unwrap : value
    end

    def http
      return @http if @http&.started?

      @http = Net::HTTP.new(@host, @port)
      @http.use_ssl = @ssl
      if @ssl
        @http.verify_mode = @ssl_verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
        @http.ca_file = @ca_file if @ca_file
      end
      @http.open_timeout = @timeout
      @http.read_timeout = @timeout
      @http.start
    end

    def request(method, path, query: {}, body: nil)
      uri = path.dup
      # args/filter values are already encoded; keep their ':' and ',' separators
      uri += "?#{query.map { |k, v| "#{k}=#{v}" }.join('&')}" unless query.empty?
      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, delete: Net::HTTP::Delete }.fetch(method)
      req = klass.new(uri)
      req['X-NITRO-USER'] = @user
      req['X-NITRO-PASS'] = @password
      req['Accept'] = 'application/json'
      if body
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
      end
      Puppet.debug("NITRO #{method.upcase} #{uri}") if defined?(Puppet)
      handle(http.request(req), method, uri)
    end

    def handle(response, method, uri)
      data = parse(response.body)
      status = response.code.to_i
      errorcode = data['errorcode'].to_i
      if status >= 400 || (errorcode != 0 && data['severity'].to_s.upcase == 'ERROR')
        msg = data['message'] || response.message
        raise Error.new("NITRO #{method.upcase} #{uri} failed (HTTP #{status}, errorcode #{errorcode}): #{msg}",
                        status: status, errorcode: errorcode)
      end
      data
    end

    def parse(body)
      return {} if body.nil? || body.strip.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      { 'message' => body.strip }
    end
  end
end
