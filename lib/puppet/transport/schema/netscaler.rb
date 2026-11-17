# frozen_string_literal: true

require 'puppet/resource_api'

Puppet::ResourceApi.register_transport(
  name: 'netscaler',
  desc: <<~EOS,
    Connects to a NetScaler (Citrix ADC) appliance through the NITRO REST API (/nitro/v1).
  EOS
  features: [],
  connection_info: {
    host: {
      type: 'String',
      desc: 'Hostname or IP address of the NetScaler management interface (NSIP/SNIP).',
    },
    port: {
      type: 'Optional[Integer[1, 65535]]',
      desc: 'TCP port of the NITRO API. Defaults to 443 (or 80 when `ssl` is false).',
    },
    ssl: {
      type: 'Boolean',
      desc: 'Use HTTPS to connect to the appliance.',
      default: true,
    },
    ssl_verify: {
      type: 'Boolean',
      desc: 'Verify the TLS certificate of the appliance.',
      default: true,
    },
    ca_file: {
      type: 'Optional[String]',
      desc: 'Path to a CA bundle used to verify the appliance certificate.',
    },
    user: {
      type: 'String',
      desc: 'NITRO user name.',
    },
    password: {
      type: 'String',
      desc: 'NITRO password.',
      sensitive: true,
    },
    timeout: {
      type: 'Integer[1]',
      desc: 'HTTP open/read timeout in seconds.',
      default: 60,
    },
    prefetch: {
      type: 'Boolean',
      desc: 'Fetch each NITRO resource type once per run (one bulk GET) instead of one GET per managed object.',
      default: true,
    },
    save_config: {
      type: 'Boolean',
      desc: 'Save the running configuration (`save ns config`) after Puppet changed something.',
      default: true,
    },
  },
)
