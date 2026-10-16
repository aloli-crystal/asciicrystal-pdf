require "./spec_helper"

describe "Lists" do
  it "renders an unordered list with bullet markers" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      * Premier
      * Deuxième
      * Troisième
      ADOC
    text = IntegrationHelper.text(pdf)
    text.should contain("Premier")
    text.should contain("Deuxième")
    text.should contain("Troisième")
    File.delete(pdf)
  end

  it "renders an ordered list with numeric markers" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      . Alpha
      . Bravo
      . Charlie
      ADOC
    text = IntegrationHelper.text(pdf)
    text.should contain("Alpha")
    text.should contain("Bravo")
    text.should contain("Charlie")
    text.should match(/1\./)
    text.should match(/2\./)
    text.should match(/3\./)
    File.delete(pdf)
  end

  # Blocs rattachés à un élément par `+` (bloc de code, paragraphe…) :
  # alignés sur le texte de l'élément, comme Asciidoctor PDF, et non sur
  # la marge de la page. Le fond d'un bloc de code est un rectangle :
  # sa position horizontale suffit.
  it "aligns blocks attached to a list item on the item text" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      ----
      hors liste
      ----

      . Étape
      +
      ----
      dans la liste
      ----
      +
      Paragraphe rattaché.
      . Suite
      ADOC
    theme = AsciicrystalPDF::Theme.new
    # Fond et cadre : deux rectangles par bloc, regroupés par hauteur.
    boxes = IntegrationHelper.rectangles(pdf).select { |r| r[2] > 100.0 }.uniq(&.[1].round)
    boxes.size.should eq(2)
    outside, inside = boxes.sort_by { |r| -r[1] }
    outside[0].should be_close(theme.page_margin, 0.5)
    inside[0].should be_close(theme.page_margin + theme.list_indent, 0.5)
    (inside[2] - (outside[2] - theme.list_indent)).abs.should be < 0.5
    text = IntegrationHelper.text(pdf)
    text.should contain("Paragraphe")
    text.should match(/2\./)
    File.delete(pdf)
  end

  it "renders a definition list" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      Meaux:: 10 km
      Reims:: 140 km
      ADOC
    text = IntegrationHelper.text(pdf)
    text.should contain("Meaux")
    text.should contain("Reims")
    text.should contain("10 km")
    text.should contain("140 km")
    File.delete(pdf)
  end
end
