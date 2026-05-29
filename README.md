# Job Tracker — Heroku → Render Migration Demo

A multi-service web app intentionally built in a **Heroku-style architecture**,
then deployed on **Render using Blueprints** — to demonstrate the migration path
firsthand.

## Stack

| Service | Tech | Heroku Equivalent |
|---|---|---|
| Web | Sinatra (Ruby) | `Procfile web:` dyno |
| Worker | Ruby polling loop | `Procfile worker:` dyno |
| Cron | Ruby script | Heroku Scheduler add-on (paid) |
| Database | Managed Postgres | Heroku Postgres add-on |
| Config | Environment Variables | `heroku config:set` / config vars |
| IaC | `render.yaml` Blueprint | `Procfile` + `app.json` combined |

## Features

- Track job applications with status (applied → interviewing → offer → rejected)
- Paste a job description → background worker analyzes it with Google Gemini
- Daily cron job flags stale applications (no activity in 7+ days)
- Full UI — no framework, plain Sinatra + ERB

---

## Local Development

```bash
# 1. Install dependencies
bundle install

# 2. Create local Postgres DB
createdb job_tracker

# 3. Copy env file and add your keys
cp .env.example .env
# Edit .env with your DATABASE_URL and GEMINI_API_KEY

# 4. Run the web server
bundle exec ruby app.rb

# 5. In a second terminal, run the worker
bundle exec ruby worker.rb

# 6. Test the cron manually
bundle exec ruby cron.rb
```

---

## Deploy to Render

### Option A — Blueprint (recommended, one-click)

1. Push this repo to GitHub
2. Go to [render.com](https://render.com) → New → Blueprint
3. Connect your repo — Render reads `render.yaml` and provisions everything
4. Set `GEMINI_API_KEY` in the Render dashboard (marked `sync: false` for security)
5. Done — web, worker, cron, and Postgres all running

### Option B — Manual (mirrors what a Heroku migration looks like)

1. Create a **Web Service** → connect repo → build: `bundle install` → start: `bundle exec ruby app.rb`
2. Create a **Worker** → same repo → start: `bundle exec ruby worker.rb`
3. Create a **Cron Job** → schedule `0 9 * * *` → start: `bundle exec ruby cron.rb`
4. Create a **Managed Postgres** instance
5. Add `DATABASE_URL` (from Postgres instance) and `GEMINI_API_KEY` as environment variables

---

## Key Heroku → Render Mapping (Interview Talking Points)

```
Procfile web: bundle exec ruby app.rb
→ render.yaml type: web, startCommand: bundle exec ruby app.rb

Procfile worker: bundle exec ruby worker.rb
→ render.yaml type: worker, startCommand: bundle exec ruby worker.rb

Heroku Scheduler (paid add-on)
→ render.yaml type: cron, schedule: "0 9 * * *"  (native, free)

heroku addons:create heroku-postgresql
→ render.yaml databases: - name: job-tracker-db

heroku config:set GEMINI_API_KEY=...
→ Render dashboard → Environment → Add Variable
  (or render.yaml envVars with sync: false)

DATABASE_URL auto-injected by Heroku
→ DATABASE_URL auto-injected via fromDatabase in render.yaml

Heroku Review Apps
→ Render Preview Environments (PR-native, more configurable)
```

---

## Architecture Notes

**Why a polling worker instead of a queue?**
This mirrors what many Heroku apps actually do before adding Redis + Sidekiq.
The worker polls Postgres every 30s for jobs with `jd_text` but no `ai_analysis`.
In production you'd replace this with a proper job queue — great interview discussion point.

**Why Sinatra instead of Rails?**
Smaller footprint, easier to read in an interview context. The Heroku/Render
deployment story is identical either way.

**AI endpoint is on both web and worker**
The web route (`POST /jobs/:id/analyze`) handles on-demand analysis.
The worker handles background processing for jobs added via the form.
Both write to the same `ai_analysis` column — the UI checks for it.
