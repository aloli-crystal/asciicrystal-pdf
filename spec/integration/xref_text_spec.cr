require "./spec_helper"

# Un renvoi `<<id>>` sans libellé affiche le titre de la section ciblée,
# comme Asciidoctor, et non son identifiant.
describe "Integration · texte des renvois" do
  it "uses the target section title for an xref without label" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test
      :sectnums:

      == Bilan

      Voir <<pilotage>> plus loin.

      [[pilotage]]
      == Adapter la consommation

      Retour vers <<pilotage>>.
      ADOC
    text = IntegrationHelper.text(pdf).squeeze(' ')
    text.should_not contain("Voir pilotage")
    text.should contain("Voir Adapter la consommation")
    text.should contain("Retour vers Adapter la consommation")
    File.delete(pdf)
  end
end
