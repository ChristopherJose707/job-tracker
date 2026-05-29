require "sinatra"
require "sinatra/json"
require "sequel"
require "json"
require "httparty"
require "dotenv/load"

# -------------------------------------------------------
# Database setup
# Render injects DATABASE_URL automatically from render.yaml
# Heroku equivalent: same pattern — DATABASE_URL config var
# -------------------------------------------------------
DB = Sequel.connect(ENV["DATABASE_URL"] || "postgres://localhost/job_tracker")

DB.create_table? :jobs do
  primary_key :id
  String      :company,    null: false
  String      :role,       null: false
  String      :status,     default: "applied"   # applied, interviewing, offer, rejected
  String      :url
  Text        :notes
  Text        :jd_text                           # job description for AI analysis
  Text        :ai_analysis                       # cached AI response
  DateTime    :applied_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime    :updated_at, default: Sequel::CURRENT_TIMESTAMP
  Boolean     :stale,      default: false
end

# -------------------------------------------------------
# Sinatra config
# -------------------------------------------------------
set :port, ENV["PORT"] || 4567
set :bind, "0.0.0.0"
set :views, File.dirname(__FILE__) + "/views"
set :public_folder, File.dirname(__FILE__) + "/public"

Jobs = DB[:jobs]

# -------------------------------------------------------
# Routes
# -------------------------------------------------------

get "/health" do
  json status: "ok"
end

get "/" do
  @jobs = Jobs.order(Sequel.desc(:applied_at)).all
  @stale_count = Jobs.where(stale: true).count
  erb :index
end

post "/jobs" do
  Jobs.insert(
    company:    params[:company],
    role:       params[:role],
    url:        params[:url],
    notes:      params[:notes],
    jd_text:    params[:jd_text],
    applied_at: Time.now,
    updated_at: Time.now
  )

  # Queue async AI analysis if a JD was provided
  # Worker polls this table for jobs where ai_analysis IS NULL and jd_text IS NOT NULL
  redirect "/"
end

patch "/jobs/:id/status" do
  Jobs.where(id: params[:id]).update(
    status:     params[:status],
    updated_at: Time.now,
    stale:      false           # activity resets staleness flag
  )
  json success: true
end

delete "/jobs/:id" do
  Jobs.where(id: params[:id]).delete
  json success: true
end

# -------------------------------------------------------
# AI Analysis endpoint
# Calls OpenAI to score fit and surface talking points.
# This is the "LLM-powered app on Render" talking point.
# -------------------------------------------------------
post "/jobs/:id/analyze" do
  job = Jobs.where(id: params[:id]).first
  halt 404, json(error: "Not found") unless job
  halt 400, json(error: "No JD text") if job[:jd_text].to_s.strip.empty?

  api_key = ENV["OPENAI_API_KEY"]
  halt 503, json(error: "AI not configured") unless api_key

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
    }.to_json
  )

  analysis_text = response.dig("choices", 0, "message", "content")

  Jobs.where(id: params[:id]).update(
    ai_analysis: analysis_text,
    updated_at:  Time.now
  )

  json JSON.parse(analysis_text)
rescue => e
  json error: e.message
end

get "/jobs/:id/analysis" do
  job = Jobs.where(id: params[:id]).first
  halt 404, json(error: "Not found") unless job
  return json(error: "No analysis yet") if job[:ai_analysis].nil?
  json JSON.parse(job[:ai_analysis])
end
