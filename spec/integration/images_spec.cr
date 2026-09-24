require "./spec_helper"
require "file_utils"
require "stumpy_png"

# Images de bloc (`image::…[]`) : SVG et bitmap.
#
# Problèmes corrigés, rencontrés sur un plan coté en SVG :
# * un SVG plus haut que la page débordait sur le pied de page ;
# * une valeur de `width` illisible (`"100%"`, ou une virgule non
#   protégée dans le texte alternatif, lue comme `width`) levait une
#   exception avalée : cadre de remplacement sans explication ;
# * le titre `.Mon titre` d'une image n'était pas rendu ;
# * les `<text>` du SVG sortaient en Helvetica WinAnsi (≈ → ?) même
#   avec une police TTF dans le thème ;
# * une image bitmap était ancrée par son haut alors que `page.image`
#   ancre par le bas : elle se dessinait au-dessus de sa place.

A4_HEIGHT = 841.89

private def with_dir(&)
  dir = File.tempname("cap-pdf-img")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# SVG dont un rectangle couvre toute la viewBox : sa position dans le
# PDF donne celle de l'image.
private def full_rect_svg(width : Int32, height : Int32) : String
  %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}">) +
    %(<rect x="0" y="0" width="#{width}" height="#{height}" fill="#b07a3c"/></svg>)
end

describe "block images" do
  it "shrinks an SVG taller than the page so that it fits on one page" do
    with_dir do |dir|
      File.write(File.join(dir, "haut.svg"), full_rect_svg(100, 3000))
      pdf = IntegrationHelper.convert(<<-ADOC, docdir: dir)
        = Image haute

        image::haut.svg[Haut]
        ADOC

      rects = IntegrationHelper.rectangles(pdf)
      rects.size.should eq(1)
      _, y, _, h = rects.first
      y.should be >= 0.0
      (y + h).should be <= A4_HEIGHT
      File.delete(pdf)
    end
  end

  it "reads a percentage width, and ignores an unreadable one instead of failing" do
    with_dir do |dir|
      File.write(File.join(dir, "large.svg"), full_rect_svg(400, 100))
      pdf = IntegrationHelper.convert(<<-ADOC, docdir: dir)
        = Largeurs

        image::large.svg[Plein,width=100%]

        image::large.svg[Moitié,pdfwidth=50%]

        image::large.svg[Titre, avec une virgule]
        ADOC

      IntegrationHelper.text(pdf).should_not contain("[Image:")
      widths = IntegrationHelper.rectangles(pdf).map { |r| r[2] }
      widths.size.should eq(3)
      (widths[0] / widths[1]).should be_close(2.0, 0.01)
      File.delete(pdf)
    end
  end

  it "draws a frame for a missing image" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Image absente

      image::absente.svg[Absente]
      ADOC

    IntegrationHelper.text(pdf).should contain("[Image: Absente]")
    File.delete(pdf)
  end

  it "renders the block title under the image, numbered like upstream" do
    with_dir do |dir|
      File.write(File.join(dir, "plan.svg"), full_rect_svg(200, 100))
      pdf = IntegrationHelper.convert(<<-ADOC, docdir: dir)
        = Titre d'image

        .Plan du podium
        image::plan.svg[Plan]
        ADOC

      IntegrationHelper.text(pdf).should contain("Figure 1. Plan du podium")
      File.delete(pdf)
    end
  end

  it "draws the SVG texts with the theme TrueType font" do
    with_dir do |dir|
      File.write(File.join(dir, "texte.svg"), <<-SVG)
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 50">
          <text x="100" y="30" text-anchor="middle">env. ≈ 10 m → ■</text>
        </svg>
        SVG
      pdf = IntegrationHelper.convert(<<-ADOC, docdir: dir, type1_fonts: false)
        = Texte SVG

        image::texte.svg[Texte]
        ADOC

      IntegrationHelper.count_byte_pattern(pdf, "/BaseFont /Helvetica").should eq(0)
      File.delete(pdf)
    end
  end

  it "anchors a bitmap image below the current position" do
    with_dir do |dir|
      canvas = StumpyPNG::Canvas.new(40, 20, StumpyPNG::RGBA.from_hex("#b07a3c"))
      StumpyPNG.write(canvas, File.join(dir, "bloc.png"))
      pdf = IntegrationHelper.convert(<<-ADOC, docdir: dir)
        = Image bitmap

        image::bloc.png[Bloc,width=200]
        ADOC

      placements = IntegrationHelper.image_placements(pdf)
      placements.size.should eq(1)
      _, height, _, y = placements.first
      height.should be_close(100.0, 0.01)
      # Le haut de l'image reste sous le titre du document, donc sous
      # le haut de la zone de contenu.
      (y + height).should be < A4_HEIGHT - 36.0
      File.delete(pdf)
    end
  end
end
