require "./spec_helper"

private def field_of(type : String, *, cols : Int32 = 1, rows : Int32? = nil, options : Array(String) | Hash(String, String)? = nil) : AsciicrystalPDF::FormField
  AsciicrystalPDF::FormField.new(
    id: "x",
    type: type,
    cols: cols,
    rows: rows,
    options: options,
  )
end

describe AsciicrystalPDF::FormRenderer do
  describe ".column_width" do
    it "retourne la largeur entière pour 1 colonne" do
      AsciicrystalPDF::FormRenderer.column_width(1, 500.0).should eq(500.0)
    end

    it "divise correctement pour 2 colonnes avec gutter par défaut" do
      # gutter = 10, content_width = 510 → col_w = (510 - 10) / 2 = 250
      AsciicrystalPDF::FormRenderer.column_width(2, 510.0).should eq(250.0)
    end

    it "divise correctement pour 3 colonnes" do
      # gutter = 10, content_width = 520 → col_w = (520 - 20) / 3 ≈ 166.66
      r = AsciicrystalPDF::FormRenderer.column_width(3, 520.0)
      r.should be_close(166.666, 0.01)
    end

    it "respecte un gutter personnalisé" do
      # gutter = 20, content_width = 540, 3 cols → (540 - 40) / 3 ≈ 166.66
      r = AsciicrystalPDF::FormRenderer.column_width(3, 540.0, 20.0)
      r.should be_close(166.666, 0.01)
    end

    it "lève si columns < 1" do
      expect_raises(ArgumentError, /columns must be >= 1/) do
        AsciicrystalPDF::FormRenderer.column_width(0, 500.0)
      end
    end
  end

  describe ".widget_height" do
    it "retourne 18.0 pour text/email/url/tel/password/number/date/checkbox" do
      %w[text email url tel password number date checkbox select].each do |t|
        AsciicrystalPDF::FormRenderer.widget_height(field_of(t)).should eq(18.0)
      end
    end

    it "calcule rows × ligne pour textarea (rows fournis)" do
      f = field_of("textarea", rows: 6)
      AsciicrystalPDF::FormRenderer.widget_height(f).should eq(6 * 14.0)
    end

    it "défaut 4 rows pour textarea sans rows" do
      f = field_of("textarea")
      AsciicrystalPDF::FormRenderer.widget_height(f).should eq(4 * 14.0)
    end

    it "calcule options × spacing pour radio" do
      f = field_of("radio", options: ["A", "B", "C", "D"])
      AsciicrystalPDF::FormRenderer.widget_height(f).should eq(4 * 18.0)
    end

    it "retourne 60.0 pour select-multi" do
      AsciicrystalPDF::FormRenderer.widget_height(field_of("select-multi", options: ["A"])).should eq(60.0)
    end

    it "retourne 50.0 pour signature" do
      AsciicrystalPDF::FormRenderer.widget_height(field_of("signature")).should eq(50.0)
    end
  end

  describe ".clamped_span" do
    it "garde cols dans [1, max_cols]" do
      AsciicrystalPDF::FormRenderer.clamped_span(field_of("text", cols: 1), 3).should eq(1)
      AsciicrystalPDF::FormRenderer.clamped_span(field_of("text", cols: 2), 3).should eq(2)
      AsciicrystalPDF::FormRenderer.clamped_span(field_of("text", cols: 3), 3).should eq(3)
    end

    it "borne cols à max_cols si plus grand" do
      AsciicrystalPDF::FormRenderer.clamped_span(field_of("text", cols: 5), 3).should eq(3)
    end

    it "remonte cols à 1 si < 1" do
      # Le constructeur de FormField n'empêche pas cols < 1 (validation
      # côté FormBuilder), mais le helper du renderer reste sûr.
      f = AsciicrystalPDF::FormField.new(id: "x", type: "text", cols: 0)
      AsciicrystalPDF::FormRenderer.clamped_span(f, 2).should eq(1)
    end
  end
end
