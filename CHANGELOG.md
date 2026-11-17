# Changelog

## 0.1.0 (unreleased)

* Initial release, as a NITRO-based drop-in replacement for
  puppetlabs-netscaler (same module, device and type names).
* Empty `netscaler` class kept for manifests that include it.
* `netscaler` transport and device (`puppet device`) for the NITRO REST API,
  accepting puppetlabs-netscaler style device URLs.
* Structured device facts (`os`, `networking`, `netscaler`), plus the
  deprecated flat facts of puppetlabs-netscaler (`operatingsystem =>
  'Netscaler'`, ...).
* Per-run prefetch: one listing per NITRO type instead of one GET per
  object (`prefetch` device option, on by default).
* 19 `nitro_*` types generated from the NITRO 14.1 OpenAPI spec (LB, CS, SSL).
* 16 `netscaler_*` compatibility types for puppetlabs-netscaler manifests.
* Secrets (`lbmonitor` passwords, RADIUS key, SNMP community and secure
  arguments, `sslcertkey` `passplain`) accept `Sensitive` values and are
  redacted in logs and reports.
