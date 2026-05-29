bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 4567)}"
environment ENV.fetch("RACK_ENV", "development")

# Single-process mode — avoids fork issues with Sequel's top-level DB connection
workers 0
threads 1, 5
