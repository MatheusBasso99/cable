# Test synchronization helpers.
#
# The specs coordinate with asynchronous work — Redis pub/sub round-trips and
# the server's background fibers — that used to be waited on with fixed
# `sleep`s. A fixed sleep is both too slow in the common case and too short
# under load, which made the suite order-dependent: a message a test published
# could still be in flight at teardown and then be delivered to the *next*
# test streaming from the same channel (e.g. `chat_1`). Waiting on the actual
# condition removes both problems — a publisher does not move on (or tear down)
# until its message has actually been delivered, so it leaves nothing in flight.

# Polls `block` until it returns a truthy value or `timeout` elapses, yielding
# to other fibers between checks. Returns the block's last value (which is
# falsey on timeout, so callers can still assert and get a meaningful failure).
#
# Bounded by attempt count rather than a clock read: the shard supports
# Crystal >= 1.10, where `Time.instant` does not exist yet and `Time.monotonic`
# is deprecated on current releases.
def wait_until(timeout : Time::Span = 2.seconds, interval : Time::Span = 5.milliseconds, &)
  attempts = (timeout / interval).ceil.to_i
  attempts.times do
    value = yield
    return value if value
    sleep interval
  end
  yield
end

# Blocks until `socket` has received `message`, so a test never proceeds while
# a broadcast is still in flight.
def wait_for_message(socket, message : String, timeout : Time::Span = 2.seconds)
  wait_until(timeout) { socket.messages.includes?(message) }
end

# Blocks until the server has an active subscription for `token`'s connection,
# replacing the "sleep and hope the subscribe was processed" pattern before
# publishing to a channel.
def wait_for_subscription(token : String, timeout : Time::Span = 2.seconds)
  wait_until(timeout) { Cable.server.subscribed_channels_for(token).size > 0 }
end
