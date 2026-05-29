require "sequel"
require "dotenv/load"

# -------------------------------------------------------
# Cron Job — Daily Staleness Checker
# Heroku equivalent: Heroku Scheduler add-on (paid)
# Render equivalent: native cron service in render.yaml (free)
#
# Flags any active application with no update in 7+ days.
# Runs daily at 9am UTC per the schedule in render.yaml.
# -------------------------------------------------------

DB = Sequel.connect(ENV["DATABASE_URL"] || "postgres://localhost/job_tracker")
Jobs = DB[:jobs]

puts "[cron] Running staleness check — #{Time.now}"

cutoff = Time.now - (7 * 24 * 60 * 60)  # 7 days ago

stale_jobs = Jobs
  .where(Sequel.lit("updated_at < ?", cutoff))
  .exclude(status: ["offer", "rejected"])  # don't flag closed deals
  .all

if stale_jobs.empty?
  puts "[cron] No stale jobs found. All good."
else
  puts "[cron] Marking #{stale_jobs.count} job(s) as stale."
  stale_jobs.each do |job|
    puts "[cron]   → #{job[:role]} at #{job[:company]} (last updated: #{job[:updated_at]})"
    Jobs.where(id: job[:id]).update(stale: true)
  end
end

puts "[cron] Done."
