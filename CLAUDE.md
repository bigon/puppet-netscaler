# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Puppet module `bigon-netscaler` (module name `netscaler`, Apache-2.0) managing NetScaler (Citrix ADC) appliances through the NITRO REST API (`/nitro/v1/config`) with `puppet device`. It is a drop-in replacement for puppetlabs-netscaler and has two type families on one engine:

- `nitro_*`: generated from the NITRO OpenAPI spec; names, attributes and data types map 1:1 to NITRO.
- `netscaler_*`: compatibility layer keeping puppetlabs-netscaler's type names, attribute names and value spellings.

Puppet/OpenVox 8 is the minimum supported version; newer releases are fine. The client uses only the Ruby standard library (`Net::HTTP`), so no gem is needed on the proxy agent.

## Commands

Everything runs in the Vox Pupuli VoxBox container (its entrypoint is `rake`). Pass several tasks in one invocation:

```console
podman run --rm -v $PWD:/repo:Z -w /repo ghcr.io/voxpupuli/voxbox:10.1.1-openvox8 syntax spec lint rubocop metadata_lint check
podman run --rm -v $PWD:/repo:Z -w /repo -e SPEC=spec/unit/puppet_x/netscaler/nitro_resource_spec.rb ghcr.io/voxpupuli/voxbox:10.1.1-openvox8 spec
podman run --rm -v $PWD:/repo:Z -w /repo ghcr.io/voxpupuli/voxbox:10.1.1-openvox8 rubocop:autocorrect
podman run --rm -v $PWD:/repo:Z -w /repo ghcr.io/voxpupuli/voxbox:10.1.1-openvox8 strings:generate:reference   # REFERENCE.md
```

To run a single file outside rake: `--entrypoint sh ... -c 'cd /repo && BUNDLE_GEMFILE=/opt/voxbox/Gemfile bundle exec rspec <file>'`.

Code generation (needs the NITRO tarballs `nitro-oas.tgz` and `nitro-rest.tgz` extracted outside the repo, see below):

```console
rake generate OAS=<nitro-oas>/config REST=<nitro-rest>/html/config        # rewrite nitro_* types/providers + specs.rb
rake generate:diff OAS=<nitro-oas>/config REST=<nitro-rest>/html/config   # compare a NITRO release with what is committed; writes nothing, exit 1 on differences
rake generate:compat                                                      # rewrite lib/puppet/type/netscaler_*.rb from compat_definitions.rb
```

`ruby tools/generate.rb` runs on the host Ruby; `tools/generate_compat.rb` needs Puppet, so run it inside VoxBox.

## Architecture

Requests flow: Resource API type → provider → `PuppetX::Netscaler::NitroResource` (engine) → `Puppet::Transport::Netscaler` (HTTP).

- **Transport** (`lib/puppet/transport/netscaler.rb`, schema in `transport/schema/netscaler.rb`): NITRO client with per-request `X-NITRO-USER`/`X-NITRO-PASS` auth and one keep-alive connection per run. A GET returns nil for "not found" (`NOT_FOUND_CODES`). Device facts: Puppet 8 structured facts (`os`, `networking`, `netscaler`), plus the flat facts upstream puppetlabs-netscaler reported (including `operatingsystem => 'Netscaler'`, that spelling). It holds the per-run prefetch snapshots (`snapshot`/`invalidate`). Connection options: `ssl`, `ssl_verify`, `ca_file`, `timeout`, `prefetch`.
- **Device** (`lib/puppet/util/network_device/netscaler/device.rb`): `puppet device` entry point. Accepts Resource API `file://` HOCON configs and the legacy `https://user:pass@host/nitro/v1/?option=...` URL.
- **Engine** (`lib/puppet_x/netscaler/nitro_resource.rb`): CRUD on records keyed by NITRO attribute names, driven by the generated metadata in `lib/puppet_x/netscaler/specs.rb` (`SPECS`, `NITRO_VERSION`). Resources have three kinds:
  - `entity`: POST create, PUT update, `?action=enable|disable` for `state`, `action_updates` (e.g. sslcertkey `update`/`link`).
  - `binding`: PUT to add, `DELETE ?args=` to remove. NITRO cannot modify a binding, so a change unbinds and binds again with the current attributes, minus `rebind_exclude` (values NITRO reports but refuses on a bind, e.g. a servicegroup member's `ip`).
  - `settings`: no ensure, PUT only (e.g. `sslvserver`).

  Only attributes present in the desired state are managed; nothing is ever unset. Writes invalidate the type's prefetch snapshot; a delete also invalidates the types that reference it (their autorequires), e.g. the bindings of a deleted lbvserver.
- **Resource API get cache:** Resource API >= 2.0 caches `get` results on the type class for the whole process (shared across the devices of one `puppet device` run, never invalidated by our writes). Every generated type opts out (`render_get_cache` in `tools/generate.rb`, also used by `generate_compat.rb`), so the transport snapshot is the only cache, as on Resource API 1.9 (OpenVox 8).
- **Providers:**
  - `NitroProvider` (`nitro_provider.rb`) is the base of all generated `nitro_*` providers. It maps Puppet attribute names to NITRO names; the namevar of entities is `name` in Puppet.
  - Its `canonicalize` sorts NITRO lists (they are unordered sets, except the `ordered` ones of `tools/resources.yaml`) through `NitroResource.canonical_list`, shared with the engine and the compat layer, and adds the composite `:title` of bindings, which Resource API strict mode requires.
  - Saving is the plain (non Resource API) type `nsconfig_save` (`lib/puppet/type/nsconfig_save.rb`, `apply_to_device`): it autosubscribes to every `nitro_*`/`netscaler_*` resource and calls `transport.save` in `refresh`, so Puppet saves only after a change and skips it after a failure. Its `pre_run_check` refuses `->`/`require`/`before` against those resources (they would replace the subscription). The providers never save.
  - `CompatProvider` (`compat_provider.rb`) translates the old attribute names and values through `COMPAT` (`compat_definitions.rb`) and delegates to the engine. Subclasses handle special cases: `netscaler_server` `address` (IP vs domain), `netscaler_csvserver` `default_lbvserver` (a `csvserver_lbvserver_binding`).
- **Generator** (`tools/generate.rb`, configured by `tools/resources.yaml`):
  - It reads the OAS YAML for structure. The YAML is 1.1, so `YES`/`NO` are protected before parsing.
  - It reads the REST reference's GET payload to find attributes NITRO never returns; those become `behaviour: :parameter` (sent, never compared).
  - Create-only attributes become `init_only`.
  - `resources.yaml` carries per-resource knobs (`namevars`, `rebind_exclude`, `action_updates`, `kind: settings`, …); each key is documented in its header comment.
  - DELETE args NITRO marks as required (written `` ` name ` `` in the OAS, optional ones `***name***`) are always passed, for entities too (e.g. lbmonitor `type`).
  - Autorequires always target both the `nitro_*` and the `netscaler_*` type of an entity.

## Rules specific to this repo

- **Generated files — never edit by hand:** `lib/puppet/type/nitro_*.rb`, `lib/puppet/provider/nitro_*/`, `lib/puppet_x/netscaler/specs.rb`, `lib/puppet/type/netscaler_*.rb`, `REFERENCE.md`.
  - Change `tools/resources.yaml`, `tools/generate.rb` or `compat_definitions.rb` instead, then regenerate.
  - `spec/unit/puppet/type/types_spec.rb` fails if the compat type files are out of date.
  - Generated files are excluded from rubocop.
- **Strictness policy:**
  - `nitro_*` types accept exactly what the NITRO API accepts; fix callers rather than adding leniency.
  - The compat layer may only reproduce leniency upstream puppetlabs-netscaler deliberately had (truthy spellings, numeric strings, scalar → list). It does not reproduce accidental behaviour (e.g. array → first element).
- **Licensing:**
  - Never commit content of the NITRO OpenAPI/REST tarballs; they carry no licence. The generator only reads them, from outside the repo.
  - `spec/fixtures/generator/oas` and `spec/fixtures/generator/rest` are hand-written imitations used only by the generator spec.
  - Keep `NOTICE` and the README "Credits and provenance" section in sync with where content comes from.
- **Testing gotchas:**
  - `spec/integration/apply_spec.rb` applies real catalogs through the Resource API glue with `Puppet[:strict] = :error`. The types opt out of the Resource API get cache, so nothing needs clearing between simulated runs.
  - Every scenario runs with and without prefetch. Stub GETs with `stub_lookup(resource, parent)`, which picks the URL each mode calls.
  - Those catalogs use `host_config = false`, which makes Puppet ignore noop. To test noop, use a host catalog and pre-create `Puppet[:statedir]`.
  - `spec/unit/examples_spec.rb` compiles every `examples/*.pp`; renaming or removing an attribute means updating the examples too.
