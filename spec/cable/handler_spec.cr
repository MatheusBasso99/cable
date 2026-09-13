require "../spec_helper"

include RequestHelpers

describe Cable::Handler do
  describe "basic handling" do
    it "matches the right route" do
      handler = Cable::Handler(ApplicationCable::Connection).new
      request = HTTP::Request.new("GET", Cable.settings.route, upgrade_headers("actioncable-v1-json, actioncable-unsupported"))

      io_with_context = create_ws_request_and_return_io_and_context(handler, request)[0]
      io_with_context.to_s.should eq(ACCEPTED_AS_ACTIONCABLE)
    end

    it "starts the web pinger" do
      Cable::WebsocketPinger.run_every(0.001) do
        address_chan = start_server
        listen_address = address_chan.receive
        ws2 = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers("1"))

        initialized = false
        ws2.on_message do |str|
          if initialized
            str.match(/\{\"type\":\"ping\",\"message\":[0-9]{10}\}/).should be_truthy
            ws2.close
          else
            str.should eq({type: "welcome"}.to_json)
            initialized = true
          end
        end

        ws2.run
      end
    end
  end

  describe "Sec-WebSocket-Protocol" do
    it "echoes actioncable-v1-json and never the credential entry" do
      response = handshake_response(upgrade_headers("actioncable-v1-json, test-token.1"))
      response.should eq(ACCEPTED_AS_ACTIONCABLE)
      response.should_not contain("test-token")

      ws, connection = live_connection(ws_headers("1"))
      connection.token.should eq("1")
      ws.close
    end

    it "sends no protocol when the client offers none, and still upgrades" do
      handshake_response(upgrade_headers).should eq(ACCEPTED_WITHOUT_PROTOCOL)

      ws, connection = live_connection(HTTP::Headers.new)
      connection.token.should be_nil
      first_message(ws).should eq({type: "welcome"}.to_json)
    end

    it "sends no protocol when the client offers entries but not actioncable-v1-json" do
      handshake_response(upgrade_headers("test-token.1")).should eq(ACCEPTED_WITHOUT_PROTOCOL)
      # a client offering only the protocol Cable cannot speak is not told it was accepted
      handshake_response(upgrade_headers("actioncable-unsupported, test-token.1")).should eq(ACCEPTED_WITHOUT_PROTOCOL)

      ws, connection = live_connection(HTTP::Headers{"Sec-WebSocket-Protocol" => "test-token.1"})
      connection.token.should eq("1")
      ws.close
    end

    it "treats repeated header lines like one comma-joined line" do
      response = handshake_response(upgrade_headers("actioncable-v1-json", "test-token.1"))
      response.should eq(handshake_response(upgrade_headers("actioncable-v1-json, test-token.1")))
      response.should_not contain("test-token")

      headers = HTTP::Headers.new
      headers.add("Sec-WebSocket-Protocol", "actioncable-v1-json")
      headers.add("Sec-WebSocket-Protocol", "test-token.1")
      ws, connection = live_connection(headers)
      connection.token.should eq("1")
      first_message(ws).should eq({type: "welcome"}.to_json)
    end

    it "does not read the credential from the query string" do
      ws, connection = live_connection(HTTP::Headers{"Sec-WebSocket-Protocol" => "actioncable-v1-json"}, "/updates?test_token=1&token=1")
      connection.token.should be_nil
      ws.close
    end
  end

  describe "subscribe to channel" do
    it "subscribes" do
      address_chan = start_server
      listen_address = address_chan.receive

      ws2 = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers("1"))

      Cable.server.connections.size.should eq(1)
      Cable.server.active_connections_for("1").size.should eq(1)
      Cable.server.subscribed_channels_for("1").size.should eq(0)

      messages = [
        {type: "welcome"}.to_json,
        {type: "confirm_subscription", identifier: {channel: "ChatChannel", room: "1"}.to_json}.to_json,
      ]
      seq = 0
      ws2.on_message do |str|
        str.should eq(messages[seq])
        seq += 1
        ws2.close if seq >= messages.size
      end
      ws2.on_close do |code, _reason|
        code.should eq(HTTP::WebSocket::CloseCode::AbnormalClosure)
      end
      ws2.send({"command" => "subscribe", "identifier" => {channel: "ChatChannel", room: "1"}.to_json}.to_json)

      ws2.run

      Cable.server.connections.size.should eq(1)
      Cable.server.active_connections_for("1").size.should eq(1)
      Cable.server.subscribed_channels_for("1").size.should eq(1)
    end

    it "malformed data from client" do
      address_chan = start_server
      listen_address = address_chan.receive

      ws2 = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers("1"))

      Cable.server.connections.size.should eq(1)

      # to avoid IO::Error from mock client connection failure
      begin
        # invalid identifier json string
        ws2.send({"command" => "subscribe", "identifier" => "{\"channel\"\"ChatChannel\",\"room\":\"1\"}"}.to_json)
        ws2.run
      rescue
      end

      Cable.server.connections.size.should eq(0)
    end

    it "malformed keys from client" do
      address_chan = start_server
      listen_address = address_chan.receive

      ws2 = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers("1"))

      Cable.server.connections.size.should eq(1)

      # to avoid IO::Error from mock client connection failure
      begin
        # typo in command vs commands
        ws2.send({"commands" => "subscribe", "identifier" => {channel: "ChatChannel", room: "1"}.to_json}.to_json)
        ws2.run
      rescue
      end

      Cable.server.connections.size.should eq(0)
    end

    it "reports errors" do
      FakeExceptionService.size.should eq(0)

      address_chan = start_server
      listen_address = address_chan.receive

      ws2 = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers("1"))

      Cable.server.connections.size.should eq(1)

      # to avoid IO::Error from mock client connection failure
      begin
        # typo in command vs commands
        ws2.send({"commands" => "subscribe", "identifier" => {channel: "ChatChannel", room: "1"}.to_json}.to_json)
        ws2.run
      rescue
      end

      FakeExceptionService.size.should eq(1)
      exception = FakeExceptionService.exceptions.first
      exception.message.should contain("Cable::Handler#socket.on_message")
      exception.exception.class.should eq(JSON::SerializableError)
      exception.connection.as(Cable::Connection).token.should eq("1")
      # the raw frame must not be forwarded to error trackers
      exception.message.should_not contain("ChatChannel")
    end

    it "rejected" do
      address_chan = start_server
      listen_address = address_chan.receive

      ws2 = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers("reject"))

      # we never get a connection from the server
      # its rejected before we get a chance to send a message
      Cable.server.connections.size.should eq(0)

      messages = [] of String
      close_code = nil
      close_reason = nil
      ws2.on_message { |str| messages << str }
      ws2.on_close do |code, reason|
        close_code = code
        close_reason = reason
      end

      # to avoid IO::Error from mock client connection failure
      begin
        ws2.run
      rescue
      end

      close_code.should eq(HTTP::WebSocket::CloseCode::NormalClosure)
      close_reason.should eq("Farewell")
      messages.should be_empty

      # should be zero connections open
      Cable.server.connections.size.should eq(0)
    end
  end

  describe "receive message from client" do
    it "receives the message" do
      address_chan = start_server
      listen_address = address_chan.receive

      ws2 = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers("1"))

      messages = [
        {type: "welcome"}.to_json,
        {type: "confirm_subscription", identifier: {channel: "ChatChannel", room: "1"}.to_json}.to_json,
        {identifier: {channel: "ChatChannel", room: "1"}.to_json, message: {message: "test", current_user: "1"}}.to_json,
      ]
      seq = 0
      ping_seq = 0
      ws2.on_message do |str|
        if str.match(/\{"type":"ping","message":[0-9]{8,12}\}/) && ping_seq < 2
          ping_seq += 1
          next
        end
        str.should eq(messages[seq])
        seq += 1
        ws2.close if seq >= messages.size
      end
      # App.cable.subscriptions.create({ channel: "ChatChannel", params: {room: "1"}});
      ws2.send({"command" => "subscribe", "identifier" => {channel: "ChatChannel", room: "1"}.to_json}.to_json)

      # Wait until the server has registered the subscription before sending,
      # instead of guessing with a fixed sleep.
      wait_for_subscription("1")

      # App.cable.subscriptions.subscriptions[0].send({message: "test"})
      ws2.send({"command" => "message", "identifier" => {channel: "ChatChannel", room: "1"}.to_json, "data" => {message: "test"}.to_json}.to_json)

      ws2.run
    end
  end

  describe "server broadcast to channels" do
    it "sends and clients receives the message" do
      address_chan = start_server
      listen_address = address_chan.receive

      ws2 = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers("1"))

      messages = [
        {type: "welcome"}.to_json,
        {type: "confirm_subscription", identifier: {channel: "ChatChannel", room: "1"}.to_json}.to_json,
        {identifier: {channel: "ChatChannel", room: "1"}.to_json, message: {message: "from Ruby!", current_user: "1"}}.to_json,
      ]
      seq = 0
      ws2.on_message do |str|
        # This is to simulate one broadcast from server, so we `ws2.run` and loose control of the flow
        # this way we are simulating a broadcast while the use is connected
        # before `ws2.close`
        if seq == 0
          # avoid publishing before the channel has subscribed
          wait_for_subscription("1")
          Cable.server.publish("chat_1", {"message" => "from Ruby!", "current_user" => "1"}.to_json)
        end
        str.should eq(messages[seq])
        seq += 1
        ws2.close if seq >= messages.size
      end
      # App.cable.subscriptions.create({ channel: "ChatChannel", params: {room: "1"}});
      ws2.send({command: "subscribe", identifier: {channel: "ChatChannel", room: "1"}.to_json}.to_json)
      ws2.run
    end
  end

  describe "performs" do
    it "server receive commands and performs an action" do
      address_chan = start_server
      listen_address = address_chan.receive

      ws2 = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers("1"))

      messages = [
        {type: "welcome"}.to_json,
        {type: "confirm_subscription", identifier: {channel: "ChatChannel", room: "1"}.to_json}.to_json,
        {identifier: {channel: "ChatChannel", room: "1"}.to_json, message: {performed: "invite", params: "3"}}.to_json,
      ]
      seq = 0
      ws2.on_message do |str|
        str.should eq(messages[seq])
        seq += 1
        ws2.close if seq >= messages.size
      end
      # App.cable.subscriptions.create({ channel: "ChatChannel", params: {room: "1"}});
      ws2.send({command: "subscribe", identifier: {channel: "ChatChannel", room: "1"}.to_json}.to_json)

      # Wait until the server has registered the subscription before sending.
      wait_for_subscription("1")

      # App.cable.subscriptions.subscriptions[0].perform("invite", {invite_id: "3"});
      ws2.send({command: "message", identifier: {channel: "ChatChannel", room: "1"}.to_json, data: {invite_id: "3", action: "invite"}.to_json}.to_json)
      ws2.run
    end
  end

  describe "the error handling" do
    it "doesn't match the wrong route" do
      handler = Cable::Handler(ApplicationCable::Connection).new
      request = HTTP::Request.new("GET", "/unknown_route", upgrade_headers("actioncable-v1-json, actioncable-unsupported"))

      io_with_context = create_ws_request_and_return_io_and_context(handler, request)[0]
      io_with_context.to_s.should contain("404 Not Found")
    end

    it "doesn't upgrade with wrong headers (without Upgrade header)" do
      handler = Cable::Handler(ApplicationCable::Connection).new
      headers_without_upgrade = upgrade_headers("actioncable-v1-json, actioncable-unsupported")
      headers_without_upgrade.delete("Upgrade")
      request = HTTP::Request.new("GET", "/unknown_route", headers_without_upgrade)

      io_with_context = create_ws_request_and_return_io_and_context(handler, request)[0]
      io_with_context.to_s.should contain("404 Not Found")
    end

    it "doesn't upgrade with wrong headers (without Connection header)" do
      handler = Cable::Handler(ApplicationCable::Connection).new
      headers_without_connection = upgrade_headers("actioncable-v1-json, actioncable-unsupported")
      headers_without_connection.delete("Connection")
      request = HTTP::Request.new("GET", "/unknown_route", headers_without_connection)

      io_with_context = create_ws_request_and_return_io_and_context(handler, request)[0]
      io_with_context.to_s.should contain("404 Not Found")
    end

    it "keeps the server running when channel code raises" do
      address_chan = start_server
      listen_address = address_chan.receive
      server = Cable.server

      bystander = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers("bystander"))
      wait_until { Cable.server.connections.size == 1 }

      # More raising connections than `restart_error_allowance` (2 in these
      # specs), each in its own room so no broadcast crosses between them.
      %w[ws2 ws3 ws4].each_with_index do |token, index|
        room = (index + 2).to_s
        ws = HTTP::WebSocket.new("ws://#{listen_address}/updates", headers: ws_headers(token))
        wait_until { Cable.server.active_connections_for(token).size == 1 }

        ws.on_message do |str|
          next unless str.includes?("confirm_subscription")

          ws.send({"command" => "message", "identifier" => {channel: "ChatChannel", room: room}.to_json, "data" => {message: "raise"}.to_json}.to_json)
        end
        ws.send({"command" => "subscribe", "identifier" => {channel: "ChatChannel", room: room}.to_json}.to_json)

        begin
          ws.run
        rescue IO::Error
          # the server closes this socket after the raise
        end

        wait_until { Cable.server.active_connections_for(token).empty? }.should be_true
      end

      # the raising connections are gone and reported, the rest of the node is untouched
      Cable.server.should be(server)
      Cable.server.errors.should eq(0)
      Cable.server.active_connections_for("bystander").size.should eq(1)
      FakeExceptionService.exceptions.count(&.exception.is_a?(IO::Error)).should eq(3)

      bystander.close
    end
  end
end

# Thanks @kemalcr
private def create_ws_request_and_return_io_and_context(handler, request)
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  begin
    handler.call context
  rescue IO::Error
    # Raises because the IO::Memory is empty
  end
  io.rewind
  {io, context}
end

private def start_server
  address_chan = Channel(Socket::IPAddress).new

  spawn do
    # Make pinger real fast so we don't need to wait
    http_server = HTTP::Server.new([Cable::Handler(ApplicationCable::Connection).new])
    address = http_server.bind_unused_port
    address_chan.send(address)
    http_server.listen
  end

  address_chan
end

private ACCEPTED_AS_ACTIONCABLE   = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: 6x90CSU0y750nc+5Do8J0YjG7lM=\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n\r\n"
private ACCEPTED_WITHOUT_PROTOCOL = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: 6x90CSU0y750nc+5Do8J0YjG7lM=\r\n\r\n"

# The raw bytes of the handshake reply. Crystal's `HTTP::WebSocket` client does not check the
# server's `Sec-WebSocket-Protocol`, so the reply is only ever asserted here.
private def handshake_response(headers : HTTP::Headers) : String
  handler = Cable::Handler(ApplicationCable::Connection).new
  request = HTTP::Request.new("GET", Cable.settings.route, headers)
  create_ws_request_and_return_io_and_context(handler, request)[0].to_s
end

# Connects a live client that sends `headers`, and returns it with the connection the server
# built for it.
private def live_connection(headers : HTTP::Headers, path : String = "/updates") : {HTTP::WebSocket, Cable::Connection}
  listen_address = start_server.receive
  ws = HTTP::WebSocket.new("ws://#{listen_address}#{path}", headers: headers)
  wait_until { Cable.server.connections.size == 1 }
  {ws, Cable.server.connections.values.first}
end

private def first_message(ws : HTTP::WebSocket) : String?
  message = nil
  ws.on_message do |str|
    message = str
    ws.close
  end
  ws.run
  message
end
