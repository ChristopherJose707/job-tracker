require "sequel"
require "json"
require "dotenv/load"
require_relative "ai_analyzer"

# -------------------------------------------------------
# Background Worker
# Heroku equivalent: Procfile `worker:` process
#
# Polls for jobs that have a JD and resume but no AI analysis yet,
# then calls Google Gemini and writes the result back to Postgres.
# Keeps the web process fast — AI calls can take 5-10s.
# -------------------------------------------------------

DB = Sequel.connect(ENV["DATABASE_URL"] || "postgres://localhost/job_tracker")
Jobs = DB[:jobs]

puts "[worker] Started. Polling for pending AI analysis jobs..."

def analyze_job(job)
  return unless AIAnalyzer.configured?

  puts "[worker] Analyzing job #{job[:id]}: #{job[:role]} at #{job[:company]}"

  result = AIAnalyzer.analyze(job, timeout: 30)
  if result[:error]
    puts "[worker] Gemini error on job #{job[:id]}: #{result[:error]}"
    return
  end

  analysis = result[:analysis]

  Jobs.where(id: job[:id]).update(
    ai_analysis: analysis,
    updated_at:  Time.now
  )

  puts "[worker] Done with job #{job[:id]}. Fit score: #{JSON.parse(analysis)["fit_score"] rescue "?"}"
rescue => e
  puts "[worker] Error on job #{job[:id]}: #{e.message}"
end

# Poll loop — in production you'd use a proper queue (Sidekiq, etc.)
# This pattern is intentionally simple to mirror what engineers often
# start with on Heroku before adding Redis. Great interview talking point.
loop do
  pending = Jobs.where(ai_analysis: nil)
                .exclude(jd_text: nil).exclude(jd_text: "")
                .exclude(resume: nil).exclude(resume: "")
                .all

  if pending.empty?
    puts "[worker] No pending jobs. Sleeping 30s..."
  else
    puts "[worker] Found #{pending.count} job(s) to analyze."
    pending.each { |job| analyze_job(job) }
  end

  sleep 30
end
