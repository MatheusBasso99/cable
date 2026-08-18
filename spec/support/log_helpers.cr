# Log assertion helper.
#
# Captures every entry the "cable" log source emits while the block runs,
# regardless of the process-wide level, and returns the raw entries so a spec
# can assert that a secret never appears at a given severity.
#
# Deliberately not `Log.capture` (log/spec): its EntriesChecker only offers a
# check/next/empty DSL and hides the entries. Never use `Cable::Logger.level=`
# in specs — it sets an override that `Log.setup`/`Log.capture` never reset.
def capture_cable_log_entries(&) : Array(Log::Entry)
  backend = Log::MemoryBackend.new
  Log.builder.bind("cable", :trace, backend)
  begin
    yield
  ensure
    Log.builder.unbind("cable", :trace, backend)
  end
  backend.entries
end
