# frozen_string_literal: true

source ENV['GEM_SOURCE'] || 'https://rubygems.org'

group :test do
  gem 'voxpupuli-test', '~> 15.0', require: false
  gem 'puppet_metadata', '~> 6.4', require: false
  gem 'webmock', '~> 3.0', require: false
end

group :development do
  gem 'overcommit', '>= 0.39.1', require: false
end

group :release do
  gem 'voxpupuli-release', '~> 5.5', require: false
end

gem 'rake', require: false

gem 'openvox', ENV.fetch('OPENVOX_GEM_VERSION', ['>= 8', '< 10']), require: false, groups: [:test]

# Resource API release the agent packages ship; 1.8.16 (puppet-agent 8.0 and
# 8.1) only exists as a git tag, it was never published on rubygems.org
case (resource_api = ENV.fetch('PUPPET_RESOURCE_API_VERSION', nil))
when nil, ''
  nil
when '1.8.16'
  gem 'puppet-resource_api', git: 'https://github.com/puppetlabs/puppet-resource_api.git', tag: resource_api, require: false, groups: [:test]
else
  gem 'puppet-resource_api', resource_api, require: false, groups: [:test]
end
