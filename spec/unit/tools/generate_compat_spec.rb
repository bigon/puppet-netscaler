# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../tools/generate_compat'

describe CompatGenerator do
  def render_with_docs(docs)
    allow(PuppetX::Netscaler::Compat).to receive(:definition).and_wrap_original do |original, name|
      original.call(name).merge(docs: docs)
    end
    described_class.render('netscaler_server')
  end

  it 'keeps the docs literal when the type is loaded' do
    registered = load_rendered_type(render_with_docs("Server, not \#{interpolated} nor \\n escaped."), :netscaler_server)
    expect(registered[:docs]).to eq("Server, not \#{interpolated} nor \\n escaped.\n")
  end

  it 'keeps docs holding the heredoc terminator' do
    registered = load_rendered_type(render_with_docs("Text\nEOS\nmore"), :netscaler_server)
    expect(registered[:docs]).to eq("Text\nEOS\nmore\n")
  end

  it 'writes nothing when a type cannot be rendered' do
    allow(described_class).to receive(:render).and_call_original
    allow(described_class).to receive(:render).with(PuppetX::Netscaler::COMPAT.keys.last).and_raise(ArgumentError, 'broken')
    allow(File).to receive(:write)
    expect { described_class.run('/nonexistent') }.to raise_error(ArgumentError, 'broken')
    expect(File).not_to have_received(:write)
  end
end
