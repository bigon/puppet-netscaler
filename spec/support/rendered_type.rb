# frozen_string_literal: true

require 'tmpdir'

# Loads a type file rendered by a generator and returns the definition it
# passes to register_type, without registering the type
module RenderedType
  def load_rendered_type(code, type)
    registered = nil
    allow(Puppet::ResourceApi).to receive(:register_type) { |definition| registered = definition }
    # Nothing is registered: the code after register_type (autorequires, get
    # cache opt-out) must not autoload the type
    allow(Puppet::Type).to receive(:type).with(type).and_return(Class.new { def self.autorequire(*); end })
    Dir.mktmpdir do |dir|
      path = File.join(dir, "#{type}.rb")
      File.write(path, code)
      load path
    end
    registered
  end
end

RSpec.configure do |c|
  c.include RenderedType
end
