module Cable
  # The `Sec-WebSocket-Protocol` entries a client offers on the upgrade request.
  #
  # Browsers cannot set headers on a WebSocket, so the connection credential travels as one
  # offered entry, `Cable.settings.token_subprotocol_prefix` followed by the credential. The
  # reply to the handshake is negotiated by `HTTP::WebSocketHandler` (see `Cable::Handler`).
  module Subprotocols
    # Returns the credential carried by the first offered entry that starts with
    # `Cable.settings.token_subprotocol_prefix`, or `nil` when there is no such entry or it is
    # exactly the prefix.
    #
    # Browsers send one comma-separated line, but the header may also be repeated; both shapes
    # give the same entries. Entries are compared exactly and case-sensitively (RFC 6455).
    # The credential is opaque: it is not validated, decoded or logged here.
    def self.token(request : HTTP::Request) : String?
      return unless lines = request.headers.get?("Sec-WebSocket-Protocol")

      prefix = Cable.settings.token_subprotocol_prefix
      lines.each do |line|
        line.split(',') do |entry|
          entry = entry.strip
          next if entry.empty? || !entry.starts_with?(prefix)

          credential = entry.lchop(prefix)
          return credential.empty? ? nil : credential
        end
      end

      nil
    end
  end
end
