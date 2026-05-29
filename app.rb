require "sinatra"
require "sinatra/json"
require "sequel"
require "json"
require "dotenv/load"
require_relative "ai_analyzer"
require_relative "resume_extractor"

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
  Text        :resume                            # candidate resume for AI fit analysis
  Text        :ai_analysis                       # cached AI response
  DateTime    :applied_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime    :updated_at, default: Sequel::CURRENT_TIMESTAMP
  Boolean     :stale,      default: false
end

unless DB[:jobs].columns.include?(:resume)
  DB.alter_table :jobs do
    add_column :resume, Text
  end
end

# -------------------------------------------------------
# Sinatra config
# -------------------------------------------------------
set :port, ENV.fetch("PORT", 4567).to_i
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
  @error = params[:error]
  @jobs = Jobs.order(Sequel.desc(:applied_at)).all
  @stale_count = Jobs.where(stale: true).count
  erb :index
end

post "/jobs" do
  resume = ResumeExtractor.resolve(params[:resume], params[:resume_file])

  Jobs.insert(
    company:    params[:company],
    role:       params[:role],
    url:        params[:url],
    notes:      params[:notes],
    jd_text:    params[:jd_text],
    resume:     resume.empty? ? nil : resume,
    applied_at: Time.now,
    updated_at: Time.now
  )

  # Queue async AI analysis if a JD and resume were provided
  # Worker polls for jobs where ai_analysis IS NULL, jd_text IS NOT NULL, and resume IS NOT NULL
  redirect "/"
rescue ResumeExtractor::ExtractError => e
  redirect "/?error=#{URI.encode_www_form_component(e.message)}"
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
# Calls Google Gemini to score fit and surface talking points.
# This is the "LLM-powered app on Render" talking point.
# -------------------------------------------------------
post "/jobs/:id/analyze" do
  job = Jobs.where(id: params[:id]).first
  halt 404, json(error: "Not found") unless job
  halt 400, json(error: "No JD text") if job[:jd_text].to_s.strip.empty?
  halt 400, json(error: "No resume") if job[:resume].to_s.strip.empty?

  result = AIAnalyzer.analyze(job)
  if result[:error]
    status = if result[:error].include?("not configured")
               503
             elsif result[:error].include?("No JD text") || result[:error].include?("No resume")
               400
             else
               502
             end
    halt status, json(error: result[:error])
  end

  Jobs.where(id: params[:id]).update(
    ai_analysis: result[:analysis],
    updated_at:  Time.now
  )

  json JSON.parse(result[:analysis])
rescue => e
  json error: e.message
end

get "/jobs/:id/analysis" do
  job = Jobs.where(id: params[:id]).first
  halt 404, json(error: "Not found") unless job
  return json(error: "No analysis yet") if job[:ai_analysis].nil?
  json JSON.parse(job[:ai_analysis])
end
