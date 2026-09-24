require "./spec_helper"

# `:toc-title:` est un attribut AsciiDoc standard. Sans lui, le libellé
# du sommaire vient du thème, dont le défaut est français — ce qui
# donnait un « Table des matières » au milieu d'un document anglais.
describe "toc-title" do
  it "uses the document's :toc-title: for the TOC heading" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = A document in English
      :toc:
      :toc-title: Contents

      == First section

      Text.

      == Second section

      Text.
      ADOC

    text = IntegrationHelper.text(pdf)
    text.should contain("Contents")
    text.should_not contain("Table des")

    File.delete(pdf)
  end

  it "falls back to the theme label when the attribute is absent" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Un document en français
      :toc:

      == Première section

      Texte.

      == Deuxième section

      Texte.
      ADOC

    IntegrationHelper.text(pdf).should contain("Table des")

    File.delete(pdf)
  end
end
