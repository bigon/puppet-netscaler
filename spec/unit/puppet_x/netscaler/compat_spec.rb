# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/netscaler/compat_provider'

describe PuppetX::Netscaler::Compat do
  let(:upcase) do
    PuppetX::Netscaler::COMPAT.flat_map do |type, c|
      c[:attributes].select { |_n, a| a[:kind] == :upcase }.map { |n, a| ["#{type} #{n}", c, a] }
    end
  end
  let(:service) { PuppetX::Netscaler::COMPAT['netscaler_service'] }

  it 'backs every :upcase attribute with a NITRO enum without values differing only in case' do
    expect(upcase).not_to be_empty
    upcase.each do |label, c, a|
      values = described_class.enum_values(c, a)
      expect(values).not_to be_nil, label
      expect(values).not_to be_empty, label
      expect(values.map(&:downcase).uniq.size).to eq(values.size), label
    end
  end

  it 'canonicalizes every NITRO enum value of every :upcase attribute to itself, in any case' do
    upcase.each do |label, c, a|
      described_class.enum_values(c, a).each do |v|
        expect([v, v.downcase, v.upcase].map { |s| described_class.enum(c, a, s) }).to eq([v, v, v]), "#{label}: #{v}"
      end
    end
  end

  it 'maps a lower-case spelling onto the NITRO one' do
    expect(described_class.enum(service, service[:attributes][:protocol], 'radiuslistener')).to eq('RADIUSListener')
  end

  it 'upcases values outside the enum as before' do
    expect(described_class.enum(service, service[:attributes][:protocol], 'bogus')).to eq('BOGUS')
  end
end
