# frozen_string_literal: true

begin
  require 'voxpupuli/test/rake'
rescue LoadError
  # only available if gem group test is installed
end

begin
  require 'voxpupuli/release/rake_tasks'
rescue LoadError
  # only available if gem group releases is installed
else
  GCGConfig.user = 'bigon'
  GCGConfig.project = 'puppet-netscaler'
end

desc 'Regenerate the nitro_* types/providers (OAS=nitro-oas/config REST=nitro-rest/html/config)'
task :generate do
  oas = File.expand_path(ENV.fetch('OAS') { abort 'Set OAS=/path/to/extracted/nitro-oas/config' })
  rest = File.expand_path(ENV.fetch('REST') { abort 'Set REST=/path/to/extracted/nitro-rest/html/config' })
  ruby 'tools/generate.rb', oas, rest, 'tools/resources.yaml', '.'
end

desc 'Compare a NITRO release with the committed nitro_* definitions (OAS=nitro-oas/config REST=nitro-rest/html/config)'
task 'generate:diff' do
  oas = File.expand_path(ENV.fetch('OAS') { abort 'Set OAS=/path/to/extracted/nitro-oas/config' })
  rest = File.expand_path(ENV.fetch('REST') { abort 'Set REST=/path/to/extracted/nitro-rest/html/config' })
  ruby 'tools/generate.rb', '--diff', oas, rest, 'tools/resources.yaml', '.'
end

desc 'Regenerate the netscaler_* compatibility types from lib/puppet_x/netscaler/compat_definitions.rb'
task 'generate:compat' do
  ruby 'tools/generate_compat.rb', '.'
end
