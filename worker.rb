require "sequel"
require "httparty"
require "json"
require "dotenv/load"

# -------------------------------------------------------
# Background Worker
# Heroku equivalent: Procfile `worker:` process
#
# Polls for jobs that have a JD but no AI analysis yet,
# then calls OpenAI and writes the result back to Postgres.
# Keeps the web process fast — AI calls can take 5-10s.
# -------------------------------------------------------

DB = Sequel.connect(ENV["DATABASE_URL"] || "postgres://localhost/job_tracker")
Jobs = DB[:jobs]

puts "[worker] Started. Polling for pending AI analysis jobs..."

def analyze_job(job)
  api_key = ENV["OPENAI_API_KEY"]
  return unless api_key

  puts "[worker] Analyzing job #{job[:id]}: #{job[:role]} at #{job[:company]}"

  prompt = <<~PROMPT
    You are a career coach reviewing a job application.

    ROLE APPLIED FOR: #{job[:role]} at #{job[:company]}

    JOB DESCRIPTION:
    #{job[:jd_text]}

    Return a JSON object with:
    - fit_score: integer 0-100
    - strengths: array of 3 strings (why this candidate fits)
    - gaps: array of up to 3 strings (honest gaps to address)
    - talking_points: array of 3 interview talking points to prepare

    Return only valid JSON, no markdown.
  PROMPT

  response = HTTParty.post(
    "https://api.openai.com/v1/chat/completions",
    headers: {
      "Authorization" => "Bearer #{api_key}",
      "Content-Type"  => "application/json"
    },
    body: {
      model:    "gpt-4o-mini",
      messages: [{ role: "user", content: prompt }]
    }.to_json,
    timeout: 30
  )

  analysis = response.dig("choices", 0, "message", "content")

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
  pending = Jobs.where(ai_analysis: nil).exclude(jd_text: nil).exclude(jd_text: "").all

  if pending.empty?
    puts "[worker] No pending jobs. Sleeping 30s..."
  else
    puts "[worker] Found #{pending.count} job(s) to analyze."
    pending.each { |job| analyze_job(job) }
  end

  sleep 30
end
