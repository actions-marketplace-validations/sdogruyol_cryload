require "./cryload"

# A signal still prints the report, and a breached threshold still outranks the
# signal's own exit code. v5 exited 0 here, which made `timeout 60 cryload ...`
# look green regardless of what the run measured.
Process.on_terminate do |reason|
  Cryload::ShutdownCoordinator.finish_on_signal reason
end

Cryload::Cli.new
