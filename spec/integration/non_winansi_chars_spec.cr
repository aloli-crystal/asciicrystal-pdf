require "./spec_helper"

# Regression for the silent-tofu bug: characters outside the WinAnsi
# encoding used to render as empty rectangles in the PDF with no
# warning to the author.
#
# As of v2.3.24.11 :
#
# * Emojis covered by `emojis-lite` (~208 codepoints) are
#   rendered as **embedded SVG glyphs in colour** via `page.svg`.
# * Other non-WinAnsi characters (CJK, dingbats not in Twemoji,
#   exotic scripts) fall back to `?` plus a deduplicated STDERR
#   warning (the v2.3.24.10 behaviour).
describe "Integration · non-WinAnsi characters" do
  it "renders covered emojis (✅ ❌) as colour SVG (path ops), not as `?`" do
    no_emoji = IntegrationHelper.convert(<<-ADOC)
      = Test
      Plain text without any emoji.
      ADOC
    with_emoji = IntegrationHelper.convert(<<-ADOC)
      = Test emoji
      Sample with ✅ and ❌ inline.
      ADOC

    begin
      File.exists?(with_emoji).should be_true
      # Crystal-pdf renders SVG as PDF path operators inside a
      # content stream — not as raw SVG strings. The simplest
      # observable difference is that the emoji-containing PDF
      # is bigger (extra path ops + colour data for two glyphs).
      File.size(with_emoji).should be > File.size(no_emoji)
      # And the emoji glyphs do NOT show up as `?` in the WinAnsi
      # text stream (that would be the v2.3.24.10 fallback, now
      # superseded by SVG rendering).
      text = IntegrationHelper.text(with_emoji)
      text.should_not contain("?")
    ensure
      File.delete(no_emoji) if File.exists?(no_emoji)
      File.delete(with_emoji) if File.exists?(with_emoji)
    end
  end

  it "renders CJK with the Noto font when available, else falls back to `?`" do
    # CJK ideograph 日 (U+65E5) — not in any emoji set nor in WinAnsi.
    #
    # Behaviour depends on whether a Noto CJK font is installed in the
    # cache (`noto-cjk pull`). Since pdf 0.6.4 the .otf CFF fonts load
    # natively, so when one is present the character is rendered with a
    # CIDFontType0 subset and the `?` fallback is NOT taken. Without a
    # cached font, the `safe_text` substitute path emits `?`.
    #
    # NB : `IntegrationHelper.text` decodes Identity-H hex strings as
    # raw 2-byte GIDs (not via ToUnicode), so it cannot reproduce the
    # exact ideograph — but it can reliably tell whether a `?`
    # substitution was emitted, which is what this test asserts.
    source = <<-ADOC
      = Test
      A CJK character: 日.
      ADOC
    path = IntegrationHelper.convert(source)
    begin
      File.exists?(path).should be_true
      text = IntegrationHelper.text(path)
      if NotoCjk.font_path
        # Font available → glyph rendered, no fallback substitution.
        text.should_not contain("?")
      else
        # No CJK font in cache → `?` fallback.
        text.should contain("?")
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "leaves WinAnsi text untouched (no `?` substitution)" do
    source = <<-ADOC
      = Test
      Plain ASCII plus accents éàù — €.
      ADOC
    path = IntegrationHelper.convert(source)
    begin
      text = IntegrationHelper.text(path)
      text.should contain("Plain ASCII")
      text.should contain("éàù")
      # No spurious `?` introduced when the source is fully WinAnsi.
      text.should_not contain("?")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
