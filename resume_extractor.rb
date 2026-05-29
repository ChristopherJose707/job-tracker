require "pdf-reader"

module ResumeExtractor
  class ExtractError < StandardError; end

  MAX_PDF_SIZE = 5 * 1024 * 1024

  def self.from_upload(upload)
    return nil unless upload && upload[:tempfile]

    filename = upload[:filename].to_s
    content_type = upload[:type].to_s
    unless content_type == "application/pdf" || filename.downcase.end_with?(".pdf")
      raise ExtractError, "Resume file must be a PDF"
    end

    upload[:tempfile].rewind
    if upload[:tempfile].size > MAX_PDF_SIZE
      raise ExtractError, "PDF must be 5MB or smaller"
    end

    upload[:tempfile].rewind
    text = from_pdf(upload[:tempfile])
    raise ExtractError, "Could not extract text from PDF — try pasting your resume instead" if text.empty?

    text
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError
    raise ExtractError, "Invalid or unreadable PDF"
  end

  def self.from_pdf(io)
    io.rewind
    PDF::Reader.new(io).pages.map(&:text).join("\n").strip
  end

  def self.resolve(pasted_text, upload)
    pasted = pasted_text.to_s.strip
    uploaded = upload && upload[:tempfile] && !upload[:filename].to_s.strip.empty?

    return from_upload(upload) if uploaded
    pasted
  end
end
