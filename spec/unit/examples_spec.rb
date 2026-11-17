# frozen_string_literal: true

require 'spec_helper'

# Compile the example manifests and turn them into RAL resources: this
# validates every attribute name and value against the type definitions.
describe 'example manifests' do
  Dir[File.expand_path('../../examples/*.pp', __dir__)].each do |manifest|
    it "#{File.basename(manifest)} compiles to valid resources" do
      Puppet[:code] = File.read(manifest)
      node = Puppet::Node.new('ns01.example.com')
      catalog = Puppet::Parser::Compiler.compile(node)
      ral = catalog.to_ral
      resources = ral.resources.reject { |r| %w[Class Stage].include?(r.type.to_s.capitalize) }
      expect(resources).not_to be_empty
    end
  end
end
