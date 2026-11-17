# frozen_string_literal: true

ENV['COVERAGE'] ||= 'yes' if Dir.exist?(File.expand_path('../lib', __dir__))

require 'voxpupuli/test/spec_helper'
require 'webmock/rspec'

Dir['./spec/support/**/*.rb'].sort.each { |f| require f }
