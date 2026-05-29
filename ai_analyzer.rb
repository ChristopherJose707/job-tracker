require "httparty"
require "json"

module AIAnalyzer
  DEFAULT_MODEL = "gemini-2.5-flash"

  def self.api_key
    ENV["GEMINI_API_KEY"]&.strip
  end

  def self.configured?
    !api_key.nil? && !api_key.empty?
  end

  def self.model
    ENV.fetch("GEMINI_MODEL", DEFAULT_MODEL)
  end

  def self.build_prompt(job)
    <<~PROMPT
      You are a career coach reviewing a job application.

      ROLE APPLIED FOR: #{job[:role]} at #{job[:company]}

      JOB DESCRIPTION:
      #{job[:jd_text]}

      CANDIDATE RESUME:
      #{job[:resume]}

      Compare the candidate's resume against the job description. Return a JSON object with:
      - fit_score: integer 0-100 (how well this specific candidate matches the role)
      - strengths: array of 3 strings (why this candidate fits)
      - gaps: array of up to 3 strings (honest gaps to address)
      - talking_points: array of 3 interview talking points to prepare

      Return only valid JSON, no markdown.
    PROMPT
  end

  def self.analyze(job, timeout: 60)
    return { error: "AI not configured — set GEMINI_API_KEY" } unless configured?
    return { error: "No JD text" } if job[:jd_text].to_s.strip.empty?
    return { error: "No resume" } if job[:resume].to_s.strip.empty?

    response = HTTParty.post(
      "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent",
      headers: {
        "x-goog-api-key" => api_key,
        "Content-Type"   => "application/json"
      },
      body: {
        contents: [{ parts: [{ text: build_prompt(job) }] }],
        generationConfig: { responseMimeType: "application/json" }
      }.to_json,
      timeout: timeout
    )

    parsed = response.parsed_response
    parsed = JSON.parse(response.body) if parsed.is_a?(String) && !response.body.to_s.strip.empty?

    unless response.success?
      detail = parsed.is_a?(Hash) ? (parsed.dig("error", "message") || parsed["error"]) : response.body
      return { error: "Gemini request failed (#{response.code}): #{detail}" }
    end

    analysis_text = parsed.is_a?(Hash) ? parsed.dig("candidates", 0, "content", "parts", 0, "text") : nil

    if analysis_text.nil? || analysis_text.to_s.strip.empty?
      detail = parsed.dig("candidates", 0, "finishReason") ||
               (parsed.is_a?(Hash) ? parsed.dig("error", "message") : "empty response")
      return { error: "Gemini returned no analysis: #{detail}" }
    end

    { analysis: analysis_text }
  rescue => e
    { error: e.message }
  end
end
