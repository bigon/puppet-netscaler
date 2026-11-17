# frozen_string_literal: true

require 'spec_helper'

describe 'netscaler' do
  let(:facts) { { os: { family: 'RedHat' } } }

  it { is_expected.to compile.with_all_deps }
  it { is_expected.to contain_class('netscaler') }

  it 'manages nothing on the proxy agent' do
    resources = catalogue.resources.reject { |r| %w[Class Stage Node].include?(r.type) }
    expect(resources).to be_empty
  end
end
