require "./spec_helper"

# TOC entries should be clickable anchors that navigate to the matching
# section in the document body. Implemented via PDF named destinations
# (one per section) plus link annotations on the TOC page rectangles.
describe "Integration · TOC anchors" do
  it "registers one /XYZ destination per section (named-dest + outline item)" do
    source = <<-ADOC
      = Document
      :toc:

      == First

      Body of first.

      == Second

      Body of second.

      == Third

      Body of third.
      ADOC

    path = IntegrationHelper.convert(source)
    begin
      # Each section contributes:
      #   - one `/XYZ` array in the document's named-destination tree
      #     (referenced by the TOC link annotations)
      #   - one `/XYZ` array in the /Outlines tree (the PDF bookmark)
      # so we expect 2 × number_of_sections /XYZ entries total.
      IntegrationHelper.xyz_destination_count(path).should eq(6)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "emits one /Subtype /Link annotation per TOC entry" do
    source = <<-ADOC
      = Document
      :toc:

      == Alpha

      a

      == Beta

      b

      == Gamma

      g
      ADOC

    path = IntegrationHelper.convert(source)
    begin
      # Three TOC entries → at least three link annotations on the TOC
      # page. The outline (PDF bookmarks) does not add link annotations
      # — it lives in a separate /Outlines tree — so the count
      # precisely matches the number of TOC entries.
      IntegrationHelper.link_annotation_count(path).should eq(3)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "produces no link annotations when the document has no TOC" do
    # Without `:toc:`, the TOC page is not rendered and no clickable
    # entries exist. Named destinations are still registered (they're
    # cheap and fuel the outline / bookmarks), but no Link annotations
    # are emitted on body pages.
    source = <<-ADOC
      = Document

      == Section

      Body.
      ADOC

    path = IntegrationHelper.convert(source)
    begin
      IntegrationHelper.link_annotation_count(path).should eq(0)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "uses the section's id as the destination name (parser-supplied)" do
    source = <<-ADOC
      = Document
      :toc:

      == Overview

      Body.
      ADOC

    path = IntegrationHelper.convert(source)
    begin
      # The asciicrystal parser auto-generates an id (`_overview`
      # by default) for each section. That id surfaces verbatim as a
      # PDF named destination — explicit `[[overview]]` ids would too.
      IntegrationHelper.count_byte_pattern(path, "(_overview)").should be > 0
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "places an article doctitle on the SAME page as its TOC" do
    # Régression : pour un article (pas de page de garde) avec `:toc:`,
    # la TOC occupait seule la 1re page et le doctitle tombait sur la
    # page suivante — la TOC apparaissait « sans titre ». Le doctitle
    # doit désormais coiffer la TOC sur la même première page.
    source = <<-ADOC
      = Mon Article
      Jean Dupont

      :toc:

      == Section Un

      Contenu un.

      == Section Deux

      Contenu deux.
      ADOC

    path = IntegrationHelper.convert(source)
    begin
      page1 = IntegrationHelper.page_text(path, 0)
      # Le doctitle est bien sur la 1re page…
      page1.should contain("Mon Article")
      # … en compagnie de la TOC (son titre + au moins une entrée).
      page1.should contain("Table des matières")
      page1.should contain("Section Un")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
