module RequestHelpers
  # The headers of a WebSocket upgrade request, with one `Sec-WebSocket-Protocol` line per
  # argument. No argument gives a client that offers no subprotocol at all.
  def upgrade_headers(*protocol_lines) : HTTP::Headers
    headers = HTTP::Headers{
      "Upgrade"               => "websocket",
      "Connection"            => "Upgrade",
      "Sec-WebSocket-Key"     => "OqColdEJm3i9e/EqMxnxZw==",
      "Sec-WebSocket-Version" => "13",
    }
    protocol_lines.each { |line| headers.add("Sec-WebSocket-Protocol", line) }
    headers
  end

  def builds_request(token : String) : HTTP::Request
    HTTP::Request.new("GET", Cable.settings.route, upgrade_headers("actioncable-v1-json, actioncable-unsupported, test-token.#{token}"))
  end

  def builds_request(token : Nil) : HTTP::Request
    HTTP::Request.new("GET", Cable.settings.route, upgrade_headers("actioncable-v1-json, actioncable-unsupported"))
  end

  # The headers a live `HTTP::WebSocket` client needs on top of the upgrade headers it adds
  # itself: the credential offered as a subprotocol entry, next to `actioncable-v1-json`.
  def ws_headers(token : String) : HTTP::Headers
    HTTP::Headers{"Sec-WebSocket-Protocol" => "actioncable-v1-json, test-token.#{token}"}
  end
end
