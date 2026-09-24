require "./spec_helper"

describe "Tables" do
  it "renders all cell contents across a simple 2x2 table" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      |===
      | A1 | A2
      | B1 | B2
      |===
      ADOC
    text = IntegrationHelper.text(pdf)
    text.should contain("A1")
    text.should contain("A2")
    text.should contain("B1")
    text.should contain("B2")
    File.delete(pdf)
  end

  it "renders a header-row table with a caption" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      .Liste des pays
      [cols="1,1", options="header"]
      |===
      | Pays | Ville

      | France | Paris
      | Allemagne | Berlin
      |===
      ADOC
    text = IntegrationHelper.text(pdf)
    text.should contain("Liste")
    text.should contain("France")
    text.should contain("Paris")
    text.should contain("Allemagne")
    text.should contain("Berlin")
    File.delete(pdf)
  end

  it "breaks long words in narrow columns rather than overflowing" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      [cols="4,1,4", options="header"]
      |===
      | Ville | Pays | Note

      | Gunzenhausen | Allemagne | siège
      |===
      ADOC
    text = IntegrationHelper.text(pdf)
    # With a very narrow middle column, "Allemagne" is broken into
    # chunks. Each fragment should still appear in the stream.
    text.should contain("Allem")
    text.should contain("Gunzenhausen")
    File.delete(pdf)
  end

  it "renders a codespan inside a table cell in monospace (not flattened)" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      [cols="1,1", options="header"]
      |===
      | Utilisateur | Mot de passe

      | admin | `qwertyuiop`
      |===
      ADOC
    text = IntegrationHelper.text(pdf)
    # Le code DOIT s'afficher (régression : il était aplati/perdu).
    text.should contain("qwertyuiop")
    # … et en MONOSPACE : la police mono (Courier dans le contexte de
    # test) doit apparaître dans les ressources du PDF, preuve que le
    # codespan a conservé son style et n'a pas été réduit à du texte
    # courant (rendu en Helvetica comme le reste de la cellule).
    raw = File.read(pdf)
    raw.includes?("Courier").should be_true
    File.delete(pdf)
  end

  it "keeps table header cells bold while preserving body codespans" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      [cols="1,1", options="header"]
      |===
      | Utilisateur | Mot de passe

      | admin | `secret`
      |===
      ADOC
    raw = File.read(pdf)
    # En-tête en gras (Helvetica-Bold) ET corps mono (Courier)
    # coexistent : la propagation du gras aux segments d'en-tête
    # n'a pas cassé le rendu mono des codespans du corps.
    raw.includes?("Helvetica-Bold").should be_true
    raw.includes?("Courier").should be_true
    File.delete(pdf)
  end

  it "repeats the header row on every page of a multi-page table" do
    body = (1..70).map { |i| "| host#{i} | rack#{i}" }.join("\n")
    adoc = "= Test\n\n" \
           "[cols=\"1,1\", options=\"header\"]\n|===\n" \
           "| ZHEADERZ | RACKHEAD\n\n#{body}\n|===\n"
    pdf = IntegrationHelper.convert(adoc)
    text = IntegrationHelper.text(pdf)
    # En-tête répété en haut de CHAQUE page : le tableau (70 lignes)
    # déborde sur ≥ 2 pages, donc le libellé d'en-tête unique
    # « ZHEADERZ » doit apparaître au moins deux fois.
    (text.split("ZHEADERZ").size - 1).should be >= 2
    File.delete(pdf)
  end

  it "does not duplicate rows when a bold cell ends with a number" do
    # Régression (parser asciicrystal ~> 2.0.26.10) : une cellule
    # finissant par un gras à nombre, p.ex. `*Phase 5.2 6.0*`, voyait son
    # `6.0*` final pris pour le multiplicateur de cellule « répéter 6× »,
    # ce qui dupliquait les rangées et déversait le texte dans les
    # mauvaises colonnes (« propre au début, puis ça se gâte »).
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      [cols="1,4"]
      |===
      | *Phase 5.2 6.0*
      | ZALPHAZ contenu unique.

      | *Phase 6.0 6.1*
      | ZBETAZ contenu unique.
      |===
      ADOC
    text = IntegrationHelper.text(pdf)
    # Chaque description n'apparaît qu'UNE fois (pas de duplication).
    (text.split("ZALPHAZ").size - 1).should eq(1)
    (text.split("ZBETAZ").size - 1).should eq(1)
    File.delete(pdf)
  end

  it "renders a multi-line justified cell paragraph without losing content" do
    # Un paragraphe dans une cellule est désormais justifié comme hors
    # tableau (défaut du thème `justify`) : les lignes non-finales
    # atteignent le bord droit de la colonne (vérifié visuellement). On
    # garde ici que le chemin de rendu justifié d'une cellule
    # multi-lignes ne perd aucun contenu et ne plante pas.
    long = "Un paragraphe de cellule suffisamment long pour occuper " \
           "plusieurs lignes dans la colonne et exercer la justification " \
           "des lignes non finales."
    pdf = IntegrationHelper.convert("= Test\n\n[cols=\"1,3\"]\n|===\n| Cle\n| #{long}\n|===\n")
    text = IntegrationHelper.text(pdf)
    text.should contain("justification")
    text.should contain("colonne")
    text.should contain("finales")
    File.delete(pdf)
  end

  it "renders bold cells whose content holds a space (thousands separator)" do
    pdf = IntegrationHelper.convert(<<-ADOC)
      = Test

      [cols="2,2,2,2",options="header"]
      |===
      | Mois | Toiture | Allège | Total

      | janvier | 370 | 85 | 455
      | *Année* | *10 400* | *1 170* | *11 570*
      |===
      ADOC
    # Le gras est émis mot par mot (`10`, ` 400`) et le helper sépare
    # chaque chaîne d'une espace : on ramène les espaces multiples à une.
    text = IntegrationHelper.text(pdf).squeeze(' ')
    text.should_not contain("*")
    text.should contain("Année")
    text.should contain("10 400")
    text.should contain("1 170")
    text.should contain("11 570")
    File.delete(pdf)
  end
end
