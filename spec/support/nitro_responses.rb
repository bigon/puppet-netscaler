# frozen_string_literal: true

# Webmock responses shaped like NITRO's
module NitroResponses
  # NITRO puts errorcode, message and severity in every JSON answer
  def nitro_body(body)
    { 'errorcode' => 0, 'message' => 'Done', 'severity' => 'NONE' }.merge(body)
  end

  def json(body, status = 200)
    { status: status, body: JSON.generate(nitro_body(body)), headers: { 'Content-Type' => 'application/json; charset=utf-8' } }
  end
end

RSpec.configure do |c|
  c.include NitroResponses
end
