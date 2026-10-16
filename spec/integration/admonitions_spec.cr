require "./spec_helper"

describe "Admonitions" do
  {
    "NOTE"      => "NOTE",
    "TIP"       => "TIP",
    "IMPORTANT" => "IMPORTANT",
    "WARNING"   => "WARNING",
    "CAUTION"   => "CAUTION",
  }.each do |kind, label|
    it "renders a #{kind} admonition with its label and body" do
      pdf = IntegrationHelper.convert(<<-ADOC)
        = Test

        #{kind}: Message de test pour #{kind}.
        ADOC
      text = IntegrationHelper.text(pdf)
      text.should contain(label)
      text.should contain("Message")
      text.should contain("test")
      File.delete(pdf)
    end
  end

  it "renders a multi-line admonition block" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      [WARNING]
      ====
      Première ligne.

      Seconde ligne.
      ====
      ADOC
    text = IntegrationHelper.text(pdf)
    text.should contain("WARNING")
    text.should contain("Première")
    text.should contain("Seconde")
    File.delete(pdf)
  end
end
