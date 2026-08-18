require "../spec_helper"

include RequestHelpers

# Stands in for the kind of secret real applications carry inside message
# bodies (meeting tokens, invite links). None of it may reach a production log
# running at the default `:info` level.
SECRET_BODY = "meet_token: SECRET-abc123"

describe Cable::Channel do
  describe ".broadcast_to" do
    it "logs the body only at debug" do
      Cable.reset_server
      Cable.temp_config(backend_class: Cable::DevBackend) do
        entries = capture_cable_log_entries do
          ChatChannel.broadcast_to("chat_secret", {"message" => SECRET_BODY})
        end

        Cable::DevBackend.published_messages.should contain({"chat_secret", {"message" => SECRET_BODY}.to_json})
        leaks_secret?(entries).should be_false
        logs_secret_at_debug?(entries).should be_true
      end
      Cable.reset_server
    end

    it "logs the body only at debug, without re-encoding an already encoded message" do
      Cable.reset_server
      Cable.temp_config(backend_class: Cable::DevBackend) do
        entries = capture_cable_log_entries do
          ChatChannel.broadcast_to("chat_secret", SECRET_BODY)
        end

        Cable::DevBackend.published_messages.should contain({"chat_secret", SECRET_BODY})
        leaks_secret?(entries).should be_false
        logs_secret_at_debug?(entries).should be_true
      end
      Cable.reset_server
    end
  end

  describe "#broadcast" do
    it "logs the body only at debug, in the channel and in the per-subscriber delivery" do
      Cable.reset_server
      Cable.temp_config(backend_class: Cable::DevBackend) do
        connection, socket, channel = subscribes_to_chat_channel

        entries = capture_cable_log_entries do
          channel.broadcast(SECRET_BODY)
        end

        wait_until { socket.messages.any?(&.includes?(SECRET_BODY)) }.should be_truthy
        leaks_secret?(entries).should be_false
        logs_secret_at_debug?(entries).should be_true

        connection.close
        socket.close
      end
      Cable.reset_server
    end

    it "reports a missing stream_from at error without the body" do
      Cable.reset_server
      Cable.temp_config(backend_class: Cable::DevBackend) do
        socket = DummySocket.new(IO::Memory.new)
        connection = ApplicationCable::Connection.new(builds_request(token: "77"), socket)
        channel = ApplicationCable::Channel.new(
          connection: connection,
          identifier: "bare",
          params: {} of String => Cable::Payload::RESULT
        )

        entries = capture_cable_log_entries do
          channel.broadcast(SECRET_BODY)
        end

        entries.any? do |entry|
          entry.severity.error? && entry.message.includes?("without already using stream_from")
        end.should be_true
        entries.any?(&.message.includes?(SECRET_BODY)).should be_false

        connection.close
        socket.close
      end
      Cable.reset_server
    end
  end

  describe "#transmit" do
    it "logs the body only at debug" do
      Cable.reset_server
      Cable.temp_config(backend_class: Cable::DevBackend) do
        connection, socket, channel = subscribes_to_chat_channel

        entries = capture_cable_log_entries do
          channel.transmit(SECRET_BODY)
        end

        wait_until { socket.messages.any?(&.includes?(SECRET_BODY)) }.should be_truthy
        leaks_secret?(entries).should be_false
        logs_secret_at_debug?(entries).should be_true

        connection.close
        socket.close
      end
      Cable.reset_server
    end
  end

  describe "incoming messages" do
    it "logs #receive and #perform data only at debug" do
      Cable.reset_server
      Cable.temp_config(backend_class: Cable::DevBackend) do
        connection, socket, _channel = subscribes_to_chat_channel
        identifier = {channel: "ChatChannel", room: "1"}.to_json

        entries = capture_cable_log_entries do
          connection.receive({
            "command"    => "message",
            "identifier" => identifier,
            "data"       => {"message" => SECRET_BODY}.to_json,
          }.to_json)

          connection.receive({
            "command"    => "message",
            "identifier" => identifier,
            "data"       => {"action" => "invite", "invite_id" => SECRET_BODY}.to_json,
          }.to_json)
        end

        Cable::DevBackend.published_messages.count { |(_, message)| message.includes?(SECRET_BODY) }.should eq(2)
        leaks_secret?(entries).should be_false
        logs_secret_at_debug?(entries).should be_true

        connection.close
        socket.close
      end
      Cable.reset_server
    end
  end
end

# True when the secret shows up at a severity a production app running at the
# default level would print.
private def leaks_secret?(entries : Array(Log::Entry)) : Bool
  entries.any? do |entry|
    entry.severity >= Log::Severity::Info && entry.message.includes?(SECRET_BODY)
  end
end

# The body must still be there for troubleshooting with `LOG_LEVEL=debug`.
private def logs_secret_at_debug?(entries : Array(Log::Entry)) : Bool
  entries.any? { |entry| entry.severity.debug? && entry.message.includes?(SECRET_BODY) }
end

# Subscribing logs lifecycle lines at `info` by design, so specs set the
# subscription up *outside* the capture block.
private def subscribes_to_chat_channel(token : String = "98", room : String = "1")
  socket = DummySocket.new(IO::Memory.new)
  connection = ApplicationCable::Connection.new(builds_request(token: token), socket)
  Cable.server.add_connection(connection)
  connection.receive({
    "command"    => "subscribe",
    "identifier" => {channel: "ChatChannel", room: room}.to_json,
  }.to_json)
  wait_for_subscription(token)

  {connection, socket, connection.channels.first}
end
