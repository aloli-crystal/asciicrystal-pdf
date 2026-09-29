require "./spec_helper"
require "file_utils"
require "stumpy_png"

# Mode sûr et fichiers lus pour le document.
#
# Faille corrigée : en `secure` (et `safe`/`server`), une image désignée
# par un chemin absolu ou par un chemin relatif contenant `..` était lue
# hors du répertoire du document et incorporée au PDF. Un document
# déposé par un tiers pouvait ainsi y faire entrer n'importe quelle
# image lisible du serveur. Comme Asciidoctor (`normalize_system_path`
# avec `jail`), le chemin est désormais enfermé dans ce répertoire dès
# que le mode sûr vaut SAFE ou plus ; en `unsafe`, rien ne change.

# Arborescence : `<racine>/conv` (le document, avec `ici.png`) et
# `<racine>/ailleurs/secret.png`, hors du répertoire du document.
private def with_tree(&)
  root = File.tempname("cap-pdf-jail")
  conv = File.join(root, "conv")
  ailleurs = File.join(root, "ailleurs")
  Dir.mkdir_p(conv)
  Dir.mkdir_p(ailleurs)
  png = StumpyPNG::Canvas.new(40, 20, StumpyPNG::RGBA.from_hex("#b07a3c"))
  StumpyPNG.write(png, File.join(conv, "ici.png"))
  StumpyPNG.write(png, File.join(ailleurs, "secret.png"))
  yield conv, File.join(ailleurs, "secret.png")
ensure
  FileUtils.rm_rf(root) if root
end

# Titres en ASCII : `image_placements` lit le flux de contenu comme une
# chaîne, et un accent WinAnsi n'y est pas de l'UTF-8 valide.
private def images_in(adoc : String, conv : String, safe : String, attributes : Hash(String, String)? = nil) : Int32
  pdf = IntegrationHelper.convert(adoc, docdir: conv, safe: safe, attributes: attributes)
  IntegrationHelper.image_placements(pdf).size
ensure
  File.delete(pdf) if pdf && File.exists?(pdf)
end

describe "images in safe mode" do
  %w(secure server safe).each do |mode|
    it "refuses a block image outside the document directory in #{mode} mode" do
      with_tree do |conv, secret|
        images_in(<<-ADOC, conv, mode).should eq(0)
          = Hors du dossier

          image::#{secret}[Absolu]

          image::../ailleurs/secret.png[Relatif]
          ADOC
      end
    end
  end

  it "does not open a system file named by an absolute path" do
    with_tree do |conv, _|
      pdf = IntegrationHelper.convert(<<-ADOC, docdir: conv, safe: "secure")
        = Fichier système

        image::/etc/hosts[Hôtes]
        ADOC
      IntegrationHelper.text(pdf).should contain("[Image: Hôtes]")
      File.delete(pdf)
    end
  end

  it "keeps a relative image of the document directory, wherever the command runs" do
    with_tree do |conv, _|
      images_in(<<-ADOC, conv, "secure").should eq(2)
        = Dans le dossier

        image::ici.png[Relatif]

        image::#{File.join(conv, "ici.png")}[Absolu interne]
        ADOC
    end
  end

  it "brings a `..` path back inside the document directory" do
    with_tree do |conv, _|
      # `../ici.png` depuis la racine du répertoire est ramené à
      # `ici.png`, comme le fait Asciidoctor.
      images_in(<<-ADOC, conv, "secure").should eq(1)
        = Ramene

        image::../ici.png[Ramene]
        ADOC
    end
  end

  it "refuses a symbolic link leading outside the document directory" do
    with_tree do |conv, secret|
      File.symlink(secret, File.join(conv, "lien.png"))
      images_in(<<-ADOC, conv, "secure").should eq(0)
        = Lien

        image::lien.png[Lien]
        ADOC
    end
  end

  it "refuses inline images and passthrough <img> outside the document directory" do
    with_tree do |conv, secret|
      images_in(<<-ADOC, conv, "secure").should eq(0)
        = En ligne

        Avant image:#{secret}[Absolu] et image:../ailleurs/secret.png[Relatif].

        Passthrough +++<img src="#{secret}" alt="brut"/>+++ fin.
        ADOC
    end
  end

  it "keeps an inline image of the document directory" do
    with_tree do |conv, _|
      images_in(<<-ADOC, conv, "secure").should eq(1)
        = En ligne

        Avant image:ici.png[Ici] apres.
        ADOC
    end
  end

  it "refuses a title logo outside the document directory" do
    with_tree do |conv, secret|
      images_in(<<-ADOC, conv, "secure").should eq(0)
        = Logo
        :title-logo-image: image::#{secret}[]

        Contenu.
        ADOC
    end
  end

  it "keeps reading images anywhere in unsafe mode" do
    with_tree do |conv, secret|
      images_in(<<-ADOC, conv, "unsafe").should eq(3)
        = Sans restriction
        :title-logo-image: image::#{secret}[]

        image::#{secret}[Absolu]

        image::../ailleurs/secret.png[Relatif]
        ADOC
    end
  end

  it "never downloads a remote image, even with allow-uri-read" do
    with_tree do |conv, _|
      pdf = IntegrationHelper.convert(<<-ADOC, docdir: conv, safe: "unsafe", attributes: {"allow-uri-read" => ""})
        = Distante

        image::https://example.invalid/logo.png[Distante]
        ADOC
      IntegrationHelper.image_placements(pdf).should be_empty
      IntegrationHelper.text(pdf).should contain("[Image: Distante]")
      File.delete(pdf)
    end
  end

  # Le thème désigné par le document (`:pdf-theme:`) est un fichier lu
  # lui aussi : en mode sûr, seul un thème du répertoire est chargé.
  it "loads a document theme file only from the document directory" do
    with_tree do |conv, secret|
      ailleurs = File.dirname(secret)
      File.write(File.join(ailleurs, "a5.yml"), "page_size: A5\n")
      File.write(File.join(conv, "a5.yml"), "page_size: A5\n")

      {"#{ailleurs}/a5.yml" => false, "../ailleurs/a5.yml" => false, "a5.yml" => true}.each do |theme, applied|
        adoc = File.join(conv, "theme.adoc")
        pdf = File.join(conv, "theme.pdf")
        File.write(adoc, "= Theme\n:pdf-theme: #{theme}\n\nContenu.\n")
        doc = Asciicrystal.load_file(adoc, {"outfile" => pdf, "safe" => "secure"})
        AsciicrystalPDF::Converter.new("pdf").convert(doc)
        (IntegrationHelper.count_byte_pattern(pdf, "MediaBox [0 0 419 595]") > 0).should eq(applied)
      end
    end
  end
end
