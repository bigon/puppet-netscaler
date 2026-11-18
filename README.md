# netscaler

Manage NetScaler (Citrix ADC) configuration with Puppet through the NITRO REST
API (`/nitro/v1/config`).

This module is a NITRO-based successor of, and drop-in replacement for,
[puppetlabs-netscaler](https://github.com/puppetlabs/puppetlabs-netscaler): it
has the same module name, the same `netscaler` device type and the same
`netscaler_*` types.

The module has two layers:

* **`nitro_*` types** are generated from the official NITRO OpenAPI
  specification (firmware 14.1-73.58). Type and attribute names map 1:1 onto
  the NITRO API, so the NITRO reference documentation applies directly.
* **`netscaler_*` types** are a compatibility layer for manifests written for
  [puppetlabs-netscaler](https://github.com/puppetlabs/puppetlabs-netscaler).
  They keep the old type names, attribute names and value spellings, and run on
  the same engine as the `nitro_*` types.

Everything runs through `puppet device` (or Bolt/agentless runs using the
`netscaler` transport). The client uses only the Ruby standard library, so you
don't need to install any extra gem on the proxy agent.

## Setup

On the proxy agent, declare the device in `device.conf`:

```ini
[ns01.example.com]
type netscaler
url file:///etc/puppetlabs/puppet/devices/ns01.example.com.conf
```

Then put the connection info in that file (HOCON or JSON):

```hocon
host: ns01.example.com
user: nsroot
password: secret
# port: 443            # default 443, or 80 when ssl is false
# ssl: true
# ssl_verify: true
# ca_file: /etc/pki/tls/certs/netscaler-ca.pem
# timeout: 60
# save_config: true    # run "save ns config" after a run that changed something
# prefetch: true       # list each NITRO type once per run instead of one GET per object
```

For migrations, the legacy puppetlabs-netscaler URL form is still accepted:
`url https://nsroot:secret@ns01.example.com/nitro/v1/`. Options can be passed as
query parameters (`?ssl_verify=false&save_config=false&prefetch=false`).

Run `puppet device -v --target ns01.example.com`, sign the certificate, and
classify the node `ns01.example.com` like any other node.

## Usage

```puppet
nitro_server { 'web1':
  ipaddress => '10.0.10.11',
}

nitro_servicegroup { 'sg_web':
  servicetype => 'HTTP',
}

# Title: <servicegroupname>/<servername>:<port>
nitro_servicegroup_servicegroupmember_binding { 'sg_web/web1:80':
  weight => 10,
}

nitro_lbvserver { 'vs_web':
  servicetype => 'HTTP',
  ipv46       => '192.0.2.10',
  port        => 80,
  lbmethod    => 'LEASTCONNECTION',
  state       => 'ENABLED',
}

# Title: <name>/<servicegroupname>
nitro_lbvserver_servicegroup_binding { 'vs_web/sg_web': }
```

See [examples/](examples/) for complete manifests, including a legacy one.

`puppet device --resource nitro_lbvserver --target ns01.example.com` lists the
existing objects in Puppet DSL.

### Facts

The device reports Puppet 8 style structured facts:

| Fact | Example |
|---|---|
| `os.name`, `os.family` | `NetScaler` |
| `os.release.full`, `.major`, `.minor` | `14.1-73.58`, `14`, `1` |
| `networking.hostname`, `.ip`, `.netmask`, `.mac` | NSIP, netmask and MAC of the first data interface |
| `netscaler.version` | full NITRO version string |
| `netscaler.hardware`, `.serialnumber`, `.systemtype`, `.primaryip`, `.timezone` | |

For compatibility, it also reports the flat facts of puppetlabs-netscaler,
unchanged: `operatingsystem` (spelled `Netscaler`, as the old module did),
`version`, `ipaddress`, `netmask`, `macaddress`, `systemtype`, `primaryip`,
`timezone`, `lastconfigchangedtime`, `lastconfigsavetime`, `systemtime`,
`cpuusage`, `memuseinmb`, `numcpus` and `starttime`. They are deprecated: use
the structured facts in new code, for example
`$facts['os']['name'] == 'NetScaler'`.

Facts the NITRO user is not allowed to read are left out instead of failing
the run.

### Semantics

* **Only attributes set in the manifest are managed.** Defaults on the
  appliance are never unset behind your back.
* **Create-only attributes** (for example `servicetype`, `port` or `td` on a
  vserver) are `init_only`. Changing them fails with an explicit error instead
  of silently recreating the object.
* **`state`** (`ENABLED`/`DISABLED`) is applied with the NITRO enable and
  disable actions. On `nitro_server` and `nitro_service`, `delay` and
  `graceful` are passed along when disabling.
* **Bindings** take composite titles (`<bound-to>/<bound>`). NITRO cannot
  modify a binding in place, so a changed binding attribute (for example
  `weight`) is unbound and bound again.
* **Lists** (for example `nitro_lbmonitor` `respcode`) are unordered sets in
  NITRO: they are compared sorted, so a different order is not a change.
  The exception is `nitro_lbvserver` `persistavpno` (`netscaler_lbvserver`
  `persist_avp_no`), nested AVP numbers listed from parent to child: its
  order is kept and compared.
* **Write-only secrets** (`lbmonitor` `password`/`secondarypassword`/`radkey`,
  `sslcertkey` `passplain`) are sent but never compared, because NITRO does not
  return them.
* **Secrets accept `Sensitive`**: `lbmonitor` `password`, `secondarypassword`,
  `radkey`, `snmpcommunity` and `secureargs`, `sslcertkey` `passplain`, and their
  `netscaler_*` counterparts. Their values are redacted in logs, reports and
  debug output, also when given as a plain String. Wrapping them in
  `Sensitive()` also marks them as sensitive when the catalog is compiled.
* **`sslcertkey`**: a change to `cert`/`key` is applied with
  `update ssl certkey` (the NITRO `update` action). `linkcertkeyname` uses the
  `link` action.
* **`sslvserver`** is a settings object: it has no `ensure`, and it exists as
  soon as its SSL vserver exists.
* **Cipher bindings**: `nitro_sslvserver_sslciphersuite_binding` binds a cipher
  group, a predefined alias (such as `DEFAULT`) or an individual cipher to an
  SSL vserver.
* **Ordering**: bindings are applied after the entities they bind, and a
  service after its server, without explicit `require`. This works across both
  families: a `nitro_*` binding waits for a `netscaler_*` vserver and the other
  way round. The compat types keep the autorequires of puppetlabs-netscaler.
* **Prefetch**: with `prefetch: true` (the default), each NITRO type is listed
  once per run (`GET /config/<type>`, or `?bulkbindings=yes` for bindings),
  and every lookup, including "does not exist yet", is answered from that
  listing. A change Puppet makes refreshes the listing of that type. If the
  NITRO user may not list a whole type, that type falls back to one GET per
  object. Set `prefetch: false` for a device to always use one GET per
  object, for example when it holds many objects of which Puppet manages few.
* **Saving**: with `save_config: true` (the default), the configuration is saved
  once, at the end of the run, if anything changed.

### Available types

| NITRO-native | puppetlabs-netscaler compatible |
|---|---|
| `nitro_server` | `netscaler_server` |
| `nitro_service` | `netscaler_service` |
| `nitro_servicegroup` | `netscaler_servicegroup` |
| `nitro_servicegroup_servicegroupmember_binding` | `netscaler_servicegroup_member` |
| `nitro_lbvserver` | `netscaler_lbvserver` |
| `nitro_lbvserver_service_binding` | `netscaler_lbvserver_service_binding` |
| `nitro_lbvserver_servicegroup_binding` | `netscaler_lbvserver_servicegroup_binding` |
| `nitro_lbmonitor` | `netscaler_lbmonitor` |
| `nitro_service_lbmonitor_binding` | `netscaler_service_lbmonitor_binding` |
| `nitro_servicegroup_lbmonitor_binding` | `netscaler_servicegroup_lbmonitor_binding` |
| `nitro_csvserver` | `netscaler_csvserver` |
| `nitro_csvserver_lbvserver_binding` | (`netscaler_csvserver` `default_lbvserver`) |
| `nitro_cspolicy` | `netscaler_cspolicy` |
| `nitro_csaction` | `netscaler_csaction` |
| `nitro_csvserver_cspolicy_binding` | `netscaler_csvserver_cspolicy_binding` |
| `nitro_sslcertkey` | `netscaler_sslcertkey` |
| `nitro_sslvserver` | |
| `nitro_sslvserver_sslcertkey_binding` | `netscaler_sslvserver` (it was a binding) |
| `nitro_sslvserver_sslciphersuite_binding` | |

## Migrating from puppetlabs-netscaler

1. Replace puppetlabs-netscaler with this module (in your `Puppetfile`, for
   example). Both are called `netscaler`, so only one can be installed.
2. Keep the existing `device.conf`. The legacy URL form is still accepted, but
   the appliance's certificate is now verified (see "Known differences"
   below). If the appliance uses a self-signed certificate, append
   `?ssl_verify=false` to the URL, or better, switch to a HOCON config with
   `ca_file`.
3. Keep `include netscaler` on the proxy agent if you have it. The class still
   exists but does nothing, because the faraday gems are no longer needed. You
   can uninstall them.
4. Existing `netscaler_*` resources keep working. The old value spellings
   (`true`, `yes`, `on`, `ENABLED`, ...) and numeric strings (`port => '80'`)
   are accepted.
5. Port manifests to the `nitro_*` types whenever convenient.

Known differences:

* Attributes that no longer exist in NITRO 14.1 are accepted but ignored, with
  a warning: `sure_connect`, `priority_queuing` and `http_compression`, the
  classic `cspolicy` `domain`/`url` (use `expression`), and `purge_bindings`.
* The 31 other puppetlabs-netscaler types (`netscaler_nsip`,
  `netscaler_rewritepolicy`, `netscaler_responderpolicy`, `netscaler_vlan`,
  `netscaler_route`, `netscaler_user`, `netscaler_file`, ...) have no
  compatibility type yet.
* Changes are saved by default (`save_config`). The old module never saved.
* The TLS certificate of the appliance is verified by default (`ssl_verify`),
  for the legacy URL form too. This is a deliberate change: puppetlabs-netscaler
  never verified it, so anyone able to intercept the connection could read the
  credentials. To get the old behaviour back, disable verification explicitly,
  either in the legacy URL
  (`url https://nsroot:secret@ns01.example.com/nitro/v1/?ssl_verify=false`) or
  with `ssl_verify: false` in the HOCON config. The safer option is to keep
  verification on and point `ca_file` at the CA that signed the appliance's
  certificate (or at the self-signed certificate itself). `ca_file` is only
  available in the HOCON config, not as a legacy URL parameter.

## Adding NITRO resources

The `nitro_*` types are generated. To support another NITRO resource:

1. Extract the NITRO OpenAPI tarball (`nitro-oas.tgz`) and add the resource to
   [tools/resources.yaml](tools/resources.yaml). Bindings need `namevars`.
   Look at the file header for the other knobs (`write_only`, `sensitive`,
   `action_updates`, `init_only`, `kind: settings`, ...).
2. Regenerate the types (see below for the two input directories).

3. Run the tests. `spec/unit/puppet/type/types_spec.rb` covers every generated
   type automatically.

The generator also reads the NITRO REST reference (`nitro-rest.tgz`) to find
the attributes a GET never returns (for example `service` `ip`). Those become
parameters, so they are sent but never compared. Pass both directories:

```console
rake generate OAS=/path/to/nitro-oas/config REST=/path/to/nitro-rest/html/config
```

When a new NetScaler release (and new NITRO tarballs) comes out, compare it
with what is committed before regenerating:

```console
rake generate:diff OAS=/path/to/nitro-oas/config REST=/path/to/nitro-rest/html/config
```

It writes nothing. It prints the NITRO release change and, per resource,
attributes added or removed and changes of data type (ranges, allowed values),
of create/update behaviour and of keys, and exits with 1 when something
differs. `lib/puppet_x/netscaler/specs.rb` records the release the committed
definitions come from (`NITRO_VERSION`).

The test fixtures under `spec/fixtures/` are hand-written: they only mimic the
structure of the NITRO files, so no NITRO documentation is copied into the
repository.

Don't edit the generated files (`lib/puppet/type/nitro_*.rb`,
`lib/puppet/provider/nitro_*`, `lib/puppet_x/netscaler/specs.rb`) by hand.
The compatibility types are generated from
`lib/puppet_x/netscaler/compat_definitions.rb` with `rake generate:compat`.
After that, regenerate `REFERENCE.md` with `rake strings:generate:reference`.

## Credits and provenance

* The `netscaler_*` compatibility types are derived from
  [puppetlabs-netscaler](https://github.com/puppetlabs/puppetlabs-netscaler)
  (Copyright 2014 Puppet, Inc., Apache-2.0): type and attribute names,
  attribute mappings onto NITRO, value spellings and autorequires.
* The `nitro_*` types are generated by `tools/generate.rb` from the NetScaler
  NITRO API definitions of NetScaler 14.1 build 73.58: the OpenAPI
  specification (`nitro-oas.tgz`) and the REST API reference
  (`nitro-rest.tgz`), downloaded directly from a NetScaler VPX appliance. The
  release is recorded as `NITRO_VERSION` in `lib/puppet_x/netscaler/specs.rb`
  and in the header of every generated file. The archives themselves are not
  part of this module.

See [NOTICE](NOTICE).

## Development

Tests run in the Vox Pupuli voxbox container:

```console
podman run --rm -v $PWD:/repo:Z -w /repo ghcr.io/voxpupuli/voxbox:10.1.1-openvox8 spec
podman run --rm -v $PWD:/repo:Z -w /repo ghcr.io/voxpupuli/voxbox:10.1.1-openvox8 rubocop
```

With Bundler, `PUPPET_RESOURCE_API_VERSION` selects the Resource API release
(1.8.16 is taken from its git tag, it was never published on rubygems.org) and
`OPENVOX_GEM_VERSION` the openvox gem. The openvox gems 8.24 to 8.33 accept
only 1.9.2 or later, so test older releases with openvox 8.23.1, as CI does:

```console
OPENVOX_GEM_VERSION=8.23.1 PUPPET_RESOURCE_API_VERSION=1.8.16 bundle exec rake spec
```

## Limitations

* The tests mock all HTTP traffic. The module has not yet been validated
  against a live appliance.
* Requires Puppet or OpenVox 8 or newer. The unit tests run against the
  Puppet Resource API releases the agent packages ship: 1.8.16 (puppet-agent
  8.0 and 8.1), 1.9.0 (puppet-agent 8.2 to 8.10, openvox-agent 8 before
  8.28.1), 1.9.2 (openvox-agent 8.28.1 and later, Debian's
  ruby-puppet-resource-api) and 2.0.1 (openvox-agent 9), plus 2.1.0.
* NITRO sessions use the per-request `X-NITRO-USER`/`X-NITRO-PASS`
  authentication; no session token is cached.
* Partitions (`/nitro/v1/config` in the admin partition only) and cluster/HA
  specific endpoints are not handled.

## License

Copyright 2026 Laurent Bigonville

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
