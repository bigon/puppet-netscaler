# @summary
#   Compatibility class for puppetlabs-netscaler.
#
#   puppetlabs-netscaler asked you to classify the `puppet device` proxy
#   agent with `class { 'netscaler': }` so it installed the faraday gems.
#   This module only uses the Ruby standard library, so the class does
#   nothing. It exists so existing manifests that include it keep compiling.
#
# @example
#   include netscaler
class netscaler {
}
