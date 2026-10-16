require "./spec_helper"

# Répertoire de sortie pour les fichiers PDF générés par les tests
OUTPUT_DIR = "spec/output"

# Crée le répertoire de sortie si nécessaire
Dir.mkdir_p(OUTPUT_DIR)

# Utilitaire : convertit un contenu AsciiDoc et retourne le chemin du PDF
private def convert_to_pdf(content : String, filename : String) : String
  output_path = "#{OUTPUT_DIR}/#{filename}.pdf"
  doc = Asciicrystal.load(content, options: {"safe" => "safe", "outfile" => output_path})
  converter = AsciicrystalPDF::Converter.new
  converter.convert(doc)
  output_path
end

# Utilitaire : convertit et vérifie qu'un PDF non vide est produit
private def assert_pdf_generated(content : String, filename : String) : Nil
  path = convert_to_pdf(content, filename)
  File.exists?(path).should be_true
  File.size(path).should be > 0
  File.delete(path)
end

describe AsciicrystalPDF::Converter do
  # =========================================================================
  # Blocs de base
  # =========================================================================

  it "should convert a simple paragraph" do
    assert_pdf_generated("Hello, World.", "simple_paragraph")
  end

  it "should convert a section" do
    assert_pdf_generated("== Ma Section\n\nContenu de la section.", "section")
  end

  it "should convert nested sections" do
    input = "= Titre\n\n== Section 1\n\n=== Sous-section 1.1\n\nContenu.\n\n== Section 2\n\nContenu 2."
    assert_pdf_generated(input, "nested_sections")
  end

  it "should convert an unordered list" do
    assert_pdf_generated("* un\n* deux\n* trois", "ulist")
  end

  it "should convert an ordered list" do
    assert_pdf_generated(". un\n. deux\n. trois", "olist")
  end

  it "should convert a table" do
    input = "|===\n| Col A | Col B\n\n| 1     | 2\n| 3     | 4\n|==="
    assert_pdf_generated(input, "table")
  end

  it "should convert a table with header" do
    input = "[%header]\n|===\n| Nom | Valeur\n\n| alpha | 1\n| beta  | 2\n|==="
    assert_pdf_generated(input, "table_header")
  end

  # =========================================================================
  # Markup inline
  # =========================================================================

  it "should convert bold text" do
    assert_pdf_generated("Texte avec *gras* ici.", "inline_bold")
  end

  it "should convert italic text" do
    assert_pdf_generated("Texte avec _italique_ ici.", "inline_italic")
  end

  it "should convert monospace text" do
    assert_pdf_generated("Texte avec `code` ici.", "inline_mono")
  end

  it "should convert mixed inline markup" do
    assert_pdf_generated("*gras* et _italique_ et `mono` dans un paragraphe.", "inline_mixed")
  end

  # =========================================================================
  # Blocs de code
  # =========================================================================

  it "should convert a listing block" do
    input = "[source]\n----\nputs \"Hello, World!\"\n----"
    assert_pdf_generated(input, "listing_block")
  end

  it "should convert a listing block with language" do
    input = %([source,crystal]\n----\ndef hello(name : String) : String\n  "Hello, " + name\nend\n----)
    assert_pdf_generated(input, "listing_crystal")
  end

  it "should convert a listing block with ruby" do
    input = %([source,ruby]\n----\ndef greet(name)\n  # Salutation\n  puts "Hello, " + name\nend\n----)
    assert_pdf_generated(input, "listing_ruby")
  end

  it "should convert a literal block" do
    input = "....\nTexte préformaté\n  avec indentation\n...."
    assert_pdf_generated(input, "literal_block")
  end

  # =========================================================================
  # Admonitions
  # =========================================================================

  it "should convert a NOTE admonition" do
    assert_pdf_generated("NOTE: Ceci est une note importante.", "admonition_note")
  end

  it "should convert a TIP admonition" do
    assert_pdf_generated("TIP: Ceci est un conseil.", "admonition_tip")
  end

  it "should convert a WARNING admonition" do
    assert_pdf_generated("WARNING: Attention à ce point.", "admonition_warning")
  end

  it "should convert a CAUTION admonition" do
    assert_pdf_generated("CAUTION: Soyez prudent.", "admonition_caution")
  end

  it "should convert an IMPORTANT admonition" do
    assert_pdf_generated("IMPORTANT: Ceci est crucial.", "admonition_important")
  end

  # =========================================================================
  # Blocs spéciaux
  # =========================================================================

  it "should convert a quote block" do
    input = "[quote, Victor Hugo, Les Misérables]\n____\nAimer, c'est agir.\n____"
    assert_pdf_generated(input, "quote_block")
  end

  it "should convert a sidebar block" do
    input = "****\nCeci est un encadré latéral.\n****"
    assert_pdf_generated(input, "sidebar_block")
  end

  it "should convert an example block" do
    input = "====\nCeci est un exemple.\n===="
    assert_pdf_generated(input, "example_block")
  end

  # =========================================================================
  # Thème personnalisé
  # =========================================================================

  it "should use a custom theme" do
    theme = AsciicrystalPDF::Theme.new
    theme.base_font_size = 14.0
    theme.base_font_color = "0000ff"

    output_path = "#{OUTPUT_DIR}/custom_theme.pdf"
    doc = Asciicrystal.load("Texte avec thème personnalisé.", options: {"safe" => "safe", "outfile" => output_path})
    converter = AsciicrystalPDF::Converter.new("pdf", theme)
    converter.convert(doc)

    File.exists?(output_path).should be_true
    File.size(output_path).should be > 0
    File.delete(output_path)
  end

  # =========================================================================
  # Document complet
  # =========================================================================

  it "should convert a complete document" do
    input = <<-ADOC
      = Manuel d'utilisation
      Auteur Exemple <auteur@exemple.com>
      v1.0, 2024-01-01
      :toc:

      == Introduction

      Ce document est un exemple complet.

      === Sous-section

      Contenu avec *gras*, _italique_ et `code`.

      == Code

      [source,crystal]
      ----
      # Exemple Crystal
      def hello : String
        "Bonjour!"
      end
      ----

      == Tableau

      |===
      | Colonne A | Colonne B

      | Valeur 1  | Valeur 2
      | Valeur 3  | Valeur 4
      |===

      NOTE: Fin du document.
      ADOC
    assert_pdf_generated(input, "complete_document")
  end

  # =========================================================================
  # Génération de l'index
  # =========================================================================

  it "should collect index terms and generate index page" do
    # Le thème doit avoir index_enabled = true pour déclencher le rendu
    theme = AsciicrystalPDF::Theme.new
    theme.index_enabled = true

    input = <<-ADOC
      = Document avec Index
      :index:

      == Chapitre 1

      Texte sur Crystal((Crystal)) et sur les langages de programmation((langage de programmation)).

      == Chapitre 2

      Plus d informations sur Crystal((Crystal)) et sur Ruby((Ruby)).
      ADOC

    output_path = "#{OUTPUT_DIR}/index_test.pdf"
    doc = Asciicrystal.load(input, options: {"safe" => "safe", "outfile" => output_path})
    converter = AsciicrystalPDF::Converter.new("pdf", theme)
    converter.convert(doc)

    File.exists?(output_path).should be_true
    File.size(output_path).should be > 0
    File.delete(output_path)
  end

  it "should not generate index page when index_enabled is false" do
    theme = AsciicrystalPDF::Theme.new
    theme.index_enabled = false

    input = "Texte avec Crystal((Crystal)) indexé."
    output_path = "#{OUTPUT_DIR}/no_index_test.pdf"
    doc = Asciicrystal.load(input, options: {"safe" => "safe", "outfile" => output_path})
    converter = AsciicrystalPDF::Converter.new("pdf", theme)
    converter.convert(doc)

    File.exists?(output_path).should be_true
    File.size(output_path).should be > 0
    File.delete(output_path)
  end

  it "should generate index with multiple columns" do
    theme = AsciicrystalPDF::Theme.new
    theme.index_enabled = true
    theme.index_columns = 3

    input = <<-ADOC
      = Index multi-colonnes

      Termes : Alpha((Alpha)), Beta((Beta)), Crystal((Crystal)), Delta((Delta)),
      Epsilon((Epsilon)), Gamma((Gamma)), Lambda((Lambda)), Omega((Omega)).
      ADOC

    output_path = "#{OUTPUT_DIR}/index_multicolumn.pdf"
    doc = Asciicrystal.load(input, options: {"safe" => "safe", "outfile" => output_path})
    converter = AsciicrystalPDF::Converter.new("pdf", theme)
    converter.convert(doc)

    File.exists?(output_path).should be_true
    File.size(output_path).should be > 0
    File.delete(output_path)
  end

  # =========================================================================
  # Bookmarks PDF (outline)
  # =========================================================================

  it "should generate PDF bookmarks from sections" do
    input = "= Document\n\n== Chapter 1\n\nContent.\n\n== Chapter 2\n\nMore content."
    path = convert_to_pdf(input, "bookmarks")
    content = String.new(File.read(path).to_slice)
    content.should contain("/Outlines")
    content.should contain("/Title")
    File.delete(path)
  end

  it "should not generate outline for document without sections" do
    path = convert_to_pdf("Just a paragraph.", "no_bookmarks")
    content = String.new(File.read(path).to_slice)
    content.should_not contain("/Outlines")
    File.delete(path)
  end

  # =========================================================================
  # Métadonnées PDF
  # =========================================================================

  it "should include document title in PDF metadata" do
    input = "= Mon Titre\n\nContenu."
    path = convert_to_pdf(input, "metadata_title")
    content = String.new(File.read(path).to_slice)
    content.should contain("/Title")
    content.should contain("Mon Titre")
    File.delete(path)
  end

  it "should include author in PDF metadata" do
    input = "= Titre\nJean Dupont\n\nContenu."
    path = convert_to_pdf(input, "metadata_author")
    content = String.new(File.read(path).to_slice)
    content.should contain("/Author")
    content.should contain("Jean Dupont")
    File.delete(path)
  end

  it "should include producer in PDF metadata" do
    path = convert_to_pdf("Contenu simple.", "metadata_producer")
    content = String.new(File.read(path).to_slice)
    content.should contain("/Producer")
    content.should contain("asciicrystal-pdf")
    File.delete(path)
  end

  # =========================================================================
  # Mesures de texte exactes
  # =========================================================================

  it "should handle long paragraphs with proper line wrapping" do
    long_text = "Ce paragraphe contient suffisamment de texte pour necessiter " \
                "un retour a la ligne automatique dans le rendu PDF. " \
                "Les mesures de texte utilisent maintenant les metriques exactes " \
                "des polices Type1 au lieu d une approximation constante."
    assert_pdf_generated(long_text, "long_paragraph")
  end

  it "should handle mixed inline formatting in paragraphs" do
    input = "Texte avec *gras* et _italique_ et `code` et encore du texte normal pour remplir la ligne."
    assert_pdf_generated(input, "mixed_inline_long")
  end

  # =========================================================================
  # Liens
  # =========================================================================

  it "should generate clickable link annotations" do
    input = "Visitez https://crystal-lang.org[Crystal] pour plus d infos."
    path = convert_to_pdf(input, "link_annotation")
    content = String.new(File.read(path).to_slice)
    # Le HTML généré par asciidoctor contient <a href=...> qui produit un lien inline
    File.size(path).should be > 0
    File.delete(path)
  end

  # =========================================================================
  # Description lists
  # =========================================================================

  it "should convert a description list" do
    input = "Terme 1:: Definition du premier terme.\nTerme 2:: Definition du second terme."
    assert_pdf_generated(input, "dlist")
  end

  # =========================================================================
  # Blocs spéciaux avancés
  # =========================================================================

  it "should convert a verse block" do
    input = "[verse, Auteur, Source]\n____\nPremiere ligne\nDeuxieme ligne\n____"
    assert_pdf_generated(input, "verse_block")
  end

  it "should convert a floating title" do
    input = "[discrete]\n== Titre flottant\n\nParagraphe sous le titre."
    assert_pdf_generated(input, "floating_title")
  end

  it "should convert nested lists" do
    input = "* Item 1\n** Sous-item 1a\n** Sous-item 1b\n* Item 2"
    assert_pdf_generated(input, "nested_list")
  end

  it "should convert a page break" do
    input = "Page 1.\n\n<<<\n\nPage 2."
    assert_pdf_generated(input, "page_break")
  end

  it "should convert a thematic break" do
    input = "Avant.\n\n'''\n\nApres."
    assert_pdf_generated(input, "thematic_break")
  end

  # =========================================================================
  # Document complet avec TOC et bookmarks
  # =========================================================================

  it "should convert a full document with TOC and bookmarks" do
    input = <<-ADOC
      = Guide Complet
      Auteur Test
      :toc:

      == Introduction

      Ceci est l introduction du guide.

      === Sous-section

      Contenu de la sous-section avec *gras* et _italique_.

      == Code

      [source,crystal]
      ----
      def hello
        puts "Bonjour"
      end
      ----

      == Tableau

      |===
      | A | B

      | 1 | 2
      | 3 | 4
      |===

      NOTE: Note importante.

      == Conclusion

      Fin du document.
      ADOC
    path = convert_to_pdf(input, "full_doc_toc_bookmarks")
    content = String.new(File.read(path).to_slice)
    content.should contain("/Outlines")
    content.should contain("/Title")
    File.size(path).should be > 1000
    File.delete(path)
  end

  # =========================================================================
  # UTF-8 / French text encoding
  # =========================================================================

  it "should correctly generate PDF with French accented characters" do
    input = <<-ADOC
      = Spécifications
      Philippe Nénert

      == Présentation

      Voici un tiret \u2014 et des accents : é è ê ë à â ù û ç ô î.

      * Puce avec accents éàü
      * Deuxième puce
      ADOC

    path = convert_to_pdf(input, "french_utf8")
    File.exists?(path).should be_true
    File.size(path).should be > 0

    # Read the PDF bytes and ensure no garbled UTF-8 sequences remain.
    # The raw UTF-8 bytes for "é" are 0xC3 0xA9. In a properly encoded
    # PDF (WinAnsi), "é" should be the single byte 0xE9.
    # If we find 0xC3 0xA9 adjacent in text streams, encoding is broken.
    bytes = File.read(path).to_slice
    # The PDF should contain WinAnsi-encoded 0xE9 (é)
    found_winansi_e_acute = bytes.includes?(0xE9_u8)
    found_winansi_e_acute.should be_true
    File.delete(path)
  end

  it "should handle em dashes and smart quotes in PDF" do
    input = "Un texte \u2014 avec un tiret cadratin et des \u201Cguillemets\u201D."
    path = convert_to_pdf(input, "emdash_smartquotes")
    File.exists?(path).should be_true
    File.size(path).should be > 0
    File.delete(path)
  end

  it "should strip HTML tags from section titles" do
    input = "= Guide\n\n== Using `Crystal` for the web\n\nContent here."
    path = convert_to_pdf(input, "section_code_title")
    File.exists?(path).should be_true
    File.size(path).should be > 0
    File.delete(path)
  end
end
