require "spec"
require "compress/zlib"
require "../../src/asciicrystal_pdf"

# Integration-test helpers: run the real converter end-to-end on a
# snippet of AsciiDoc, then read the produced PDF back via the sibling
# `PDF::Reader` (pdf v0.3+) to extract what we need to assert
# on. Stays entirely in Crystal — no external tools.
#
# The goal is NOT byte-identical golden files (too brittle); each spec
# asserts the minimal property it cares about (text present, title
# decoded, no tofu, etc.).
module IntegrationHelper
  # Converts an AsciiDoc source string to a PDF on a temp path and
  # returns that path. The caller is responsible for cleanup (usually
  # via `after_each` or `ensure`).
  #
  # `type1_fonts: false` keeps the theme's TrueType fonts (DejaVu), for
  # the specs that check a TTF is used. `docdir` writes the source into
  # that directory, so that relative images placed there resolve.
  def self.convert(adoc_source : String, *, type1_fonts : Bool = true, docdir : String? = nil) : String
    stem = docdir ? File.join(docdir, "doc-#{Random.rand(1_000_000)}") : File.tempname("cap-pdf-it")
    adoc_path = stem + ".adoc"
    pdf_path = stem + ".adoc.pdf"
    File.write(adoc_path, adoc_source)

    # Force the Type1 standard fallback fonts (Helvetica/Courier):
    # their content-stream encoding is WinAnsi, i.e. literal
    # `(text)` strings readable back with a simple regex scan.
    # TrueType fonts (DejaVuSans) emit hex strings indexed on glyph
    # ids via a `ToUnicode` CMap, which would require a full CMap
    # parser to decode in the test. The tests care about rendering
    # semantics (text present, NBSP collapsed, title decoded), not
    # the font choice.
    theme = AsciicrystalPDF::Theme.new
    reset_fonts(theme) if type1_fonts

    options = {"docfile" => adoc_path, "outfile" => pdf_path} of String => String
    # Avec un `docdir`, on se place en mode `unsafe` comme la CLI : en
    # `secure` (défaut de l'API), asciidoctor vide `docdir` et les
    # images relatives au document ne sont plus trouvées.
    options["safe"] = "unsafe" if docdir
    doc = Asciicrystal.load_file(adoc_path, options)
    converter = AsciicrystalPDF::Converter.new("pdf", theme)
    converter.convert(doc)

    File.delete(adoc_path) if File.exists?(adoc_path)
    pdf_path
  end

  private def self.reset_fonts(theme : AsciicrystalPDF::Theme) : Nil
    theme.base_font_path = nil
    theme.base_font_bold_path = nil
    theme.base_font_italic_path = nil
    theme.base_font_bold_italic_path = nil
    theme.mono_font_path = nil
    theme.mono_font_bold_path = nil
  end

  # Returns the `/Title` value from the PDF `/Info` dictionary, or nil.
  # Used to assert that the title was properly decoded (e.g. `{nbsp}`
  # rendered as an actual space, not a literal `&#160;`).
  def self.title(pdf_path : String) : String?
    reader = PDF::Reader.open(pdf_path)
    # `@trailer` is a private ivar on Reader; accessing it from a
    # spec is fine in Crystal.
    info_ref = reader.@trailer["Info"]?
    return nil unless info_ref
    info = reader.resolve(info_ref).as?(PDF::Objects::Dictionary)
    return nil unless info
    title_obj = info["Title"]?
    return nil unless title_obj
    resolved = reader.resolve(title_obj)
    raw = resolved.as?(PDF::Objects::Str).try(&.value)
    raw ? decode_pdf_string(raw) : nil
  end

  # Decodes a raw string extracted from a PDF object. PDF strings can
  # be either PDFDocEncoding (1 byte per codepoint, mostly ASCII) or
  # UTF-16BE prefixed with the BOM 0xFE 0xFF. Crystal-pdf stores
  # non-ASCII titles in the latter form.
  private def self.decode_pdf_string(str : String) : String
    bytes = str.to_slice
    if bytes.size >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF
      buf = String::Builder.new
      i = 2
      while i + 1 < bytes.size
        cp = (bytes[i].to_u32 << 8) | bytes[i + 1].to_u32
        begin
          buf << cp.chr
        rescue
          # skip invalid codepoints
        end
        i += 2
      end
      buf.to_s
    else
      str
    end
  end

  # Returns a best-effort flat text extraction of every page. Walks
  # the content streams, decodes Flate if present, and collects every
  # literal `(...)` string as well as every hex `<...>` string.
  #
  # CAVEAT : hex strings under Identity-H encoding hold 2-byte GLYPH
  # IDs, not Unicode codepoints. This helper decodes them as raw
  # 2-byte values, so for fonts where GID == codepoint (basic Latin
  # in many fonts) the text is readable, but for CJK/composite fonts
  # the decoded chars are the GIDs, not the source text. Asserting the
  # exact CJK text would require parsing the font's ToUnicode CMap —
  # not done here. Tests that touch CJK assert on the *presence /
  # absence of the `?` fallback* instead, which is GID-agnostic.
  def self.text(pdf_path : String) : String
    reader = PDF::Reader.open(pdf_path)
    buf = String::Builder.new

    (0...reader.page_count).each do |i|
      page = reader.pages[i]
      page.content_streams.each do |bytes|
        decoded = inflate_if_needed(bytes)
        extract_text_from_stream(decoded, buf)
      end
    end

    buf.to_s
  end

  # Like `.text` but limited to a single 0-based page index. Lets a
  # spec assert WHERE content landed — e.g. an article doctitle must
  # share its first page with the TOC, not sit on a later page.
  def self.page_text(pdf_path : String, page_index : Int32) : String
    reader = PDF::Reader.open(pdf_path)
    buf = String::Builder.new
    page = reader.pages[page_index]
    page.content_streams.each do |bytes|
      decoded = inflate_if_needed(bytes)
      extract_text_from_stream(decoded, buf)
    end
    buf.to_s
  end

  # Returns the image placements of the document, as
  # `{width, height, x, y}` in PDF points — one entry per `Do`
  # operator preceded by its scaling/translating `cm` matrix.
  #
  # PDF anchors an XObject by its LOWER-LEFT corner, so `y` is the
  # BOTTOM of the drawn image and `y + height` its top. That is what
  # lets a spec assert an image stays inside the page.
  def self.image_placements(pdf_path : String) : Array(Tuple(Float64, Float64, Float64, Float64))
    reader = PDF::Reader.open(pdf_path)
    out = [] of Tuple(Float64, Float64, Float64, Float64)
    pattern = /([\d.]+) 0 0 ([\d.]+) (-?[\d.]+) (-?[\d.]+) cm\s*\/[A-Za-z0-9_]+ Do/

    (0...reader.page_count).each do |i|
      reader.pages[i].content_streams.each do |bytes|
        decoded = inflate_if_needed(bytes)
        # Le flux de contenu est de l'ASCII (les octets de l'image
        # vivent dans un XObject séparé) : la conversion est sûre.
        String.new(decoded).scan(pattern) do |m|
          out << {m[1].to_f, m[2].to_f, m[3].to_f, m[4].to_f}
        end
      end
    end

    out
  end

  # Counts the number of `/Subtype /Link` annotations in the raw PDF
  # bytes. This is the cheapest, most font-agnostic way to assert that
  # the TOC entries are clickable: every entry should produce one link
  # annotation that targets a named destination.
  #
  # PDF content streams may contain arbitrary high (>= 0x80) bytes that
  # break Crystal's UTF-8 regex engine, so we count via raw byte-window
  # comparison instead of `String#scan`.
  def self.link_annotation_count(pdf_path : String) : Int32
    count_byte_pattern(pdf_path, "/Subtype /Link") +
      count_byte_pattern(pdf_path, "/Subtype/Link")
  end

  # Returns the total number of `/XYZ` destinations appearing anywhere
  # in the PDF. Each section emits exactly one named destination AND
  # one outline (bookmark) entry — both of which use the `/XYZ` view
  # type when targeting a precise position. So the raw count is
  # `2 × number_of_sections` for the standard pipeline.
  def self.xyz_destination_count(pdf_path : String) : Int32
    count_byte_pattern(pdf_path, "/XYZ")
  end

  # Returns the rectangles (`x y w h re`) drawn in the document, as
  # `{x, y, width, height}` in PDF points (y = bottom edge). Vector
  # images (SVG) are drawn with these primitives, which lets a spec
  # check where an SVG landed.
  def self.rectangles(pdf_path : String) : Array(Tuple(Float64, Float64, Float64, Float64))
    reader = PDF::Reader.open(pdf_path)
    out = [] of Tuple(Float64, Float64, Float64, Float64)
    pattern = /(-?[\d.]+) (-?[\d.]+) ([\d.]+) ([\d.]+) re/
    (0...reader.page_count).each do |i|
      reader.pages[i].content_streams.each do |bytes|
        String.new(inflate_if_needed(bytes)).scan(pattern) do |m|
          out << {m[1].to_f, m[2].to_f, m[3].to_f, m[4].to_f}
        end
      end
    end
    out
  end

  def self.page_count(pdf_path : String) : Int32
    PDF::Reader.open(pdf_path).page_count
  end

  # Returns the number of byte-level occurrences of `pattern` in the
  # raw bytes of `pdf_path`. Avoids regex (would crash on non-UTF-8
  # bytes) and avoids loading the whole file as a `String`.
  def self.count_byte_pattern(pdf_path : String, pattern : String) : Int32
    bytes = File.read(pdf_path).to_slice
    needle = pattern.to_slice
    return 0 if needle.size == 0 || needle.size > bytes.size
    count = 0
    i = 0
    last = bytes.size - needle.size
    while i <= last
      match = true
      j = 0
      while j < needle.size
        if bytes[i + j] != needle[j]
          match = false
          break
        end
        j += 1
      end
      if match
        count += 1
        i += needle.size
      else
        i += 1
      end
    end
    count
  end

  # Tests that the PDF was generated and is non-empty.
  def self.produces_pdf?(adoc_source : String) : Bool
    path = convert(adoc_source)
    ok = File.exists?(path) && File.size(path) > 500
    File.delete(path) if File.exists?(path)
    ok
  end

  # Inflates `bytes` when it looks like a zlib-compressed stream
  # (the default `FlateDecode` filter used by pdf). Returns
  # the original bytes otherwise.
  private def self.inflate_if_needed(bytes : Bytes) : Bytes
    return bytes if bytes.size < 2
    # zlib header detection: first byte is usually 0x78, second byte
    # makes the header checksum (first_byte * 256 + second_byte) % 31 == 0
    return bytes unless bytes[0] == 0x78
    io_in = IO::Memory.new(bytes)
    io_out = IO::Memory.new
    Compress::Zlib::Reader.open(io_in) { |z| IO.copy(z, io_out) }
    io_out.to_slice
  rescue
    bytes
  end

  # Scans `bytes` for PDF text operators and appends the text to
  # `buf`. The scan is done byte-per-byte (not via a regex) because
  # PDF content streams may contain high (>= 0x80) bytes that break
  # Crystal's UTF-8 regex engine. Two encodings are recognised:
  #
  # * Literal strings `(Hello)` — one byte per codepoint, interpreted
  #   as Latin-1 (a superset of the useful WinAnsi character set).
  # * Hex strings `<00480065>` — used by TrueType fonts with
  #   `Identity-H` encoding; decoded as 2-byte big-endian codepoints.
  #
  # Anything that cannot be decoded is silently skipped. The output is
  # a best-effort flat string suitable for `contain?` assertions.
  private def self.extract_text_from_stream(bytes : Bytes, buf : String::Builder) : Nil
    i = 0
    while i < bytes.size
      c = bytes[i]
      case c
      when '('.ord
        j = consume_literal_string(bytes, i + 1, buf)
        buf << ' '
        i = j
      when '<'.ord
        j = consume_hex_string(bytes, i + 1, buf)
        buf << ' '
        i = j
      else
        i += 1
      end
    end
  end

  # Reads a `(… )` literal starting at `start` (the byte right after
  # the opening parenthesis). Supports nested parentheses and the PDF
  # backslash escapes (`\(`, `\)`, `\\`). Writes decoded bytes into
  # `buf` (interpreted as Latin-1) and returns the index right after
  # the closing parenthesis.
  private def self.consume_literal_string(bytes : Bytes, start : Int32, buf : String::Builder) : Int32
    depth = 1
    i = start
    while i < bytes.size && depth > 0
      c = bytes[i]
      if c == '\\'.ord && i + 1 < bytes.size
        nc = bytes[i + 1]
        case nc
        when 'n'.ord  then buf << '\n'
        when 'r'.ord  then buf << '\r'
        when 't'.ord  then buf << '\t'
        when 'b'.ord  then buf << '\b'
        when 'f'.ord  then buf << '\f'
        when '('.ord  then buf << '('
        when ')'.ord  then buf << ')'
        when '\\'.ord then buf << '\\'
        else               buf << nc.chr
        end
        i += 2
      elsif c == '('.ord
        depth += 1
        buf << '('
        i += 1
      elsif c == ')'.ord
        depth -= 1
        if depth > 0
          buf << ')'
        end
        i += 1
      else
        buf << c.chr # byte interpreted as Unicode codepoint (Latin-1)
        i += 1
      end
    end
    i
  end

  # Reads a `<…>` hex string starting at `start` (the byte right
  # after the opening `<`). Whitespace inside is ignored. A run of
  # 4 hex digits is decoded as a big-endian codepoint (TrueType
  # Identity-H convention); 2 hex digits are decoded as a single
  # byte (useful for PDF `/Info` entries in hex form).
  private def self.consume_hex_string(bytes : Bytes, start : Int32, buf : String::Builder) : Int32
    hex = String::Builder.new
    i = start
    while i < bytes.size
      c = bytes[i]
      break if c == '>'.ord
      hex << c.chr unless c == ' '.ord || c == '\n'.ord || c == '\r'.ord || c == '\t'.ord
      i += 1
    end
    h = hex.to_s
    return i + 1 unless h.chars.all? { |ch| ch.ascii_number? || ('a'..'f').includes?(ch) || ('A'..'F').includes?(ch) }

    if !h.empty? && h.size.divisible_by?(4) && h.size >= 4
      0.step(to: h.size - 4, by: 4) do |k|
        begin
          cp = h[k, 4].to_u32(16)
          buf << cp.chr
        rescue
          # ignore invalid codepoints
        end
      end
    elsif !h.empty? && h.size.divisible_by?(2)
      0.step(to: h.size - 2, by: 2) do |k|
        begin
          byte = h[k, 2].to_u8(16)
          buf << byte.chr
        rescue
          # ignore invalid
        end
      end
    end
    i + 1
  end
end
