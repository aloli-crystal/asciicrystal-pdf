require "asciicrystal"
require "pdf"
require "country-flags"
require "emojis"
require "noto-cjk"
require "./inline_flags"

module AsciicrystalPDF
  # Convertisseur AsciiDoc → PDF pour asciicrystal.
  # Suit le pattern des convertisseurs asciicrystal (HTML5, DocBook5, ManPage).
  # S'enregistre sous le backend "pdf".
  class Converter < Asciicrystal::Converter::Base
    register_for "pdf"

    # Métadonnées de page pour les en-têtes/pieds de page.
    # `chrome = false` désactive header / footer / footnotes sur la
    # page (utilisé pour la page de garde, qu'on veut typographiquement
    # « nue »).
    # `numbering` indique le style de numérotation à afficher dans le
    # footer : `:none` (aucun numéro), `:roman` (i, ii, iii — front-
    # matter), `:arabic` (1, 2, 3 — corps de doc).
    # `displayed_number` est calculé après coup par
    # `assign_displayed_numbers` pour que les compteurs roman / arabic
    # repartent chacun de 1. Mutable parce qu'on l'assigne en post.
    class PageMeta
      property number : Int32
      property section_title : String
      property chrome : Bool
      property numbering : Symbol
      property displayed_number : Int32

      def initialize(@number : Int32, @section_title : String, @chrome : Bool = true, @numbering : Symbol = :arabic, @displayed_number : Int32 = 0)
      end
    end

    # Entrée d'index
    record IndexEntry, term : String, page_number : Int32

    # Note de bas de page
    record FootnoteEntry, index : Int32, text : String, page_number : Int32

    # --- Polices ---
    # Les polices sont résolues au démarrage : si le thème définit des chemins TTF,
    # elles sont chargées ; sinon les polices Type1 standard sont utilisées.
    # Ceci permet de mesurer le texte et de rendre avec les mêmes polices.
    @font_body : PDF::Fonts::Base?
    @font_body_bold : PDF::Fonts::Base?
    @font_body_italic : PDF::Fonts::Base?
    @font_body_bold_italic : PDF::Fonts::Base?
    @font_mono : PDF::Fonts::Base?
    @font_mono_bold : PDF::Fonts::Base?
    @font_heading : PDF::Fonts::Base?
    # Police CJK chargée au boot si noto-cjk a une variante
    # en cache. `draw_text_run` bascule la police courante sur cette
    # variante pour les segments contenant des codepoints CJK, puis
    # remet la police principale pour le reste — même pattern que
    # le rendu d'emojis qui utilise page.svg pour les glyphes
    # spécifiques.
    @font_cjk : PDF::Fonts::TrueTypeFont?
    @fn_cjk : String = ""

    # Chargement paresseux de la police CJK : on mémorise juste le
    # chemin au démarrage et on charge effectivement la fonte au
    # premier caractère CJK rencontré dans le document. Cela évite
    # d'allouer la fonte (et de lever `UnsupportedFontFormat` pour
    # les `.otf`) quand le document n'a aucun caractère CJK. Cf.
    # note mémoire ALOLI `roadmap_pdf_cff_subsetting.md`.
    @cjk_font_path : String? = nil
    @cjk_load_attempted : Bool = false

    # Noms de polices utilisés dans les appels page.font()
    @fn_body : String = "Helvetica"
    @fn_body_bold : String = "Helvetica-Bold"
    @fn_body_italic : String = "Helvetica-Oblique"
    @fn_body_bold_italic : String = "Helvetica-BoldOblique"
    @fn_mono : String = "Courier"
    @fn_mono_bold : String = "Courier-Bold"
    @fn_heading : String = "Helvetica-Bold"

    # --- État interne ---
    @doc : PDF::Document
    @theme : Theme
    @current_page : PDF::Page?
    @current_y : Float64 = 0.0
    @page_number : Int32 = 0
    @page_metas : Array(PageMeta) = [] of PageMeta
    @current_section_title : String = ""
    @document_title : String = ""
    # Nom du fichier source AsciiDoc (`docfile`, repli `docname`).
    # Sert à préfixer les `WARNING` stderr pour qu'on sache, en
    # conversion multi-fichiers (`*.adoc`), DE QUEL fichier provient
    # l'avertissement. Vide si l'info n'est pas disponible.
    @document_file : String = ""
    # Langue du document AsciiDoc (`:lang:` ou défaut `en`).
    # Utilisée pour résoudre les patterns de césure Liang via
    # `Hyphenation::Loader.for(@document_lang)`. `nil` = pas de
    # césure (le composer émet des Box monolithiques).
    @document_lang : String? = nil
    @index_entries : Array(IndexEntry) = [] of IndexEntry
    # Entrées de la table des matières.
    # Chaque entrée capture {titre, niveau, page (1-based), nom de destination
    # PDF, coordonnée Y (PDF, repère bas-gauche) du haut du titre}. Le nom
    # de destination est unique dans le document et permet à la TOC ainsi
    # qu'à l'outline (bookmarks) de pointer précisément sur le début de la
    # section, pas seulement sur la page.
    @toc_entries : Array({String, Int32, Int32, String, Float64}) = [] of {String, Int32, Int32, String, Float64}
    # Compteur pour générer des noms de destination uniques quand la
    # section n'a pas d'id explicite côté AsciiDoc.
    @dest_counter : Int32 = 0
    @anchor_positions : Hash(String, Float64) = {} of String => Float64 # {id => y_position}
    @footnotes : Array(FootnoteEntry) = [] of FootnoteEntry             # notes de bas de page
    @footnotes_by_page : Hash(Int32, Array(FootnoteEntry)) = {} of Int32 => Array(FootnoteEntry)
    @output_path : String = "output.pdf"
    # Caractères hors WinAnsi déjà signalés à l'utilisateur pendant
    # cette conversion. On dédup pour ne pas spammer STDERR si un
    # même emoji apparaît N fois dans le source.
    @warned_chars : Set(Char) = Set(Char).new
    # État du mode `x-title-page-toc` : page index (0-based) où rendre la
    # TOC en post-traitement, et ordonnée Y (PDF, top) à partir de
    # laquelle commencer le rendu. Restent à -1 / 0 quand le mode n'est
    # pas activé.
    @title_page_toc_index : Int32 = -1
    @title_page_toc_y_start : Float64 = 0.0

    # Répétition d'en-tête de tableau : pendant le rendu d'un tableau
    # multi-pages, ce hook re-dessine la (les) ligne(s) d'en-tête en haut
    # de chaque nouvelle page. Posé par `convert_table`, invoqué par
    # `check_page_break` juste après un saut de page. nil hors tableau.
    @repeat_table_header : Proc(Nil)? = nil

    # Dimensions de la page (A4 par défaut). Surchargeables via le
    # thème (`page_size`, `page_layout`) ou les attributs document
    # `:pdf-page-size:`, `:pdf-page-layout:` au moment de
    # `convert_document`.
    @page_width : Float64 = 595.28
    @page_height : Float64 = 841.89
    @margin : Float64 = 36.0
    @content_width : Float64 = 0.0

    # Tailles de page standard en points PDF (1pt = 1/72 in).
    # Format portrait : {largeur, hauteur}.
    PAGE_SIZES = {
      "A0"      => {2383.94, 3370.39},
      "A1"      => {1683.78, 2383.94},
      "A2"      => {1190.55, 1683.78},
      "A3"      => {841.89, 1190.55},
      "A4"      => {595.28, 841.89},
      "A5"      => {419.53, 595.28},
      "A6"      => {297.64, 419.53},
      "B5"      => {498.90, 708.66},
      "LETTER"  => {612.00, 792.00},
      "LEGAL"   => {612.00, 1008.00},
      "TABLOID" => {792.00, 1224.00},
    }

    # `@theme_provided` mémorise si l'appelant a passé un thème
    # explicite. Quand non (theme: nil), `convert_document` peut
    # résoudre dynamiquement via l'attribut document `:pdf-theme:`
    # — alignement avec le comportement du CLI.
    @theme_provided : Bool = false

    def initialize(backend : String = "pdf", theme : Theme? = nil)
      super(backend)
      @theme_provided = !theme.nil?
      @theme = theme || Theme.new
      @doc = PDF::Document.new
      @backend_traits = Asciicrystal::Converter::BackendTraits.new(
        basebackend: "pdf",
        filetype: "pdf",
        outfilesuffix: ".pdf"
      )
      @margin = @theme.page_margin
      apply_page_size(@theme.page_size, @theme.page_layout)

      # Charger les polices TTF si définies dans le thème
      load_theme_fonts
    end

    # Applique une taille et orientation à la page. La taille est
    # résolue depuis `PAGE_SIZES` (insensible à la casse). L'orientation
    # `landscape` permute largeur et hauteur. Cas inconnu → A4.
    private def apply_page_size(size : String, layout : String) : Nil
      key = size.upcase
      dims = PAGE_SIZES[key]? || PAGE_SIZES["A4"]
      w, h = dims
      if layout.downcase == "landscape"
        @page_width = h
        @page_height = w
      else
        @page_width = w
        @page_height = h
      end
      @content_width = @page_width - (2 * @margin)
    end

    # Point d'entrée principal : convertit le document et écrit le PDF
    def convert(node : Asciicrystal::AbstractNode, transform : String? = nil) : String
      transform ||= node.node_name
      dispatch(node, transform)
    end

    def dispatch(node : Asciicrystal::AbstractNode, transform : String) : String
      case transform
      when "document"         then convert_document(node)
      when "section"          then convert_section(node)
      when "paragraph"        then convert_paragraph(node)
      when "listing"          then convert_listing(node)
      when "literal"          then convert_literal(node)
      when "admonition"       then convert_admonition(node)
      when "ulist"            then convert_ulist(node)
      when "olist"            then convert_olist(node)
      when "dlist"            then convert_dlist(node)
      when "table"            then convert_table(node)
      when "image"            then convert_image(node)
      when "page_break"       then convert_page_break(node)
      when "thematic_break"   then convert_thematic_break(node)
      when "quote"            then convert_quote(node)
      when "verse"            then convert_verse(node)
      when "sidebar"          then convert_sidebar(node)
      when "example"          then convert_example(node)
      when "open"             then convert_open(node)
      when "preamble"         then convert_preamble(node)
      when "toc"              then "" # géré dans convert_document
      when "floating_title"   then convert_floating_title(node)
      when "inline_anchor"    then convert_inline_anchor(node)
      when "inline_break"     then ""
      when "inline_button"    then convert_inline_button(node)
      when "inline_callout"   then convert_inline_callout(node)
      when "inline_footnote"  then convert_inline_footnote(node)
      when "inline_image"     then convert_inline_image(node)
      when "inline_indexterm" then convert_inline_indexterm(node)
      when "inline_kbd"       then convert_inline_kbd(node)
      when "inline_menu"      then convert_inline_menu(node)
      when "inline_quoted"    then convert_inline_quoted(node)
      when "pass"             then convert_pass(node)
      when "stem"             then convert_stem(node)
      when "audio"            then convert_audio(node)
      when "video"            then convert_video(node)
      when "colist"           then convert_colist(node)
      when "outline"          then ""
      when "embedded"         then convert_embedded(node)
      else                         ""
      end
    end

    # =========================================================================
    # Document
    # =========================================================================

    def convert_document(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Document)

      # Decode HTML entities in the document title once here so every
      # downstream renderer (title page, headers, PDF metadata, index
      # title, …) sees a plain-text title. NBSPs remain as U+00A0 so
      # `wrap_text` preserves the non-break property ; they become
      # ASCII spaces only just before each `page.text` call.
      @document_title = decode_html_entities(node.doctitle || "")
      @output_path = determine_output_path(node)

      # Nom du fichier source, pour préfixer les WARNING (savoir de quel
      # fichier ils proviennent en conversion multi-fichiers). `docfile`
      # d'abord (chemin tel que passé), repli sur `docname`.
      @document_file =
        if node.attr?("docfile") && !node.attr("docfile").to_s.empty?
          node.attr("docfile").to_s
        elsif node.attr?("docname")
          node.attr("docname").to_s
        else
          ""
        end

      # Détection de la langue : attribut `:lang:` du document
      # AsciiDoc. Détermine quel pattern Liang sera utilisé pour
      # la césure. Pas de valeur par défaut implicite — si
      # l'auteur n'a pas spécifié, on n'active pas la césure
      # (composition sans césure, comportement gracieux).
      lang_attr = node.attr?("lang") ? node.attr("lang").to_s.strip : ""
      @document_lang = lang_attr.empty? ? nil : lang_attr

      # Résolution per-document du thème : si l'utilisateur n'a pas
      # passé de thème explicite au constructeur, on lit l'attribut
      # AsciiDoc `:pdf-theme:` et on charge le thème embarqué (ou un
      # fichier YAML) correspondant. Alignement de comportement entre
      # le CLI (qui faisait déjà ça) et l'API directe (qui ignorait
      # cet attribut).
      if !@theme_provided && (pdf_theme = node.attr("pdf-theme")) && !pdf_theme.to_s.empty?
        @theme = ThemeLoader.resolve(pdf_theme.to_s)
        @margin = @theme.page_margin
        apply_page_size(@theme.page_size, @theme.page_layout)
        load_theme_fonts
      end

      # Métadonnées PDF
      # Override per-document de la taille / orientation par les
      # attributs AsciiDoc `:pdf-page-size:`, `:pdf-page-layout:`.
      # Permet à un doc précis d'imposer A3 paysage sans toucher au
      # thème global. Parité Ruby asciicrystal-pdf.
      pdf_size = node.attr("pdf-page-size")
      pdf_layout = node.attr("pdf-page-layout")
      if pdf_size || pdf_layout
        apply_page_size(
          (pdf_size || @theme.page_size).to_s,
          (pdf_layout || @theme.page_layout).to_s,
        )
      end

      @doc.title = @document_title unless @document_title.empty?
      @doc.author = node.attr("author") if node.attr?("author")
      @doc.subject = node.attr("subject") if node.attr?("subject")
      # Keywords : virgule-séparé est le format Ruby asciicrystal-pdf et
      # le format conventionnel des métadonnées PDF.
      @doc.keywords = node.attr("keywords") if node.attr?("keywords")
      # Creator : nom de l'application qui a *produit* le contenu (par
      # opposition à `producer` = nom du moteur PDF). Utile pour
      # identifier la chaîne d'outillage qui a généré le document.
      if node.attr?("creator")
        @doc.creator = node.attr("creator")
      end
      @doc.producer = "asciicrystal-pdf #{AsciicrystalPDF::VERSION}"

      # Numérotation front-matter en chiffres romains : activée par
      # l'attribut document `:pdf-front-matter-numbering: roman`
      # (parité Ruby asciicrystal-pdf). Quand activée, la garde et la
      # TOC réservée sont marquées :roman, le contenu :arabic ; les
      # deux compteurs repartent de 1 chacun. Sinon, tout en :arabic
      # continu (comportement historique).
      front_matter_roman = (node.attr("pdf-front-matter-numbering").to_s.downcase == "roman")
      front_numbering = front_matter_roman ? :roman : :arabic

      # Page de titre
      # Décision : page de garde dédiée OU titre H1 en haut de page 1 OU rien.
      # Convention :
      #   :title-page:        ⇒ activée explicitement
      #   :title-page: false  ⇒ désactivée explicitement (équivalent
      #                          standard à `:!title-page:` — non
      #                          détectable côté asciicrystal,
      #                          d'où l'usage de la valeur explicite)
      #   absent              ⇒ défaut du thème (`title_page_enabled`)
      title_rendered = false
      title_page_toc_active = false
      inline_doctitle = false
      if !@document_title.empty?
        if title_page_active?(node)
          render_title_page(node)
          title_rendered = true
          # Si `render_title_page_with_toc` a été retenu, il a positionné
          # @title_page_toc_index ≥ 0 — la TOC sera rendue sur la page de
          # garde en post-traitement, pas sur une page réservée.
          title_page_toc_active = @title_page_toc_index >= 0
        else
          # Pas de page de garde : on rendra le doctitle comme un H1
          # tout en haut de la première page de contenu, conformément
          # au mode `:doctype: article` standard d'AsciiDoc.
          inline_doctitle = true
        end
      end

      # Table des matières + doctitle inline. Trois dispositions selon
      # le type de document :
      #
      #   • Article AVEC TOC : le doctitle (titre + auteur + date) est
      #     rendu en haut de la 1re page, PUIS la TOC le suit INLINE sur
      #     cette même page (placement `auto` d'AsciiDoc pour un
      #     article), et le corps démarre page suivante. Sans ça, la TOC
      #     occupait seule une page réservée et le doctitle tombait sur
      #     la page de contenu d'après : la TOC apparaissait « sans
      #     titre » (bug signalé sur un :toc: left d'article).
      #   • Livre / page de garde + TOC : la TOC garde sa propre page
      #     réservée, avec la numérotation de front-matter.
      #   • Article SANS TOC : juste le doctitle en tête de la 1re page,
      #     le préambule suit dessous.
      toc_page_index = -1
      toc_inline_y_start = nil
      toc_requested = @theme.toc_enabled && node.attr?("toc") && !title_page_toc_active

      if inline_doctitle && toc_requested
        render_inline_doctitle(node)
        toc_page_index = @doc.pages.size - 1 # page courante (celle du titre)
        toc_inline_y_start = @current_y      # la TOC démarre sous le titre
        new_page                             # le corps démarre page suivante
      elsif toc_requested
        toc_page_index = @page_number # index 0-based de la page TOC
        new_page(numbering: front_numbering)
        # Nouvelle page pour le contenu afin d'éviter que le corps ne se
        # superpose à la TOC (qui sera rendue en post-traitement).
        new_page
      elsif inline_doctitle
        render_inline_doctitle(node)
      elsif title_rendered
        # Page de garde sans TOC : nouvelle page pour ne pas superposer
        # le corps au titre rendu sur la garde.
        new_page
      end

      # Contenu principal
      node.blocks.each do |block|
        convert(block)
      end

      # Calculer les numéros de page logiques d'abord — la TOC en a
      # besoin pour afficher les bons « 1, 2 » / « i, ii » dans ses
      # entrées (via `format_page_number`), pas l'index PDF brut.
      assign_displayed_numbers

      # Rendre la table des matières sur la page réservée. `y_start`
      # est non-nil pour un article (TOC inline sous le doctitle) et
      # nil pour un livre (TOC en haut de sa page dédiée).
      if toc_page_index >= 0
        render_toc(toc_page_index, y_start: toc_inline_y_start)
      end
      # …ou directement sur la page de garde quand le mode `x-title-page-toc`
      # est actif. Le titre « Sommaire » a déjà été dessiné par
      # `render_title_page_with_toc` ⇒ render_title: false.
      if title_page_toc_active
        render_toc(
          @title_page_toc_index,
          y_start: @title_page_toc_y_start,
          render_title: false,
        )
      end

      # Générer la page d'index si activée et si des entrées ont été collectées
      if @theme.index_enabled && !@index_entries.empty?
        render_index
      end
      # Générer les bookmarks PDF (outline) à partir des entrées TOC
      generate_pdf_outline

      # Rendre les en-têtes et pieds de page sur toutes les pages
      render_headers_footers
      # Écrire le PDF
      write_pdf
      # Bilan post-conversion : si des caractères ont été substitués
      # par '?', proposer à l'auteur les pistes pour récupérer une
      # bonne couverture (cache emojis Twemoji, polices supplémentaires).
      report_unrenderable_chars
      ""
    end

    def convert_embedded(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Document)
      node.blocks.each { |b| convert(b) }
      ""
    end

    # =========================================================================
    # Sections
    # =========================================================================

    def convert_section(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Section)

      level = node.level
      raw_title = node.title || ""
      # Strip HTML tags from the title (e.g., <code>Crystal</code> → Crystal)
      title = decode_html_entities(raw_title.gsub(/<[^>]+>/, ""))

      # Prepend section number when :sectnums: is enabled
      if node.numbered
        title = "#{node.sectnum} #{title}"
      end

      # Transformation typographique (uppercase / smallcaps / capitalize)
      # appliquée juste avant le wrap. Numéro de section inclus dans la
      # transformation (ex: "1. INTRODUCTION" en mode uppercase).
      title = TextTransformer.apply(title, @theme.heading_text_transform)

      @current_section_title = title

      # Forge un nom de destination PDF stable et unique pour cette
      # section. Préfère l'id AsciiDoc (`[[anchor]]` ou auto-généré
      # par le parseur) s'il existe, sinon retombe sur un compteur.
      # Les noms PDF n'ont pas besoin d'être lisibles ; ils servent
      # juste de clé pour l'`Annot.link_dest` de la TOC et pour
      # l'outline.
      @dest_counter += 1
      dest_name = node.id || "_sect_#{@dest_counter}"

      ensure_page

      # Saut de page automatique avant un titre de niveau ≤
      # `heading_chapter_break_before` (mode « livre »). On ne saute
      # pas si la page courante est encore vierge (sinon on enchaîne
      # deux pages blanches).
      cb = @theme.heading_chapter_break_before
      if cb > 0 && level <= cb && level > 0 && @current_y < @page_height - @margin - 1
        new_page
      end

      # Marge supérieure
      margin_top = @theme.heading_margin_top(level)
      @current_y -= margin_top if @current_y < (@page_height - @margin - margin_top)

      # Rendu du titre de section
      font_size = @theme.heading_font_size(level)
      heading_line_h = font_size * @theme.base_line_height

      # Découper le titre en lignes si il dépasse la largeur de contenu.
      # Sans ce wrapping, un titre long est rendu tronqué (le texte déborde
      # la page et le dernier mot est coupé).
      title_lines = wrap_text(title, @content_width, font_size, @fn_heading)
      heading_block_h = font_size + (title_lines.size - 1) * heading_line_h

      # Ensure heading is not orphaned: require room for the whole heading
      # plus at least 4 lines of body text below it.
      min_content_below = @theme.base_font_size * @theme.base_line_height * 4
      check_page_break(heading_block_h + @theme.heading_margin_bottom(level) + min_content_below)

      # Acquérir la page après check_page_break (qui peut créer une nouvelle page).
      # On enregistre l'entrée TOC ici (et non avant `check_page_break`) pour
      # que le numéro de page reflète bien la page sur laquelle le titre
      # va effectivement être dessiné — sinon une section qui déborde
      # apparaîtrait dans la TOC avec le numéro de la page précédente.
      page = @current_page.not_nil!

      # Crée une destination nommée pointant sur le haut du titre. La TOC
      # et l'outline (bookmarks) y feront référence pour amener le lecteur
      # exactement sur le titre — pas juste « quelque part » sur la page.
      # Petit padding au-dessus pour ne pas coller le scroll au sommet.
      top_y = @current_y + 4.0
      @doc.add_dest(dest_name, PDF::Destination.xyz(page.page_reference, top: top_y))

      @toc_entries << {title, level, @page_number, dest_name, top_y}

      set_font(page, @fn_heading, font_size)
      page.fill_color(@theme.heading_font_color)

      y = @current_y - font_size
      title_lines.each_with_index do |line, idx|
        page.text(line, at: {@margin, y})
        y -= heading_line_h unless idx == title_lines.size - 1
      end
      @current_y -= heading_block_h + @theme.heading_margin_bottom(level)

      # Ligne de séparation pour h1 et h2
      if level <= 2
        page.stroke_color("cccccc")
        page.line_width(0.5)
        page.line({@margin, @current_y}, {@margin + @content_width, @current_y})
        page.stroke
        @current_y -= 4.0
      end

      # Rendu des blocs enfants
      node.blocks.each { |b| convert(b) }
      ""
    end

    # =========================================================================
    # Paragraphes
    # =========================================================================

    def convert_paragraph(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)

      # Style spécial `[abstract]` : présentation distincte d'un
      # paragraphe d'introduction (résumé ISO, executive summary,
      # accroche d'article). Italique, légèrement en retrait, couleur
      # plus discrète. Le texte garde son markup inline et son wrap
      # comme un paragraphe normal.
      if node.responds_to?(:style) && node.style == "abstract"
        return render_abstract_paragraph(node)
      end

      ensure_page
      html = node.content || ""
      return "" if html.empty?

      font_size = @theme.base_font_size
      line_height = @theme.base_line_height
      line_h = font_size * line_height

      # Découper le HTML en lignes de texte brut pour le calcul de la hauteur
      plain = strip_inline_markup(html)
      lines = wrap_text(plain, @content_width, font_size)
      total_h = lines.size * line_h + @theme.prose_margin_bottom

      check_page_break(total_h)

      page = @current_page.not_nil!

      # Rendre chaque ligne avec le markup inline
      render_inline_lines(page, html, @margin, @content_width, font_size, line_h)
      @current_y -= @theme.prose_margin_bottom
      ""
    end

    # Rend un paragraphe en style abstract : indenté + italique + couleur
    # plus discrète. Tous les segments inline forcés en italique (sauf
    # ceux déjà italiques pour ne pas inverser).
    private def render_abstract_paragraph(node : Asciicrystal::Block) : String
      ensure_page
      raw = node.content
      html = raw.is_a?(Array) ? raw.join("\n") : raw.to_s
      return "" if html.empty?

      font_size = @theme.base_font_size + 1.0
      line_h = font_size * @theme.base_line_height
      side_indent = 24.0
      content_w = @content_width - 2 * side_indent

      segments = parse_inline(html)
      lines = wrap_segments(segments, content_w, font_size)
      lines = [[] of InlineSegment] if lines.empty?

      total_h = lines.size * line_h + @theme.prose_margin_bottom + 6.0
      check_page_break(total_h)

      page = @current_page.not_nil!
      @current_y -= 4.0

      y = @current_y - font_size
      lines.each do |line|
        # Italiciser sans écraser un segment déjà italique.
        styled = line.map do |seg|
          next seg if seg.italic
          InlineSegment.new(
            text: seg.text, bold: seg.bold, italic: true, mono: seg.mono,
            sup: seg.sup, sub: seg.sub, mark: seg.mark, kbd: seg.kbd,
            button: seg.button, menu: seg.menu,
            color: seg.color || "555555",
            link: seg.link,
            image_path: seg.image_path,
            image_width: seg.image_width,
            image_height: seg.image_height
          )
        end
        render_segment_line(page, styled, @margin + side_indent, y, font_size)
        y -= line_h
      end

      @current_y -= lines.size * line_h + @theme.prose_margin_bottom + 4.0
      ""
    end

    # =========================================================================
    # Blocs de code (listing, literal)
    # =========================================================================

    def convert_listing(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)

      # Extension : bloc `[x-form, id=..., action=...]` — formulaire
      # PDF interactif décrit en YAML (cf. doc/x-form-spec.adoc).
      # Asciicrystal laisse `node.style` à "listing" pour un bloc
      # délimité par `----`, mais conserve "x-form" dans
      # `attributes["style"]` (1er attribut positional).
      return render_x_form_block(node) if node.attributes["style"]? == "x-form"

      render_code_block(node)
    end

    def convert_literal(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)
      render_code_block(node)
    end

    private def render_code_block(node : Asciicrystal::Block) : String
      ensure_page

      source = node.source
      language = node.attr("language") || ""
      font_size = @theme.code_font_size
      line_h = font_size * 1.4
      padding = @theme.code_padding
      highlight = @theme.code_highlight_enabled && !language.empty?
      bottom_limit = @margin + 20.0

      # Soft-wrap des lignes trop longues (v2.3.24.88). Un bloc
      # `[source,…]` est rendu verbatim et ne se justifie pas ; mais
      # une ligne plus large que l'encadré (commande shell avec UUID
      # + flags, p. ex. `beryl scan aloli/<uuid> --provider=… --dns
      # --write --hostname=…`) débordait HORS PAGE et se faisait
      # rogner. On la replie désormais aux caractères charnières
      # (espace en priorité, puis `/ - = ,`, comme la coupure douce
      # des codespans inline) pour qu'elle reste intégralement
      # visible dans l'encadré. Aucun caractère n'est injecté : une
      # coupure sur espace consomme l'espace, une coupure sur
      # charnière garde la charnière sur la ligne du haut.
      avail_w = @content_width - 2 * padding
      # `node.lineno` pointe la ligne du délimiteur ouvrant (`----`) ;
      # le contenu du bloc commence à la ligne suivante. On passe donc
      # `lineno + 1` comme numéro de ligne source du PREMIER morceau de
      # code, pour que les avertissements de repli citent la bonne
      # ligne du fichier `.adoc`.
      content_first_lineno = node.lineno.try { |l| l + 1 }
      lines = soft_wrap_code_lines(source.split("\n"), font_size, avail_w, content_first_lineno)

      total_h = lines.size * line_h + (2 * padding) + @theme.code_margin_top + @theme.code_margin_bottom

      # If the whole block fits on the current page, use the simple path
      if @current_y - total_h >= bottom_limit
        render_code_block_simple(lines, language, font_size, line_h, padding, highlight)
      else
        # Split the code block across pages
        render_code_block_paginated(lines, language, font_size, line_h, padding, highlight, bottom_limit)
      end

      ""
    end

    # Replie les lignes de code dont la largeur dépasse `avail_w`
    # (largeur interne de l'encadré). Les lignes qui tiennent sont
    # conservées telles quelles. Pour les autres, on coupe aux
    # caractères charnières (espace en priorité, puis `/`, `-`, `=`,
    # `,`) au plus près de la limite, et on poursuit sur une ligne
    # de continuation (sans indentation ni caractère injecté, pour
    # préserver le copier-coller). Une ligne sans aucune charnière
    # (jeton unique très long, ex. base64) est coupée net en dernier
    # recours — toujours préférable au rognage hors page.
    # Replie les lignes de code trop longues. Renvoie des paires
    # `{texte, continuation?}` : `continuation? == true` marque un
    # fragment issu d'un repli (toutes les lignes d'un repli SAUF la
    # première). Le renderer y dessine un marqueur « ↳ » d'avertissement.
    #
    # Un `WARNING` est aussi émis sur stderr pour CHAQUE ligne source
    # repliée : le copier-coller du PDF embarquera un saut de ligne
    # (la commande ne sera pas exécutable telle quelle), donc l'auteur
    # est invité à raccourcir la ligne — ou à ajouter une continuation
    # propre à son langage (`\` en shell) — dans le source. Le message
    # cite le NUMÉRO DE LIGNE `.adoc` (via `content_first_lineno`, issu
    # de `node.lineno` + 1) plutôt que de recopier le code.
    private def soft_wrap_code_lines(lines : Array(String), font_size : Float64, avail_w : Float64, content_first_lineno : Int32? = nil) : Array(Tuple(String, Bool))
      font = get_font(@fn_mono)
      result = [] of Tuple(String, Bool)
      lines.each_with_index do |line, idx|
        if line.empty? || font.string_width(line, font_size) <= avail_w
          result << {line, false}
        else
          where = content_first_lineno ? "(ligne #{content_first_lineno + idx})" : "(numéro de ligne indisponible — activez sourcemap)"
          # Préfixe `<fichier>: ` (convention asciidoctor) pour savoir
          # de quel source provient le warning en mode multi-fichiers.
          file_prefix = @document_file.empty? ? "" : "#{@document_file}: "
          STDERR.puts "asciidoctor: WARNING: #{file_prefix}ligne de code repliée : trop longue pour l'encadré #{where}"
          rest = line
          first = true
          # Garde-fou anti-boucle : au plus une coupure par caractère.
          guard = line.size + 1
          while guard > 0 && font.string_width(rest, font_size) > avail_w
            guard -= 1
            head_end, tail_start = code_wrap_cut(rest, font, font_size, avail_w)
            break if head_end <= 0
            result << {rest[0...head_end], !first}
            first = false
            rest = rest[tail_start..]
          end
          result << {rest, !first} unless rest.empty?
        end
      end
      result
    end

    # Détermine où couper `rest` pour que le début tienne dans
    # `avail_w`. Renvoie `{head_end, tail_start}` (indices de
    # caractères) : le haut est `rest[0...head_end]`, le bas
    # `rest[tail_start..]`.
    private def code_wrap_cut(rest : String, font : PDF::Fonts::Base, font_size : Float64, avail_w : Float64) : Tuple(Int32, Int32)
      # Plus grand préfixe qui tient (recherche dichotomique).
      lo = 1
      hi = rest.size
      while lo < hi
        mid = (lo + hi + 1) // 2
        if font.string_width(rest[0...mid], font_size) <= avail_w
          lo = mid
        else
          hi = mid - 1
        end
      end
      maxfit = lo

      # Priorité 1 — ESPACE (frontière d'argument). On coupe à
      # l'espace le plus à droite qui tient : c'est de loin la
      # coupure la plus lisible pour une commande shell, car elle
      # garde chaque argument/flag entier (`--hostname=chouquette`
      # ne doit pas être scindé en `--` + `hostname=…`). On le
      # consomme (séparateur).
      i = maxfit
      while i >= 1
        if rest[i - 1] == ' '
          return {i - 1, i}
        end
        i -= 1
      end

      # Priorité 2 — CHARNIÈRE `/ - = ,`. Atteinte seulement si la
      # portion ne contient AUCUN espace (un jeton unique plus large
      # que l'encadré : UUID, chemin, hash). On coupe après la
      # charnière la plus à droite (elle reste sur la ligne du haut),
      # comme la coupure douce des codespans inline.
      i = maxfit
      while i >= 1
        c = rest[i - 1]
        if c == '/' || c == '-' || c == '=' || c == ','
          return {i, i}
        end
        i -= 1
      end

      # Priorité 3 — aucune charnière : coupe nette à la limite.
      {maxfit, maxfit}
    end

    # Render a code block that fits entirely on the current page.
    private def render_code_block_simple(lines : Array(Tuple(String, Bool)), language : String, font_size : Float64, line_h : Float64, padding : Float64, highlight : Bool) : Nil
      check_page_break(lines.size * line_h + (2 * padding) + @theme.code_margin_top + @theme.code_margin_bottom)
      page = @current_page.not_nil!
      @current_y -= @theme.code_margin_top

      block_h = lines.size * line_h + (2 * padding)
      draw_code_block_background(page, @current_y, block_h)
      draw_code_language_label(page, language, font_size, padding)

      y = @current_y - padding - font_size
      lines.each do |(text, cont)|
        render_code_line(page, text, y, font_size, padding, highlight, language, cont)
        y -= line_h
      end

      @current_y -= block_h + @theme.code_margin_bottom
    end

    # Render a code block that may span multiple pages.
    private def render_code_block_paginated(lines : Array(Tuple(String, Bool)), language : String, font_size : Float64, line_h : Float64, padding : Float64, highlight : Bool, bottom_limit : Float64) : Nil
      # Start a new page if the current page can't even fit a few lines
      min_first_chunk = padding + font_size + 3 * line_h + padding + @theme.code_margin_top
      check_page_break(min_first_chunk)

      page = @current_page.not_nil!
      @current_y -= @theme.code_margin_top

      line_idx = 0
      first_chunk = true

      while line_idx < lines.size
        page = @current_page.not_nil!

        # Calculate how many lines fit on the current page
        available_h = @current_y - bottom_limit - (2 * padding)
        max_lines = (available_h / line_h).to_i
        max_lines = 1 if max_lines < 1

        chunk_lines = lines[line_idx, [max_lines, lines.size - line_idx].min]
        chunk_block_h = chunk_lines.size * line_h + (2 * padding)

        # Draw background & border for this chunk
        draw_code_block_background(page, @current_y, chunk_block_h)

        # Language label only on the first chunk
        if first_chunk
          draw_code_language_label(page, language, font_size, padding)
          first_chunk = false
        end

        # Render lines
        y = @current_y - padding - font_size
        chunk_lines.each do |(text, cont)|
          render_code_line(page, text, y, font_size, padding, highlight, language, cont)
          y -= line_h
        end

        line_idx += chunk_lines.size
        @current_y -= chunk_block_h

        # If there are more lines, move to a new page
        if line_idx < lines.size
          new_page
        end
      end

      @current_y -= @theme.code_margin_bottom
    end

    # Draw code block background rectangle and border.
    private def draw_code_block_background(page : PDF::Page, top_y : Float64, block_h : Float64) : Nil
      page.fill_color(@theme.code_background_color)
      page.rectangle(@margin, top_y - block_h, @content_width, block_h)
      page.fill

      page.stroke_color(@theme.code_border_color)
      page.line_width(@theme.code_border_width)
      page.rectangle(@margin, top_y - block_h, @content_width, block_h)
      page.stroke
    end

    # Draw the language indicator label in the top-right corner.
    private def draw_code_language_label(page : PDF::Page, language : String, font_size : Float64, padding : Float64) : Nil
      return if language.empty?
      set_font(page, @fn_body, font_size * 0.75)
      page.fill_color("888888")
      lang_x = @margin + @content_width - text_width(language, @fn_body, font_size * 0.75) - padding
      page.text(language, at: {lang_x, @current_y - font_size * 0.75})
    end

    # Render a single line of code text. `continuation` signale une
    # ligne issue d'un repli (cf. `soft_wrap_code_lines`) : on dessine
    # alors un marqueur « ↳ » d'avertissement dans la gouttière gauche.
    private def render_code_line(page : PDF::Page, line : String, y : Float64, font_size : Float64, padding : Float64, highlight : Bool, language : String, continuation : Bool = false) : Nil
      draw_code_continuation_marker(page, y, font_size) if continuation

      if highlight
        tokens = SyntaxHighlighter.tokenize(line, language)
        x = @margin + padding
        tokens.each do |token|
          set_font(page, @fn_mono, font_size)
          page.fill_color(token.color)
          page.text(token.text, at: {x, y})
          x += text_width(token.text, @fn_mono, font_size)
        end
      else
        set_font(page, @fn_mono, font_size)
        page.fill_color(@theme.code_font_color)
        page.text(line, at: {@margin + padding, y})
      end
    end

    # Dessine le marqueur de continuation « ↳ » d'une ligne de code
    # repliée, dans la gouttière gauche de l'encadré (entre le bord
    # `@margin` et le début du texte `@margin + padding`). Tracé
    # VECTORIEL (deux segments + tête de flèche) — pas un glyphe :
    #   - aucune dépendance à la couverture de la police mono ;
    #   - n'appartient PAS au flux de texte, donc absent du
    #     copier-coller (le lecteur n'embarque que le code, pas le
    #     marqueur).
    # Couleur d'avertissement (ambre) configurable via le thème.
    private def draw_code_continuation_marker(page : PDF::Page, y : Float64, font_size : Float64) : Nil
      gx = @margin + 2.5
      top = y + font_size * 0.48
      corner = y + 1.0
      arm = 3.5
      page.stroke_color(@theme.code_wrap_marker_color)
      page.line_width(0.6)
      # Crochet « ↳ » : descend puis part à droite.
      page.move_to(gx, top)
      page.line_to(gx, corner)
      page.line_to(gx + arm, corner)
      page.stroke
      # Petite tête de flèche pointant à droite.
      page.move_to(gx + arm, corner)
      page.line_to(gx + arm - 2.0, corner + 1.6)
      page.move_to(gx + arm, corner)
      page.line_to(gx + arm - 2.0, corner - 1.6)
      page.stroke
    end

    # =========================================================================
    # Admonitions
    # =========================================================================

    def convert_admonition(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)

      ensure_page
      name = node.attr("name") || "note"
      # `node.content` retourne le HTML inline déjà substitué par
      # asciicrystal (`<strong>`, `<em>`, `<code>`, …) qu'on
      # parse ici en segments stylisés via `InlineRenderer.parse`.
      # L'ancien comportement (`strip_inline_markup`) effaçait *gras*,
      # _italique_, `mono` — bug confirmé sur les fiches de quiz.
      raw = node.content
      html = raw.is_a?(Array) ? raw.join("\n") : raw.to_s

      border_color = case name.downcase
                     when "tip"       then @theme.admonition_tip_color
                     when "warning"   then @theme.admonition_warning_color
                     when "caution"   then @theme.admonition_caution_color
                     when "important" then @theme.admonition_important_color
                     else                  @theme.admonition_note_color
                     end

      font_size = @theme.base_font_size
      line_h = font_size * @theme.base_line_height
      padding = @theme.admonition_padding

      # Espace réservé au label (NOTE, TIP, IMPORTANT, WARNING, CAUTION) :
      # au minimum 60pt pour aligner les labels entre admonitions, plus si
      # le texte du label mesuré est plus long (évite qu'il mange le début
      # du texte de l'admonition).
      # Lookup en cascade pour permettre la traduction :
      #   1. attribut document `:<name>-caption: TRADUCTION` (priorité)
      #   2. propriété de thème `admonition_<name>_label` (fallback)
      #   3. `name.upcase` (fallback ultime, comportement historique)
      label_text = admonition_label(node, name)
      label_size = font_size - 1
      label_offset = @theme.admonition_border_width + 4.0
      label_gap = 8.0
      label_space = [60.0, label_offset + text_width(label_text, @fn_body_bold, label_size) + label_gap].max
      # Mode encadré : option A (rôle `boxed` sur le bloc) OU option B
      # (`theme.admonition_boxed: true`). L'ombre + le cadre + la
      # bande gauche + le label sont tous *à l'intérieur* du
      # rectangle entourant. `total_h` inclut alors l'offset d'ombre
      # pour réserver l'espace.
      boxed = node.has_role?("boxed") || @theme.admonition_boxed

      # Largeur de la zone de texte. Le bord DROIT du texte :
      #   - admonition encadrée : insé de `padding` pour ne pas
      #     toucher la bordure droite du cadre (à @margin +
      #     @content_width) ;
      #   - admonition simple (bande gauche seule, cas par défaut) :
      #     atteint la marge droite de page comme un paragraphe
      #     ordinaire — pas de bordure à droite, donc pas de raison
      #     d'insérer un retrait (la justification rejoignait sinon
      #     un bord « fantôme » ~8 pt avant la marge, défaut visuel
      #     signalé sur le README beryl).
      right_inset = boxed ? padding : 0.0
      content_w = @content_width - label_space - right_inset

      segments = parse_inline(html)
      lines = wrap_segments(segments, content_w, font_size)
      lines = [[] of InlineSegment] if lines.empty?
      block_h = [lines.size * line_h + (2 * padding), font_size * 2 + (2 * padding)].max

      shadow_offset = boxed && @theme.admonition_box_shadow_enabled ? @theme.admonition_box_shadow_offset : 0.0
      total_h = block_h + @theme.admonition_margin_top + @theme.admonition_margin_bottom + shadow_offset

      check_page_break(total_h)

      page = @current_page.not_nil!
      @current_y -= @theme.admonition_margin_top

      # 1) Cadre (si boxed) : ombre puis fond puis bordure, dans cet
      #    ordre pour que la bordure et le contenu se posent dessus.
      if boxed
        render_box_chrome(
          page, @margin, @current_y - block_h, @content_width, block_h,
          background: @theme.admonition_box_background_color,
          border_color: @theme.admonition_box_border_color,
          border_width: @theme.admonition_box_border_width,
          shadow_enabled: @theme.admonition_box_shadow_enabled,
          shadow_color: @theme.admonition_box_shadow_color,
          shadow_offset: @theme.admonition_box_shadow_offset,
        )
      end

      # 2) Bande de couleur à gauche (à l'intérieur du cadre quand boxed).
      bar_x = boxed ? @margin + 1.0 : @margin
      page.fill_color(border_color)
      page.rectangle(bar_x, @current_y - block_h + (boxed ? 1.0 : 0.0),
        @theme.admonition_border_width, block_h - (boxed ? 2.0 : 0.0))
      page.fill

      # 3) Label
      set_font(page, @fn_body_bold, label_size)
      page.fill_color(border_color)
      page.text(label_text, at: {@margin + label_offset, @current_y - padding - font_size})

      # 4) Texte de l'admonition (segments inline avec leur typographie)
      # — justify pour toutes les lignes sauf la dernière, comme un
      # paragraphe ordinaire.
      y = @current_y - padding - font_size
      last_idx = lines.size - 1
      lines.each_with_index do |line, idx|
        line_align = idx == last_idx ? "left" : @theme.base_text_align
        render_segment_line(page, line, @margin + label_space, y, font_size,
          target_w: content_w, align: line_align)
        y -= line_h
      end

      @current_y -= block_h + @theme.admonition_margin_bottom + shadow_offset
      ""
    end

    # Dessine le chrome d'un bloc encadré : ombre portée (rectangle
    # gris décalé en bas-droite), fond opaque, bordure. Appelé avant
    # de tracer le contenu interne (qui se posera par-dessus).
    private def render_box_chrome(
      page : PDF::Page,
      x : Float64, y_bottom : Float64, w : Float64, h : Float64,
      *,
      background : String,
      border_color : String,
      border_width : Float64,
      shadow_enabled : Bool,
      shadow_color : String,
      shadow_offset : Float64,
    ) : Nil
      # Ombre : rectangle plein, couleur gris pâle, décalé de
      # `shadow_offset` vers la droite et le bas. Pas de transparence
      # (le shard pdf n'expose pas /CA dans une API publique pour le
      # moment) — la couleur grise pâle suffit visuellement.
      if shadow_enabled && shadow_offset > 0
        page.fill_color(shadow_color)
        page.rectangle(x + shadow_offset, y_bottom - shadow_offset, w, h)
        page.fill
      end

      # Fond
      unless background.empty?
        page.fill_color(background)
        page.rectangle(x, y_bottom, w, h)
        page.fill
      end

      # Bordure
      unless border_color.empty?
        page.stroke_color(border_color)
        page.line_width(border_width)
        page.rectangle(x, y_bottom, w, h)
        page.stroke
      end
    end

    # Défauts injectés par asciicrystal (title-case, pour rendu
    # HTML). On les ignore lors de la lookup pour que le thème
    # (`admonition_<name>_label = "WARNING"`) reste autoritaire tant que
    # l'utilisateur n'a pas vraiment défini un override.
    DEFAULT_ADMONITION_CAPTIONS = {
      "note"      => "Note",
      "tip"       => "Tip",
      "warning"   => "Warning",
      "caution"   => "Caution",
      "important" => "Important",
    }

    # Résout le label d'une admonition selon la cascade :
    # `<name>-caption` (attr du node ou du document, **si différent du
    # défaut injecté par asciicrystal**) →
    # `theme.admonition_<name>_label` → `name.upcase`.
    # Permet la traduction sans patcher le code via, p. ex.,
    # `:caution-caption: ATTENTION` au niveau document.
    private def admonition_label(node : Asciicrystal::Block, name : String) : String
      key = name.downcase
      attr_key = "#{key}-caption"
      caption = node.attr(attr_key) || node.document.attr(attr_key)
      caption_str = caption.to_s
      # Override explicite : valeur non vide ET différente du défaut
      # injecté par le parser asciicrystal.
      if !caption_str.empty? && DEFAULT_ADMONITION_CAPTIONS[key]? != caption_str
        return caption_str
      end

      case key
      when "note"      then @theme.admonition_note_label
      when "tip"       then @theme.admonition_tip_label
      when "warning"   then @theme.admonition_warning_label
      when "caution"   then @theme.admonition_caution_label
      when "important" then @theme.admonition_important_label
      else                  name.upcase
      end
    end

    # =========================================================================
    # Blocs de score (extension `x-score-*`) — non standard
    # =========================================================================

    # Cherche un rôle `x-score-<niveau>` sur le node et retourne le
    # niveau (string) si trouvé. Niveaux reconnus :
    # `excellent`, `tres-bien`, `bien`, `insuffisant`, `a-revoir`.
    private X_SCORE_LEVELS = %w(excellent tres-bien bien insuffisant a-revoir)

    private def detect_x_score_level(node : Asciicrystal::AbstractBlock) : String?
      X_SCORE_LEVELS.each do |level|
        return level if node.has_role?("x-score-#{level}")
      end
      nil
    end

    # Rend un bloc de score (extension non standard, parité visuelle
    # avec les admonitions). Bande colorée à gauche + label en gras +
    # contenu indenté. La couleur et le libellé sont configurables
    # par le thème (`x_score_<niveau>_color/label`).
    private def render_x_score_block(node : Asciicrystal::Block, level : String) : String
      ensure_page

      label_text, color = x_score_label_and_color(level)

      # Concaténer le HTML inline des sous-blocs et le parser en
      # segments stylisés (cf. convert_admonition pour le rationale).
      html_parts = [] of String
      node.blocks.each do |b|
        raw = b.responds_to?(:content) ? b.content : nil
        chunk = raw.is_a?(Array) ? raw.join("\n") : (raw || "")
        html_parts << chunk.to_s unless chunk.to_s.empty?
      end
      html = html_parts.join("\n\n")

      font_size = @theme.base_font_size
      line_h = font_size * @theme.base_line_height
      padding = @theme.admonition_padding
      label_size = font_size - 1
      label_offset = @theme.admonition_border_width + 4.0
      label_gap = 8.0
      label_space = [60.0, label_offset + text_width(label_text, @fn_body_bold, label_size) + label_gap].max
      content_w = @content_width - label_space - padding

      segments = parse_inline(html)
      lines = wrap_segments(segments, content_w, font_size)
      lines = [[] of InlineSegment] if lines.empty?
      block_h = [lines.size * line_h + (2 * padding), font_size * 2 + (2 * padding)].max

      # Mode encadré : option A (rôle `boxed` cumulé avec `x-score-*`)
      # OU option B (`theme.x_score_boxed: true`).
      boxed = node.has_role?("boxed") || @theme.x_score_boxed
      shadow_offset = boxed && @theme.x_score_box_shadow_enabled ? @theme.x_score_box_shadow_offset : 0.0
      total_h = block_h + @theme.admonition_margin_top + @theme.admonition_margin_bottom + shadow_offset

      check_page_break(total_h)

      page = @current_page.not_nil!
      @current_y -= @theme.admonition_margin_top

      # 1) Cadre (si boxed)
      if boxed
        render_box_chrome(
          page, @margin, @current_y - block_h, @content_width, block_h,
          background: @theme.x_score_box_background_color,
          border_color: @theme.x_score_box_border_color,
          border_width: @theme.x_score_box_border_width,
          shadow_enabled: @theme.x_score_box_shadow_enabled,
          shadow_color: @theme.x_score_box_shadow_color,
          shadow_offset: @theme.x_score_box_shadow_offset,
        )
      end

      # 2) Bande de couleur à gauche (à l'intérieur du cadre quand boxed)
      bar_x = boxed ? @margin + 1.0 : @margin
      page.fill_color(color)
      page.rectangle(bar_x, @current_y - block_h + (boxed ? 1.0 : 0.0),
        @theme.admonition_border_width, block_h - (boxed ? 2.0 : 0.0))
      page.fill

      # 3) Label
      set_font(page, @fn_body_bold, label_size)
      page.fill_color(color)
      page.text(label_text, at: {@margin + label_offset, @current_y - padding - font_size})

      # 4) Texte (segments inline avec leur typographie)
      y = @current_y - padding - font_size
      lines.each do |line|
        render_segment_line(page, line, @margin + label_space, y, font_size)
        y -= line_h
      end

      @current_y -= block_h + @theme.admonition_margin_bottom + shadow_offset
      ""
    end

    private def x_score_label_and_color(level : String) : {String, String}
      case level
      when "excellent"   then {@theme.x_score_excellent_label, @theme.x_score_excellent_color}
      when "tres-bien"   then {@theme.x_score_tres_bien_label, @theme.x_score_tres_bien_color}
      when "bien"        then {@theme.x_score_bien_label, @theme.x_score_bien_color}
      when "insuffisant" then {@theme.x_score_insuffisant_label, @theme.x_score_insuffisant_color}
      when "a-revoir"    then {@theme.x_score_a_revoir_label, @theme.x_score_a_revoir_color}
      else                    {level.upcase, @theme.admonition_note_color}
      end
    end

    # =========================================================================
    # Extension `[x-form]` — formulaires PDF interactifs (AcroForm)
    # Cf. doc/x-form-spec.adoc et src/asciicrystal_pdf/form_builder.cr
    # =========================================================================

    private def collect_x_form_block_attrs(node : Asciicrystal::Block) : Hash(String, String)
      attrs = {} of String => String
      {"id", "action", "method", "read-only"}.each do |key|
        v = node.attr(key)
        attrs[key] = v.to_s if v
      end
      attrs
    end

    # Point d'entrée du rendu : parse le YAML, dessine titre +
    # sections/champs en flow auto, attache les widgets AcroForm
    # via le shard `pdf`.
    private def render_x_form_block(node : Asciicrystal::Block) : String
      ensure_page
      page = @current_page.not_nil!

      block_attrs = collect_x_form_block_attrs(node)
      begin
        form = AsciicrystalPDF::FormBuilder.parse(node.source, block_attrs)
      rescue ex : AsciicrystalPDF::FormError
        STDERR.puts ex.message
        render_x_form_error_text(page, ex.message.to_s)
        return ""
      end

      acroform = @doc.acroform

      if title = form.title
        render_x_form_inline_label(page, title, font_size: AsciicrystalPDF::FormRenderer::FORM_TITLE_FONT_SIZE, gap_below: 6.0)
      end
      if desc = form.description
        render_x_form_inline_label(page, desc, font_size: AsciicrystalPDF::FormRenderer::FORM_DESC_FONT_SIZE, gap_below: 8.0)
      end

      if form.sectioned?
        form.sections.each_with_index do |sec, i|
          render_x_form_section(sec, page, acroform, first: i == 0)
        end
      else
        render_x_form_field_group(form.fields, form.columns, page, acroform)
      end

      ""
    end

    private def render_x_form_error_text(page : PDF::Page, message : String) : Nil
      @current_y -= 14.0
      page.font("Helvetica", size: 9)
      page.text(message, at: {@margin, @current_y})
      @current_y -= 10.0
    end

    private def render_x_form_inline_label(page : PDF::Page, text : String, *, font_size : Float64, gap_below : Float64) : Nil
      @current_y -= font_size + 2.0
      page.font("Helvetica", size: font_size)
      page.text(text, at: {@margin, @current_y})
      @current_y -= gap_below
    end

    private def render_x_form_section(sec : AsciicrystalPDF::Section, page : PDF::Page, acroform : PDF::AcroForm::Form, *, first : Bool) : Nil
      @current_y -= 8.0 unless first
      if title = sec.title
        render_x_form_inline_label(page, title,
          font_size: AsciicrystalPDF::FormRenderer::SECTION_TITLE_FONT_SIZE,
          gap_below: 4.0)
      end
      if desc = sec.description
        render_x_form_inline_label(page, desc,
          font_size: AsciicrystalPDF::FormRenderer::SECTION_DESC_FONT_SIZE,
          gap_below: 6.0)
      end
      render_x_form_field_group(sec.fields, sec.columns, page, acroform)
    end

    # Flow auto multi-colonnes. Avance cursor_y rangée par rangée ;
    # à l'intérieur d'une rangée, les colonnes partagent le même y
    # de départ. Quand un champ avec `cols: N` ne tient pas, on
    # ferme la rangée courante avant de l'émettre.
    private def render_x_form_field_group(fields : Array(AsciicrystalPDF::FormField), columns : Int32, page : PDF::Page, acroform : PDF::AcroForm::Form) : Nil
      gutter = AsciicrystalPDF::FormRenderer::DEFAULT_GUTTER
      col_w = AsciicrystalPDF::FormRenderer.column_width(columns, @content_width, gutter)

      current_col = 0
      row_top_y = @current_y
      row_max_h = 0.0

      fields.each do |field|
        span = AsciicrystalPDF::FormRenderer.clamped_span(field, columns)

        if current_col + span > columns && current_col > 0
          @current_y = row_top_y - row_max_h
          row_top_y = @current_y
          row_max_h = 0.0
          current_col = 0
        end

        x = @margin + current_col * (col_w + gutter)
        width = col_w * span + gutter * (span - 1)

        @current_y = row_top_y
        consumed = render_x_form_one_field(field, x, width, page, acroform)
        row_max_h = consumed if consumed > row_max_h

        current_col += span
        if current_col >= columns
          @current_y = row_top_y - row_max_h
          row_top_y = @current_y
          row_max_h = 0.0
          current_col = 0
        end
      end

      if current_col > 0
        @current_y = row_top_y - row_max_h
      end
    end

    # Rend un champ unique dans la zone `(x..x+width)` à partir du
    # `@current_y` courant. Retourne la hauteur totale consommée
    # par le bloc (label + widget + help + spacing) — utilisée pour
    # synchroniser la hauteur de la rangée multi-colonnes.
    private def render_x_form_one_field(field : AsciicrystalPDF::FormField, x : Float64, width : Float64, page : PDF::Page, acroform : PDF::AcroForm::Form) : Float64
      start_y = @current_y

      if label = field.label
        label_text = field.required ? "#{label} *" : label
        @current_y -= AsciicrystalPDF::FormRenderer::LABEL_FONT_SIZE + 1.0
        page.font("Helvetica", size: AsciicrystalPDF::FormRenderer::LABEL_FONT_SIZE)
        page.text(label_text, at: {x, @current_y})
        @current_y -= AsciicrystalPDF::FormRenderer::LABEL_GAP
      end

      widget_h = AsciicrystalPDF::FormRenderer.widget_height(field)
      widget_y = @current_y - widget_h

      begin
        place_x_form_widget(field, x, widget_y, width, widget_h, page, acroform)
      rescue ex : ArgumentError
        STDERR.puts "[x-form] champ '#{field.id}' : #{ex.message}"
        page.font("Helvetica", size: 8)
        page.text("[#{field.id}: #{ex.message}]", at: {x, widget_y + 4.0})
      end

      @current_y -= widget_h + 4.0

      if help = field.help
        @current_y -= AsciicrystalPDF::FormRenderer::HELP_FONT_SIZE
        page.font("Helvetica", size: AsciicrystalPDF::FormRenderer::HELP_FONT_SIZE)
        page.text(help, at: {x, @current_y})
        @current_y -= AsciicrystalPDF::FormRenderer::HELP_GAP
      end

      @current_y -= 6.0

      start_y - @current_y
    end

    # Place le widget AcroForm correspondant au type. Lève
    # ArgumentError si options/valeurs invalides (capturé en amont).
    private def place_x_form_widget(field : AsciicrystalPDF::FormField, x : Float64, y : Float64, width : Float64, height : Float64, page : PDF::Page, acroform : PDF::AcroForm::Form) : Nil
      case field.type
      when "text", "email", "url", "tel"
        acroform.text_field(field.id, page: page, x: x, y: y,
          width: width, height: height,
          value: field.value_string,
          required: field.required, read_only: field.read_only)
      when "password"
        acroform.text_field(field.id, page: page, x: x, y: y,
          width: width, height: height,
          value: field.value_string, password: true,
          required: field.required, read_only: field.read_only)
      when "number", "date"
        # min/max/step ne sont pas natifs AcroForm ; un /JS /AA action
        # sera ajouté plus tard pour valider. Pour l'instant : champ
        # texte simple.
        acroform.text_field(field.id, page: page, x: x, y: y,
          width: width, height: height,
          value: field.value_string,
          required: field.required, read_only: field.read_only)
      when "textarea"
        acroform.text_field(field.id, page: page, x: x, y: y,
          width: width, height: height,
          value: field.value_string, multiline: true,
          required: field.required, read_only: field.read_only)
      when "checkbox"
        checked = field.value.try(&.as_bool?) || false
        size = Math.min(width, AsciicrystalPDF::FormRenderer::DEFAULT_FIELD_H)
        acroform.checkbox(field.id, page: page, x: x, y: y,
          size: size, checked: checked,
          required: field.required, read_only: field.read_only)
      when "radio"
        options = field.options
        raise ArgumentError.new("options requis pour radio") if options.nil?
        # `radio_group` prend l'origine au coin haut-gauche du
        # premier bouton : on passe (x, y + height) car notre y
        # est le coin bas-gauche du bloc complet.
        acroform.radio_group(field.id, page: page, options: options,
          x: x, y: y + height,
          spacing: AsciicrystalPDF::FormRenderer::RADIO_OPTION_SPACING,
          selected: field.value_string,
          required: field.required, read_only: field.read_only)
      when "select"
        options = field.options
        raise ArgumentError.new("options requis pour select") if options.nil?
        acroform.dropdown(field.id, page: page, options: options,
          x: x, y: y, width: width, height: height,
          value: field.value_string,
          required: field.required, read_only: field.read_only)
      when "select-multi"
        options = field.options
        raise ArgumentError.new("options requis pour select-multi") if options.nil?
        acroform.listbox(field.id, page: page, options: options,
          x: x, y: y, width: width, height: height,
          value: field.value_array,
          required: field.required, read_only: field.read_only)
      when "signature"
        # Widget /Sig (pdf 0.5.9+). Le slot est vide ; le contenu
        # PAdES sera rempli par pdf-signature (non livré). Le widget
        # est cliquable dans les visualiseurs PDF.
        acroform.signature_field(field.id, page: page,
          x: x, y: y, width: width, height: height,
          required: field.required, read_only: field.read_only)
      end
    end

    # =========================================================================
    # Listes
    # =========================================================================

    def convert_ulist(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::List)
      render_list(node, ordered: false)
    end

    def convert_olist(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::List)
      render_list(node, ordered: true)
    end

    def convert_dlist(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::List)
      style = node.responds_to?(:style) ? node.style : nil
      case style
      when "qanda"      then render_dlist_qanda(node)
      when "horizontal" then render_dlist_horizontal(node)
      else                   render_dlist_default(node)
      end
      ""
    end

    # Rendu par défaut : terme en gras sur sa ligne, définition (sous-blocs)
    # juste en dessous. C'était l'unique mode avant l'ajout de qanda /
    # horizontal — comportement préservé.
    private def render_dlist_default(node : Asciicrystal::List) : Nil
      node.items.each do |item|
        next unless item.is_a?(Asciicrystal::ListItem)
        ensure_page
        page = @current_page.not_nil!
        term = strip_inline_markup(item.text || "")
        set_font(page, @fn_body_bold, @theme.base_font_size)
        page.fill_color(@theme.base_font_color)
        draw_text_run(page, term, @margin, @current_y - @theme.base_font_size, @fn_body_bold, @theme.base_font_size)
        @current_y -= @theme.base_font_size * @theme.base_line_height
        item.blocks.each { |b| convert(b) } if item.blocks?
      end
    end

    # Style FAQ : « Q1. » devant chaque question (numérotée), « → »
    # devant chaque réponse. Question en gras, réponse en flux normal.
    private def render_dlist_qanda(node : Asciicrystal::List) : Nil
      node.items.each_with_index do |item, idx|
        next unless item.is_a?(Asciicrystal::ListItem)
        ensure_page
        page = @current_page.not_nil!
        font_size = @theme.base_font_size
        line_h = font_size * @theme.base_line_height

        # Question
        prefix = "Q#{idx + 1}. "
        term = strip_inline_markup(item.text || "")
        prefix_w = text_width(prefix, @fn_body_bold, font_size)
        question_lines = wrap_text(term, @content_width - prefix_w, font_size, @fn_body_bold)
        check_page_break(question_lines.size * line_h + 4.0)
        page = @current_page.not_nil!
        set_font(page, @fn_body_bold, font_size)
        page.fill_color(@theme.base_font_color)
        question_lines.each_with_index do |line, li|
          x = li == 0 ? @margin : @margin + prefix_w
          y = @current_y - font_size - (li * line_h)
          if li == 0
            draw_text_run(page, prefix + line, x, y, @fn_body_bold, font_size)
          else
            draw_text_run(page, line, x, y, @fn_body_bold, font_size)
          end
        end
        @current_y -= question_lines.size * line_h + 2.0

        # Réponse : indenter de la largeur du préfixe pour aligner
        # visuellement sur le début du texte de la question.
        if item.blocks?
          saved_margin = @margin
          saved_content_w = @content_width
          @margin += prefix_w
          @content_width -= prefix_w
          item.blocks.each { |b| convert(b) }
          @margin = saved_margin
          @content_width = saved_content_w
        end
        @current_y -= 4.0
      end
    end

    # Style horizontal : terme à gauche dans une colonne fixe (~25 %),
    # définition à droite dans le reste. Pour les items où la
    # définition fait plusieurs lignes, le terme reste aligné en haut
    # de la première ligne.
    private def render_dlist_horizontal(node : Asciicrystal::List) : Nil
      term_col_w = @content_width * 0.25
      def_col_x = @margin + term_col_w + 8.0
      def_col_w = @content_width - term_col_w - 8.0
      font_size = @theme.base_font_size
      line_h = font_size * @theme.base_line_height

      node.items.each do |item|
        next unless item.is_a?(Asciicrystal::ListItem)
        ensure_page

        term = strip_inline_markup(item.text || "")
        term_lines = wrap_text(term, term_col_w - 4.0, font_size, @fn_body_bold)

        # Concaténer le contenu des sous-blocs (paragraphes) pour le
        # rendu inline horizontal — pas de support des listings ou
        # tables dans la colonne définition (ça nécessiterait une
        # « zone » dédiée, hors scope de cette itération).
        def_html = item.blocks? ? item.blocks.map do |b|
          if b.responds_to?(:content)
            content = b.content
            content.is_a?(Array) ? content.join(" ") : (content || "").to_s
          else
            ""
          end
        end.reject(&.empty?).join("\n") : ""

        def_segments = parse_inline(def_html)
        def_lines = wrap_segments(def_segments, def_col_w, font_size)
        def_lines = [[] of InlineSegment] if def_lines.empty?

        n_lines = [term_lines.size, def_lines.size].max
        check_page_break(n_lines * line_h + 4.0)
        page = @current_page.not_nil!

        # Terme à gauche
        set_font(page, @fn_body_bold, font_size)
        page.fill_color(@theme.base_font_color)
        term_lines.each_with_index do |line, li|
          y = @current_y - font_size - (li * line_h)
          draw_text_run(page, line, @margin, y, @fn_body_bold, font_size)
        end

        # Définition à droite
        y = @current_y - font_size
        def_lines.each do |line|
          render_segment_line(page, line, def_col_x, y, font_size)
          y -= line_h
        end

        @current_y -= n_lines * line_h + 4.0
      end
    end

    private def render_list(node : Asciicrystal::List, ordered : Bool, indent : Float64 = 0.0) : String
      node.items.each_with_index do |item, idx|
        next unless item.is_a?(Asciicrystal::ListItem)
        ensure_page

        # Le markup inline de l'item (gras, italique, code inline,
        # liens, etc.) doit être préservé : on parse les segments via
        # `InlineRenderer.parse` et on les rend via `render_segment_line`
        # — même pipeline que pour les paragraphes ordinaires. Avant,
        # `strip_inline_markup` + `draw_text_run` réduisaient l'item à
        # du texte plat, ce qui faisait disparaître la police mono, le
        # fond grisé du codespan, l'italique, le gras, etc.
        html = item.text || ""
        font_size = @theme.base_font_size
        line_h = font_size * @theme.base_line_height
        content_w = @content_width - @theme.list_indent - indent

        segments = parse_inline(html)
        lines = wrap_segments(segments, content_w, font_size)
        lines = [[] of InlineSegment] if lines.empty?
        total_h = lines.size * line_h + @theme.list_item_spacing
        check_page_break(total_h)

        page = @current_page.not_nil!
        marker = ordered ? "#{idx + 1}." : "•"
        x_marker = @margin + indent
        x_text = x_marker + @theme.list_indent

        set_font(page, @fn_body, font_size)
        page.fill_color(@theme.list_marker_color)
        page.text(marker, at: {x_marker, @current_y - font_size})

        # Rendu des lignes avec markup complet + justify de paragraphe.
        last_idx = lines.size - 1
        lines.each_with_index do |line, i|
          line_align = i == last_idx ? "left" : @theme.base_text_align
          render_segment_line(page, line, x_text, @current_y - font_size, font_size,
            target_w: content_w, align: line_align)
          @current_y -= line_h
        end
        @current_y -= @theme.list_item_spacing

        # Sous-blocs attachés à l'item (via `+`) : sous-listes,
        # blocs de code (`[source,...] + ----` ou ```), paragraphes,
        # tableaux, admonitions, etc. Le dispatcher général gère
        # chaque type. Sans ce dispatch, tous les blocs *non*-liste
        # à l'intérieur d'un item étaient silencieusement ignorés
        # — typiquement un bloc source affiché à plat dans le
        # source AsciiDoc disparaissait du PDF final.
        item.blocks.each do |sub_block|
          if sub_block.is_a?(Asciicrystal::List)
            render_list(sub_block, ordered: sub_block.context == :olist, indent: indent + @theme.list_indent)
          elsif sub_block.is_a?(Asciicrystal::AbstractNode)
            dispatch(sub_block, sub_block.context.to_s)
          end
        end
      end
      ""
    end

    # =========================================================================
    # Tableaux
    # =========================================================================

    def convert_table(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Table)

      ensure_page
      @current_y -= @theme.table_margin_top

      col_count = node.columns.size
      return "" if col_count == 0

      # Calculer les largeurs de colonnes proportionnelles (via colpcwidth)
      col_widths = node.columns.map do |col|
        pcw = col.attr("colpcwidth")
        pcw ? (pcw.to_f / 100.0 * @content_width) : (@content_width / col_count)
      end

      font_size = @theme.base_font_size
      padding = @theme.table_cell_padding
      line_h = font_size * @theme.base_line_height

      page = @current_page.not_nil!

      # Titre du tableau (caption)
      if (caption = node.title) && !caption.empty?
        set_font(page, @fn_body, font_size - 1)
        page.fill_color("888888")
        draw_text_run(page, caption, @margin, @current_y - (font_size - 1), @fn_body, font_size - 1)
        @current_y -= (font_size - 1) * 1.4
      end

      # En-têtes. On se fie à `rows.head` (peuplé par le parser
      # quand une ligne d'en-tête est détectée) PLUTÔT qu'à
      # `has_header_option` : ce dernier ne reflète pas toujours
      # l'option `options="header"` (cas vécu : `rows.head` contenait
      # « Plateforme | Url » mais `has_header_option` valait `false`,
      # d'où un en-tête parsé mais jamais rendu). Si une ligne
      # d'en-tête existe, on la rend.
      head_rows = node.rows.head
      render_head = -> do
        head_rows.each do |row|
          render_table_row(row, col_widths, col_count, font_size, line_h, padding,
            font_name: @fn_body_bold,
            font_color: @theme.table_header_font_color,
            bg_color: @theme.table_header_background_color)
        end
      end
      render_head.call

      # Tableau multi-pages : on RÉPÈTE l'en-tête en haut de chaque nouvelle
      # page (via `check_page_break`), pour que les intitulés de colonnes
      # restent lisibles quand le corps déborde. Désactivé en fin de tableau.
      @repeat_table_header = render_head unless head_rows.empty?
      begin
        # Corps du tableau avec alternance de couleurs
        row_idx = 0
        node.rows.body.each do |row|
          bg_color = (row_idx % 2 == 1) ? @theme.table_row_alt_background_color : nil
          render_table_row(row, col_widths, col_count, font_size, line_h, padding,
            font_name: @fn_body,
            font_color: @theme.base_font_color,
            bg_color: bg_color)
          row_idx += 1
        end

        # Pied de tableau
        unless node.rows.foot.empty?
          node.rows.foot.each do |row|
            render_table_row(row, col_widths, col_count, font_size, line_h, padding,
              font_name: @fn_body_bold,
              font_color: @theme.base_font_color,
              bg_color: @theme.table_footer_background_color)
          end
        end
      ensure
        @repeat_table_header = nil
      end

      @current_y -= @theme.table_margin_bottom
      ""
    end

    # Rend une rangée de tableau, en gérant `colspan` et `valign`.
    # `rowspan` n'est pas encore visuellement géré (la cellule occupe
    # une seule rangée et le cell suivant remplit la position que le
    # span aurait laissée libre — comportement minimaliste sûr).
    # Largeur naturelle d'une ligne de segments inline, en points.
    # Reproduit EXACTEMENT la mesure de `wrap_segments` (compensation
    # codespan/kbd/button/mark, CJK via `font_cjk`) afin d'aligner
    # correctement les cellules de tableau en `halign=center|right`.
    private def measure_segment_line(segments : Array(InlineSegment), font_size : Float64) : Float64
      w = 0.0
      segments.each do |seg|
        if seg.image_path
          w += seg.image_width || (font_size * 1.2)
        elsif !seg.text.empty?
          base_w =
            if seg.text.size == 1 && (c = seg.text[0]) && c.ord >= 0x3000 &&
               (cjk_f = font_cjk) && cjk_f.has_glyph?(c)
              cjk_f.string_width(seg.text, font_size)
            else
              get_font(resolve_inline_font(seg)).string_width(seg.text, font_size)
            end
          if seg.mono && !seg.kbd && !@theme.codespan_background_color.empty?
            base_w += @theme.codespan_padding_x
          end
          base_w += 4.0 if seg.kbd || seg.button
          base_w += 2.0 if seg.mark
          w += base_w
        end
      end
      w
    end

    private def render_table_row(
      row,
      col_widths : Array(Float64),
      col_count : Int32,
      font_size : Float64,
      line_h : Float64,
      padding : Float64,
      *,
      font_name : String,
      font_color : String,
      bg_color : String?,
    ) : Nil
      # Calculer les largeurs effectives par cellule (colspan), et
      # wrapper le texte dans cette largeur pour mesurer la hauteur de
      # la rangée.
      # Une rangée d'en-tête / de pied est en gras : on propage le
      # gras aux segments (via `copy_with`) plutôt que de forcer la
      # police globalement, car `render_segment_line` choisit la
      # police PAR segment (`resolve_inline_font`). De même, on
      # injecte `font_color` comme couleur de segment par défaut
      # (l'en-tête a sa propre couleur, distincte du corps).
      row_bold = font_name == @fn_body_bold
      cell_widths = [] of Float64
      cell_seg_lines = [] of Array(Array(InlineSegment))
      col_idx = 0
      row.each do |cell|
        cs = cell.colspan || 1
        cs = 1 if cs < 1
        # Borne supérieure : ne pas déborder si l'auteur a indiqué un
        # colspan > nombre de colonnes restantes.
        remaining = col_count - col_idx
        cs = remaining if remaining > 0 && cs > remaining
        cw = (col_idx...col_idx + cs).sum { |k| col_widths[k]? || (@content_width / col_count) }
        cell_widths << cw
        # Markup inline PRÉSERVÉ : on parse les segments (codespan,
        # gras, italique, lien…) au lieu de les aplatir via
        # `strip_inline_markup`. Un mot de passe en `` `…` `` garde
        # ainsi sa police monospace + son fond grisé dans la cellule
        # (c'était le bug : le code n'était plus rendu « comme du
        # code » mais en texte courant).
        segs = parse_inline(cell.text || "").map do |s|
          s.copy_with(bold: s.bold || row_bold, color: s.color || font_color)
        end
        wrapped = wrap_segments(segs, cw - 2 * padding, font_size)
        wrapped = [[] of InlineSegment] if wrapped.empty?
        cell_seg_lines << wrapped
        col_idx += cs
      end
      max_lines = cell_seg_lines.empty? ? 1 : cell_seg_lines.max_of(&.size)
      row_h = (max_lines * line_h) + (2 * padding)

      check_page_break(row_h)
      page = @current_page.not_nil!
      x = @margin

      row.each_with_index do |cell, ci|
        cw = cell_widths[ci]

        # Fond
        if bg_color
          page.fill_color(bg_color)
          page.rectangle(x, @current_y - row_h, cw, row_h)
          page.fill
        end

        # Bordure
        page.stroke_color(@theme.table_border_color)
        page.line_width(@theme.table_border_width)
        page.rectangle(x, @current_y - row_h, cw, row_h)
        page.stroke

        # Texte : rendu des segments inline (codespan en mono + fond
        # grisé, gras, italique, lien…). La police et la couleur sont
        # portées par chaque segment (cf. boucle de mesure ci-dessus).
        page.fill_color(font_color)
        lines = cell_seg_lines[ci]
        halign = cell.attr("halign") || "left"
        valign = cell.attr("valign") || "top"
        text_block_h = lines.size * line_h

        # Position Y du haut du bloc texte selon valign.
        # `top`    : padding sous le bord supérieur
        # `middle` : centré dans la rangée
        # `bottom` : padding au-dessus du bord inférieur
        block_top_y = case valign
                      when "middle" then @current_y - (row_h - text_block_h) / 2
                      when "bottom" then @current_y - row_h + padding + text_block_h
                      else               @current_y - padding
                      end

        last_li = lines.size - 1
        lines.each_with_index do |line, li|
          ty = block_top_y - font_size - (li * line_h)
          if halign == "center" || halign == "right"
            # Centré / à droite : mesure + décalage, jamais justifié.
            lw = measure_segment_line(line, font_size)
            tx = halign == "center" ? x + (cw - lw) / 2 : x + cw - lw - padding
            render_segment_line(page, line, tx, ty, font_size)
          else
            # Aligné à gauche (défaut) : on JUSTIFIE les lignes
            # non-finales à la largeur interne de la cellule, comme un
            # paragraphe (la dernière ligne reste à gauche). On suit le
            # défaut du thème via `base_text_align` : en thème « left »
            # rien n'est étiré ; en « justify » un paragraphe de cellule
            # multi-lignes va jusqu'au bord droit de la colonne — même
            # traitement que les paragraphes hors tableau. Le garde-fou
            # `max_extra_factor` de `render_segment_line` évite les
            # lignes sur-étirées (colonne étroite).
            line_align = li == last_li ? "left" : @theme.base_text_align
            render_segment_line(page, line, x + padding, ty, font_size,
              target_w: cw - 2 * padding, align: line_align)
          end
        end

        # Lien cliquable : le rendu de cellule affiche du texte brut
        # (`strip_inline_markup`), mais si le contenu portait un lien
        # (`<a href="…">`), on superpose une annotation URI sur la
        # zone de texte. Couvre le cas courant « cellule = URL ». On
        # se limite aux URI externes (http/https/ftp/mailto) ; les
        # ancres internes (`#id`) relèvent d'un autre type d'annotation.
        if (lm = (cell.text || "").match(/href="([^"]+)"/)) && !lines.empty?
          href = lm[1]
          if href.includes?("://") || href.starts_with?("mailto:")
            page.link_uri(
              rect: {x + padding, block_top_y - lines.size * line_h, x + cw - padding, block_top_y},
              uri: href,
            )
          end
        end

        x += cw
      end

      @current_y -= row_h
    end

    # =========================================================================
    # Images
    # =========================================================================

    def convert_image(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)

      target = node.attr("target") || ""
      return "" if target.empty?

      ensure_page
      alt = node.attr("alt") || target
      image_path = resolve_image_path(node, target)

      unless image_path && File.exists?(image_path)
        warn_image(target, "fichier introuvable")
        render_image_placeholder(alt)
        return ""
      end

      begin
        if svg_target?(target)
          render_svg_image(image_path, node)
        else
          render_raster_image(image_path, node)
        end
      rescue ex
        # Le cadre de remplacement reste, mais l'auteur doit savoir
        # pourquoi : sans message, un attribut mal lu (ex. une virgule
        # dans le texte alternatif non protégée par des guillemets, lue
        # comme `width`) donnait un cadre vide inexpliqué.
        warn_image(target, ex.message || ex.class.name)
        render_image_placeholder(alt)
      end
      ""
    end

    private def warn_image(target : String, reason : String) : Nil
      STDERR.puts "Avertissement : image « #{target} » non rendue (#{reason}) ; remplacée par un cadre."
    end

    # Vector path: route `.svg` → `page.svg`. Bitmap loaders (PDF::Images::Image)
    # ne savent pas lire le SVG ; il faut le contenu textuel + le renderer SVG
    # natif du shard pdf, qui dessine le SVG en primitives PDF.
    private def svg_target?(target : String) : Bool
      target.downcase.ends_with?(".svg")
    end

    private def render_svg_image(path : String, node : Asciicrystal::Block) : Nil
      svg_data = File.read(path)
      parser = @doc.svg_parser_for(svg_data)

      # Dimensions natives (préfère viewBox quand présent — c'est le repère
      # de coord. interne du SVG, le « width=/height= » du tag <svg> n'est
      # qu'une suggestion d'affichage).
      svg_w = parser.width
      svg_h = parser.height
      if vb = parser.viewbox
        svg_w = vb[2] if vb[2] > 0
        svg_h = vb[3] if vb[3] > 0
      end

      display_w, display_h = image_display_size(node, svg_w, svg_h)
      caption_lines = image_caption_lines(node)
      check_page_break(display_h + caption_height(caption_lines) + 8.0)
      page = @current_page.not_nil!
      x = align_image_x(node, display_w)
      # Les `<text>` du SVG prennent la police du corps quand elle est
      # une TTF : sinon Helvetica WinAnsi remplace ≈, →, ■… par `?`.
      page.svg(svg_data, at: {x, @current_y}, width: display_w, height: display_h,
        font: @font_body.as?(PDF::Fonts::TrueTypeFont),
        bold_font: @font_body_bold.as?(PDF::Fonts::TrueTypeFont))
      @current_y -= display_h
      render_image_caption(node, caption_lines)
      @current_y -= 8.0
    end

    private def render_raster_image(path : String, node : Asciicrystal::Block) : Nil
      img = PDF::Images::Image.load(path)
      display_w, display_h = image_display_size(node, img.width.to_f, img.height.to_f)
      caption_lines = image_caption_lines(node)
      check_page_break(display_h + caption_height(caption_lines) + 8.0)
      page = @current_page.not_nil!
      x = align_image_x(node, display_w)
      # `page.image` ancre l'image par son coin INFÉRIEUR gauche (cf.
      # `render_title_logo`) : on passe donc le bas de l'image. Passer
      # `@current_y` la dessinait au-dessus de sa place, par-dessus le
      # bloc précédent.
      page.image(img, at: {x, @current_y - display_h}, width: display_w, height: display_h)
      @current_y -= display_h
      render_image_caption(node, caption_lines)
      @current_y -= 8.0
    end

    # Taille d'affichage d'une image de dimensions natives `native_w` ×
    # `native_h` :
    #
    # * largeur : `pdfwidth`, sinon `width` (nombre, `pt`/`cm`/`mm`/`in`
    #   ou pourcentage de la largeur utile), sinon la largeur native ;
    #   jamais plus que la largeur utile ;
    # * hauteur : `height` si fourni, sinon proportionnelle ;
    # * une image plus haute que la zone utile d'une page est réduite,
    #   ratio conservé, pour tenir sur une page (elle débordait sur le
    #   pied de page et hors de la feuille).
    private def image_display_size(node : Asciicrystal::Block, native_w : Float64, native_h : Float64) : {Float64, Float64}
      max_w = @content_width
      requested_w = parse_image_length(node.attr("pdfwidth")) || parse_image_length(node.attr("width"))
      display_w = [requested_w || native_w, max_w].min
      display_h = parse_image_length(node.attr("height")) || native_h * display_w / native_w

      caption_h = caption_height(image_caption_lines(node))
      max_h = @page_height - 2 * @margin - 20.0 - caption_h - 8.0
      if display_h > max_h && max_h > 0
        display_w *= max_h / display_h
        display_h = max_h
      end
      {display_w, display_h}
    end

    # Longueur d'image : nombre nu ou `px` (points), `pt`, `cm`, `mm`,
    # `in`, ou `%` de la largeur utile. `nil` si absente ou illisible
    # (au lieu de lever une exception sur `"100%".to_f`).
    private def parse_image_length(value : String?) : Float64?
      return nil unless value
      v = value.strip.downcase
      if v.ends_with?('%')
        v.rchop.to_f?.try { |n| n * @content_width / 100.0 }
      else
        parse_logo_length(v.ends_with?("px") ? v[0...-2] : v)
      end
    end

    # Titre d'image (`.Mon titre`), préfixé de sa numérotation
    # (« Figure 1. ») comme en amont ; `:figure-caption!:` la retire.
    # Découpé en lignes à la largeur utile.
    private def image_caption_lines(node : Asciicrystal::Block) : Array(String)
      title = node.title
      return [] of String if title.nil? || title.empty?
      # Asciidoctor (Ruby) numérote les images à l'analyse :
      # `block.assign_caption(attributes.delete('caption'), 'figure')`.
      # Le parser asciicrystal ne le fait pas pour le contexte `:image`
      # (absent de CAPTION_ATTRIBUTE_NAMES) : on complète ici, dans
      # l'ordre du document. Sans effet si une légende existe déjà.
      node.assign_caption(node.attr("caption"), :figure)
      caption = strip_inline_markup(node.captioned_title)
      wrap_text(caption, @content_width, image_caption_font_size, @fn_body_italic)
    end

    private def image_caption_font_size : Float64
      @theme.base_font_size - 1
    end

    private def caption_height(lines : Array(String)) : Float64
      return 0.0 if lines.empty?
      4.0 + lines.size * image_caption_font_size * @theme.base_line_height
    end

    # Titre sous l'image, aligné comme elle, en italique gris.
    private def render_image_caption(node : Asciicrystal::Block, lines : Array(String)) : Nil
      return if lines.empty?
      page = @current_page.not_nil!
      size = image_caption_font_size
      line_h = size * @theme.base_line_height
      @current_y -= 4.0
      set_font(page, @fn_body_italic, size)
      page.fill_color("888888")
      lines.each do |line|
        x = align_image_x(node, text_width(line, @fn_body_italic, size))
        draw_text_run(page, line, x, @current_y - size, @fn_body_italic, size)
        @current_y -= line_h
      end
      page.fill_color("000000")
    end

    private def align_image_x(node : Asciicrystal::Block, display_w : Float64) : Float64
      case node.attr("align") || "left"
      when "center" then @margin + (@content_width - display_w) / 2
      when "right"  then @margin + @content_width - display_w
      else               @margin
      end
    end

    # Même résolution que le logo de garde (`resolve_image_path_str`) :
    # `docdir`, puis le dossier du `docfile`. Sans ce repli, en mode
    # sûr `secure`/`server` (défaut de l'API, `docdir` vidé), une image
    # à chemin relatif n'était trouvée que depuis le répertoire courant.
    private def resolve_image_path(node : Asciicrystal::Block, target : String) : String?
      resolve_image_path_str(node.document, target)
    end

    private def render_image_placeholder(alt : String) : Nil
      ensure_page
      page = @current_page.not_nil!
      block_h = 40.0
      @current_y -= 8.0
      page.stroke_color("cccccc")
      page.line_width(0.5)
      page.rectangle(@margin, @current_y - block_h, @content_width, block_h)
      page.stroke
      set_font(page, @fn_body, @theme.base_font_size - 1)
      page.fill_color("888888")
      page.text("[Image: #{alt}]", at: {@margin + 8.0, @current_y - 24.0})
      @current_y -= block_h + 8.0
    end

    # =========================================================================
    # Sauts de page et séparateurs
    # =========================================================================

    def convert_page_break(node : Asciicrystal::AbstractNode) : String
      # Saut de page de base (`<<<` ou `[%always]` — `always` est
      # accepté par parité Ruby asciicrystal-pdf bien qu'il ne change
      # rien au comportement, le saut étant déjà inconditionnel).
      new_page

      # Options recto / verso : aligner la prochaine page de contenu
      # sur une page impaire (recto, page de droite en livre ouvert)
      # ou paire (verso, gauche). Si la nouvelle page créée n'est pas
      # du bon parité, on en génère une de plus, qui restera vide.
      if node.is_a?(Asciicrystal::Block)
        if node.option?("recto") && @page_number.even?
          new_page
        elsif node.option?("verso") && @page_number.odd?
          new_page
        end
      end
      ""
    end

    def convert_thematic_break(node : Asciicrystal::AbstractNode) : String
      ensure_page
      page = @current_page.not_nil!
      @current_y -= 8.0
      page.stroke_color("cccccc")
      page.line_width(1.0)
      page.line({@margin, @current_y}, {@margin + @content_width, @current_y})
      page.stroke
      @current_y -= 8.0
      ""
    end

    # Audio inline : un PDF n'embarque pas d'audio lisible nativement.
    # On rend un bandeau visuel « ▶ Audio : <target> » qui pointe vers
    # l'URL en lien cliquable. Le caption éventuel est inclus.
    def convert_audio(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)
      target = node.attr("target") || ""
      caption = node.title
      render_media_placeholder("▶ Audio", target, caption)
      ""
    end

    # Video inline : même idée — placeholder cliquable vers la source.
    def convert_video(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)
      target = node.attr("target") || ""
      caption = node.title
      render_media_placeholder("▶ Vidéo", target, caption)
      ""
    end

    # STEM (mathématiques inline AsciiMath / LaTeX) : faute de moteur
    # math intégré, on affiche le contenu source en monospace dans un
    # encadré gris pâle (même style que les listings courts). Une vraie
    # implémentation demanderait l'embed d'un sous-ensemble MathJax ou
    # un rendu via katex-cli — reporté.
    def convert_stem(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)
      raw = node.content
      content = raw.is_a?(Array) ? raw.join("\n") : (raw || "").to_s
      render_media_placeholder("∑ Math", content, node.title, monospace: true)
      ""
    end

    # Pass-through : contenu HTML brut sans interprétation. Comme on
    # cible le PDF, on dégrade vers du texte plat : on strippe le HTML
    # via Sanitizer et on l'inclut comme un paragraphe normal. Mieux
    # que de tout perdre.
    def convert_pass(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)
      raw = node.content
      content = raw.is_a?(Array) ? raw.join("\n") : (raw || "").to_s
      ensure_page
      page = @current_page.not_nil!
      font_size = @theme.base_font_size
      line_h = font_size * @theme.base_line_height
      stripped = Sanitizer.sanitize(content)
      lines = wrap_text(stripped, @content_width, font_size)
      check_page_break(lines.size * line_h + 4.0)
      page = @current_page.not_nil!
      set_font(page, @fn_body, font_size)
      page.fill_color(@theme.base_font_color)
      lines.each do |line|
        draw_text_run(page, line, @margin, @current_y - font_size, @fn_body, font_size)
        @current_y -= line_h
      end
      @current_y -= 4.0
      ""
    end

    # Bandeau placeholder commun pour les médias non rendables en PDF
    # (audio, video, stem). Affiche un label coloré + la source +
    # éventuellement un caption, dans un cadre gris pâle.
    private def render_media_placeholder(
      label : String, target : String, caption : String?, monospace : Bool = false,
    ) : Nil
      ensure_page
      font_size = @theme.base_font_size
      line_h = font_size * @theme.base_line_height
      padding = 6.0

      target_font = monospace ? @fn_mono : @fn_body
      target_lines = wrap_text(target, @content_width - 80.0, font_size, target_font)
      caption_lines = caption ? wrap_text(caption, @content_width - 16.0, font_size - 1, @fn_body) : [] of String
      content_lines = target_lines.size + caption_lines.size
      block_h = content_lines * line_h + 2 * padding

      check_page_break(block_h + 8.0)
      page = @current_page.not_nil!
      @current_y -= 4.0

      # Fond + bordure
      page.fill_color("f5f5f5")
      page.rectangle(@margin, @current_y - block_h, @content_width, block_h)
      page.fill
      page.stroke_color("cccccc")
      page.line_width(0.5)
      page.rectangle(@margin, @current_y - block_h, @content_width, block_h)
      page.stroke

      # Label (à gauche, en bleu)
      set_font(page, @fn_body_bold, font_size)
      page.fill_color("3b9ddd")
      page.text(label, at: {@margin + padding, @current_y - padding - font_size})

      # Cible
      x_target = @margin + 80.0
      y = @current_y - padding - font_size
      set_font(page, target_font, font_size)
      page.fill_color(@theme.base_font_color)
      target_lines.each do |line|
        if target.starts_with?("http://") || target.starts_with?("https://")
          # Link cliquable vers la source.
          tw = text_width(line, target_font, font_size)
          page.link_uri(rect: {x_target, y - 2, x_target + tw, y + font_size}, uri: target)
        end
        draw_text_run(page, line, x_target, y, target_font, font_size)
        y -= line_h
      end

      # Caption (si présent)
      caption_lines.each do |line|
        set_font(page, @fn_body, font_size - 1)
        page.fill_color("888888")
        draw_text_run(page, line, @margin + padding, y, @fn_body, font_size - 1)
        y -= line_h
      end

      @current_y -= block_h + 8.0
    end

    # =========================================================================
    # Blocs de citation, verse, sidebar, example, open, preamble
    # =========================================================================

    def convert_quote(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)
      ensure_page
      render_indented_block(node, left_bar_color: "aaaaaa", indent: 16.0, kind: :quote)
    end

    def convert_verse(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)
      ensure_page
      render_indented_block(node, left_bar_color: "aaaaaa", indent: 16.0, kind: :verse)
    end

    def convert_sidebar(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)
      render_panel(node, :sidebar)
      ""
    end

    def convert_example(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)

      # Extension : rôle `[.x-score-<niveau>]` sur un bloc example
      # (`====`) le transforme en bloc de score coloré.
      if (level = detect_x_score_level(node))
        return render_x_score_block(node, level)
      end

      render_panel(node, :example, collapsible: node.option?("collapsible"))
      ""
    end

    # Rend un bloc encadré (sidebar / example).
    #
    # Stratégie : on estime la hauteur du bloc (paragraphes + tableaux
    # + listes + …) via `estimate_block_height`, on dessine fond +
    # bordure d'avance, puis on rend le contenu par-dessus. Le
    # contenu opaque écrase le fond et le rend visible — l'inverse
    # (rétroactif) masquerait le contenu sous une couche unie.
    #
    # Si l'estimation diffère de la hauteur réelle, on aura un fond
    # un peu plus court ou un peu trop long ; on accepte cet écart
    # visuel mineur en échange de la simplicité (pas de mode
    # « deux passes » avec dry-run du rendu).
    private def render_panel(node : Asciicrystal::Block, kind : Symbol, collapsible : Bool = false) : Nil
      ensure_page

      bg, border, border_w, padding, mtop, mbot, title_color, title_size =
        case kind
        when :sidebar
          {
            @theme.sidebar_background_color,
            @theme.sidebar_border_color,
            @theme.sidebar_border_width,
            @theme.sidebar_padding,
            @theme.sidebar_margin_top,
            @theme.sidebar_margin_bottom,
            @theme.sidebar_title_font_color,
            @theme.sidebar_title_font_size,
          }
        else
          {
            @theme.example_background_color,
            @theme.example_border_color,
            @theme.example_border_width,
            @theme.example_padding,
            @theme.example_margin_top,
            @theme.example_margin_bottom,
            @theme.example_title_font_color,
            @theme.example_title_font_size,
          }
        end

      # Estimation de la hauteur cumulée du contenu interne.
      content_h_est = node.blocks.sum { |b| estimate_block_height(b) }
      title_h = node.title? ? title_size * 1.6 : 0.0
      total_h_est = content_h_est + 2 * padding + title_h

      # Pré-flight : si le bloc tient sur une page entière mais pas
      # dans l'espace restant, on saute proprement.
      page_content_h = @page_height - 2 * @margin
      if @current_y - total_h_est < @margin && total_h_est <= page_content_h
        new_page
      end

      page = @current_page.not_nil!
      @current_y -= mtop
      y_start = @current_y

      # 1) Fond + bordure dessinés EN PREMIER, dimensionnés via
      #    l'estimation. Ce qui suit (titre, contenu) sera tracé
      #    par-dessus.
      saved_margin = @margin
      saved_content_w = @content_width

      if !bg.empty?
        page.fill_color(bg)
        page.rectangle(saved_margin, y_start - total_h_est, saved_content_w, total_h_est)
        page.fill
      end
      if !border.empty?
        page.stroke_color(border)
        page.line_width(border_w)
        page.rectangle(saved_margin, y_start - total_h_est, saved_content_w, total_h_est)
        page.stroke
      end

      # 2) Titre du bloc (caption `.Mon titre`). Préfixé d'un ▾ quand
      # le bloc porte l'option `[%collapsible]` — signal visuel du
      # caractère « dépliable » côté HTML, simplement informatif en
      # PDF (pas d'interactivité possible).
      if node.title? && (title = node.title)
        inner_x = saved_margin + padding
        set_font(page, @fn_body_bold, title_size)
        page.fill_color(title_color)
        rendered_title = decode_html_entities(title)
        rendered_title = "▾ #{rendered_title}" if collapsible
        draw_text_run(page, rendered_title, inner_x, @current_y - padding - title_size, @fn_body_bold, title_size)
        @current_y -= padding + title_size * 1.4
      else
        @current_y -= padding
      end

      # 3) Contenu : on indente via @margin/@content_width temporaires.
      @margin += padding
      @content_width -= 2 * padding
      begin
        node.blocks.each { |b| convert(b) }
      ensure
        @margin = saved_margin
        @content_width = saved_content_w
      end

      # Aligner @current_y sur le bas estimé du panneau pour ne pas
      # créer de décalage avec les blocs qui suivent. Au pire on
      # gagne ou perd quelques points par rapport au tracé réel.
      @current_y = y_start - total_h_est
      @current_y -= mbot
    end

    def convert_open(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)

      # Extension : rôle `[.x-score-<niveau>]` sur un open block
      # (`--`) le transforme en bloc de score coloré.
      if (level = detect_x_score_level(node))
        return render_x_score_block(node, level)
      end

      # Extension : rôle `[.x-box]` sur un open block le transforme en
      # panneau encadré avec fond, bordure et titre optionnel — sans
      # passer par la sémantique « sidebar » ou « example », plus
      # libre côté AsciiDoc. Pratique pour des encadrés visuels qu'on
      # veut faire sans détourner les blocs sémantiques existants.
      if node.has_role?("x-box")
        render_panel(node, :sidebar)
        return ""
      end

      # Option `[%unbreakable]` : on essaie de garder tout le bloc sur
      # une même page. Estimation grossière de la hauteur cumulée
      # (paragraphes + tableaux + listes + listings + admonitions).
      # Si le bloc tient sur une page mais pas dans l'espace restant,
      # on saute à la page suivante avant de commencer le rendu.
      # Si le bloc dépasse la hauteur d'une page entière, on accepte
      # la pagination normale (cf. « if possible » du standard).
      if node.option?("unbreakable")
        ensure_page
        total_h = node.blocks.sum { |b| estimate_block_height(b) }
        page_content_h = @page_height - 2 * @margin
        space_left = @current_y - @margin
        if total_h <= page_content_h && total_h > space_left
          new_page
        end
      end

      node.blocks.each { |b| convert(b) }
      ""
    end

    # Estime la hauteur en points qu'occupera un bloc enfant lors du
    # rendu. Utilisé par `convert_open` (option `[%unbreakable]`) pour
    # décider d'un saut de page anticipé. Volontairement pessimiste
    # (mieux vaut sauter trop que pas assez).
    private def estimate_block_height(block : Asciicrystal::AbstractBlock) : Float64
      case block.context.to_s
      when "paragraph"
        raw = block.content
        text = raw.is_a?(Array) ? raw.join(" ") : (raw || "")
        return 0.0 if text.empty?
        lines = wrap_text(text, @content_width, @theme.base_font_size, @fn_body)
        lines.size * @theme.base_font_size * @theme.base_line_height + 8.0
      when "table"
        estimate_table_height(block)
      when "listing", "literal"
        estimate_listing_height(block)
      when "ulist", "olist", "dlist"
        estimate_list_height(block)
      when "admonition"
        line_h = @theme.base_font_size * @theme.base_line_height
        raw = block.content
        text = raw.is_a?(Array) ? raw.join("\n") : (raw || "")
        (text.lines.size + 1) * line_h + 16.0
      when "image"
        # Sans charger l'image on ne sait pas la hauteur réelle ; on
        # surestime pour rester côté safe.
        160.0
      when "open"
        # Bloc imbriqué : somme récursive des enfants.
        if block.responds_to?(:blocks)
          block.blocks.sum { |b| estimate_block_height(b) }
        else
          40.0
        end
      else
        # Fallback raisonnable pour les types non couverts.
        40.0
      end
    end

    private def estimate_table_height(block : Asciicrystal::AbstractBlock) : Float64
      return 40.0 unless block.responds_to?(:rows)
      font_size = @theme.base_font_size
      line_h = font_size * @theme.base_line_height
      padding = @theme.table_cell_padding * 2

      total = @theme.table_margin_top + @theme.table_margin_bottom
      rows = block.rows
      [rows.head, rows.body, rows.foot].each do |section|
        section.each do |row|
          row_h = padding + line_h
          row.each do |cell|
            text = cell.text || ""
            next if text.empty?
            # Largeur de cellule estimée : content_width / nb cellules.
            est_col_w = @content_width / [row.size, 1].max
            wrapped = wrap_text(text, est_col_w - padding, font_size, @fn_body)
            cell_h = wrapped.size * line_h + padding
            row_h = cell_h if cell_h > row_h
          end
          total += row_h
        end
      end
      total
    end

    private def estimate_listing_height(block : Asciicrystal::AbstractBlock) : Float64
      return 40.0 unless block.responds_to?(:lines)
      line_h = @theme.code_font_size * @theme.base_line_height
      block.lines.size * line_h + 2 * @theme.code_padding +
        @theme.code_margin_top + @theme.code_margin_bottom
    end

    private def estimate_list_height(block : Asciicrystal::AbstractBlock) : Float64
      return 40.0 unless block.responds_to?(:items)
      line_h = @theme.base_font_size * @theme.base_line_height
      # Approximation : chaque item ≈ 1 ligne + petit espacement.
      block.items.size * (line_h + 4.0) + 8.0
    end

    def convert_preamble(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)
      node.blocks.each { |b| convert(b) }
      ""
    end

    def convert_floating_title(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Block)
      ensure_page
      level = node.level
      title = node.title || ""
      font_size = @theme.heading_font_size(level)
      check_page_break(font_size + 8.0)
      page = @current_page.not_nil!
      set_font(page, @fn_body_bold, font_size)
      page.fill_color(@theme.heading_font_color)
      draw_text_run(page, title, @margin, @current_y - font_size, @fn_body_bold, font_size)
      @current_y -= font_size + 6.0
      ""
    end

    def convert_inline_indexterm(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Inline)
      term = node.text || ""
      @index_entries << IndexEntry.new(term, @page_number) unless term.empty?
      ""
    end

    # Callout inline `<1>` `<2>` … dans un bloc listing.
    # Rendu : un disque sombre avec le numéro en blanc, mêlé au flux
    # de code. Parité Ruby : `<b class="conum">(1)</b>`.
    def convert_inline_callout(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Inline)
      text = node.text || ""
      # Encodage typographique simple : utiliser les chiffres
      # entourés d'un cercle (Unicode ① ② … ⑳) quand possible. Au-delà,
      # fallback sur `(N)` en gras.
      n = text.to_i?
      glyph = if n && n >= 1 && n <= 20
                # ① = U+2460 → décalage selon le numéro
                ((0x2460 + n - 1).chr.to_s)
              else
                "(#{text})"
              end
      "<b class=\"conum\">#{glyph}</b>"
    end

    # Liste de callouts (colist) qui suit un listing annoté.
    # Format AsciiDoc : `<1> Description du premier callout.`
    # Rendu : liste à marqueurs ① ② … alignés sur le bloc texte.
    def convert_colist(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::List)
      ensure_page

      font_size = @theme.base_font_size
      line_h = font_size * @theme.base_line_height
      marker_w = 18.0 # espace réservé au marqueur ①

      @current_y -= 4.0
      node.items.each_with_index do |item, idx|
        n = idx + 1
        glyph = (n >= 1 && n <= 20) ? ((0x2460 + n - 1).chr.to_s) : "(#{n})"

        text = ""
        if item.responds_to?(:text)
          itext = item.text
          text = itext.is_a?(Array) ? itext.join(" ") : (itext || "").to_s
        end

        segments = parse_inline(text)
        lines = wrap_segments(segments, @content_width - marker_w, font_size)
        lines = [[] of InlineSegment] if lines.empty?

        # Hauteur totale de l'item pour anti-orphelin.
        check_page_break(lines.size * line_h + 4.0)
        page = @current_page.not_nil!

        # Marqueur en gras à gauche.
        set_font(page, @fn_body_bold, font_size)
        page.fill_color(@theme.heading_font_color)
        draw_text_run(page, glyph, @margin, @current_y - font_size, @fn_body_bold, font_size)

        # Texte indenté sous le marqueur, multi-ligne.
        y = @current_y - font_size
        lines.each do |line|
          render_segment_line(page, line, @margin + marker_w, y, font_size)
          y -= line_h
        end
        @current_y -= lines.size * line_h + 4.0
      end
      ""
    end

    # Conversion d'un quoted inline (gras / italique / mono / sub / sup
    # / mark / quotes) en HTML, qui sera ensuite digéré par
    # `InlineRenderer.parse` avec son markup. Parité de la table
    # `QUOTE_TAGS` côté HTML5 d'asciidoctor (Ruby et Crystal).
    def convert_inline_quoted(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Inline)
      type = node.type || :strong
      text = node.text || ""
      case type
      when :strong      then "<strong>#{text}</strong>"
      when :emphasis    then "<em>#{text}</em>"
      when :monospaced  then "<code>#{text}</code>"
      when :superscript then "<sup>#{text}</sup>"
      when :subscript   then "<sub>#{text}</sub>"
      when :mark        then "<mark>#{text}</mark>"
      when :double      then "“#{text}”"
      when :single      then "‘#{text}’"
      else                   text
      end
    end

    # `kbd:[Ctrl+C]` — produit le HTML keyseq parité Ruby/HTML5.
    # `InlineRenderer` mappera `<kbd>` sur monospace + traitement
    # spécifique (réservé pour un futur encadré).
    def convert_inline_kbd(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Inline)
      keys_str = node.attr("keys") || ""
      keys = keys_str.split('+').map(&.strip).reject(&.empty?)
      return "" if keys.empty?
      if keys.size == 1
        "<kbd>#{keys[0]}</kbd>"
      else
        "<span class=\"keyseq\"><kbd>#{keys.join("</kbd>+<kbd>")}</kbd></span>"
      end
    end

    # `btn:[OK]` — bouton d'interface utilisateur. HTML : <b class="button">.
    def convert_inline_button(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Inline)
      "<b class=\"button\">#{node.text}</b>"
    end

    # `image:logo.png[]` ou `icon:warning[]` — image inline.
    # Pour les images : produit un `<img>` HTML qui sera digéré par
    # `InlineRenderer.parse_html` et rendu via `page.image` ou
    # `page.svg`. Pour les icônes (`type == :icon`) : on retourne pour
    # l'instant un placeholder textuel `[<nom>]` faute de bibliothèque
    # d'icônes intégrée. Une vraie roadmap demanderait Font Awesome /
    # icônes Twemoji.
    def convert_inline_image(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Inline)
      target = node.target || ""
      return "" if target.empty?

      type = node.type || :image
      alt = node.attr("alt") || target

      if type == :icon
        return "[#{target}]" # fallback texte tant que pas de bibliothèque d'icônes
      end

      image_path = resolve_image_path_str(node.document, target)
      return "[#{alt}]" unless image_path && File.exists?(image_path)

      # Width/height : prioritaire `pdfwidth`, sinon `width`. Si rien,
      # le rendu prendra une taille raisonnable « inline » (cf.
      # `render_segment_line`). On encode l'alt comme texte du segment
      # pour le fallback (et pour la lisibilité du HTML produit).
      width = node.attr("pdfwidth") || node.attr("width") || ""
      height = node.attr("height") || ""

      attrs = %( src="#{image_path}")
      attrs += %( width="#{width}") unless width.empty?
      attrs += %( height="#{height}") unless height.empty?
      attrs += %( alt="#{alt}")
      "<img#{attrs}/>"
    end

    # `menu:[Fichier > Quitter]` — chaîne de menus. HTML standard.
    def convert_inline_menu(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Inline)
      menu = node.attr("menu") || ""
      menuitem = node.attr("menuitem") || ""
      submenus = node.attr("submenus") || ""
      caret = " › "
      if submenus.empty?
        if !menuitem.empty?
          "<span class=\"menuseq\"><b class=\"menu\">#{menu}</b>#{caret}<b class=\"menuitem\">#{menuitem}</b></span>"
        else
          "<b class=\"menuref\">#{menu}</b>"
        end
      else
        joiner = "</b>#{caret}<b class=\"submenu\">"
        "<span class=\"menuseq\"><b class=\"menu\">#{menu}</b>#{caret}<b class=\"submenu\">#{submenus.split(",").map(&.strip).join(joiner)}</b>#{caret}<b class=\"menuitem\">#{menuitem}</b></span>"
      end
    end

    # Gestion des notes de bas de page
    # Les notes sont collectées pendant le rendu, puis affichées en bas de chaque page.
    def convert_inline_footnote(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Inline)
      index_str = node.attr("index")
      index = index_str ? index_str.to_i : (@footnotes.size + 1)
      text = node.text || ""
      return "" if text.empty? && node.type == :xref

      # Enregistrer la note
      entry = FootnoteEntry.new(index, text, @page_number)
      @footnotes << entry
      (@footnotes_by_page[@page_number] ||= [] of FootnoteEntry) << entry

      # Afficher le numéro de note en exposant dans le texte courant
      ensure_page
      page = @current_page.not_nil!
      font_size = @theme.base_font_size * 0.7
      set_font(page, @fn_body, font_size)
      page.fill_color("0645ad")
      page.text("[#{index}]", at: {@margin, @current_y - @theme.base_font_size})
      page.fill_color(@theme.base_font_color)
      ""
    end

    # Rend les notes de bas de page pour une page donnée.
    # Appelé après le rendu de chaque page.
    private def render_page_footnotes(page : PDF::Page, page_num : Int32) : Nil
      notes = @footnotes_by_page[page_num]?
      return unless notes && !notes.empty?

      font_size = @theme.base_font_size * 0.8
      line_h = font_size * 1.3
      separator_y = @margin + @theme.footer_height + notes.size * line_h + 8.0

      # Ligne de séparation
      page.stroke_color("cccccc")
      page.line_width(0.5)
      page.line({@margin, separator_y}, {@margin + @content_width / 3, separator_y})
      page.stroke

      y = separator_y - 4.0
      notes.each do |note|
        set_font(page, @fn_body, font_size)
        page.fill_color(@theme.base_font_color)
        page.text("[#{note.index}] #{note.text}", at: {@margin, y - font_size})
        y -= line_h
      end
    end

    # Gestion des liens et références internes (XRefs)
    # Les liens sont rendus en couleur bleue soulignée dans le PDF.
    # Pour les références internes, le texte de la référence est affiché entre crochets.
    def convert_inline_anchor(node : Asciicrystal::AbstractNode) : String
      return "" unless node.is_a?(Asciicrystal::Inline)
      case node.type
      when :xref
        # Référence interne : afficher le texte ou l'id entre crochets
        reftext = node.text || node.attr("refid") || node.target || ""
        ensure_page
        page = @current_page.not_nil!
        font_size = @theme.base_font_size
        set_font(page, @fn_body, font_size)
        page.fill_color("0645ad")
        page.text("[» #{reftext}]", at: {@margin, @current_y - font_size})
        page.fill_color(@theme.base_font_color)
        @current_y -= font_size * @theme.base_line_height
      when :link
        # Lien externe : afficher le texte du lien en bleu avec annotation cliquable
        link_text = node.text || node.target || ""
        target = node.target || ""
        ensure_page
        page = @current_page.not_nil!
        font_size = @theme.base_font_size
        set_font(page, @fn_body, font_size)
        page.fill_color("0645ad")
        display = link_text.empty? ? target : link_text
        text_y = @current_y - font_size
        page.text(display, at: {@margin, text_y})

        # Annotation lien URI cliquable
        unless target.empty?
          tw = text_width(display, @fn_body, font_size)
          page.link_uri(rect: {@margin, text_y - 2, @margin + tw, text_y + font_size}, uri: target)
        end

        page.fill_color(@theme.base_font_color)
        @current_y -= font_size * @theme.base_line_height
      when :ref
        # Ancre de destination : enregistrer la position pour les XRefs
        @anchor_positions[node.id || ""] = @current_y if node.id
      when :bibref
        # Référence bibliographique
        id = node.id || ""
        reftext = node.reftext || id
        ensure_page
        page = @current_page.not_nil!
        font_size = @theme.base_font_size
        set_font(page, @fn_body, font_size)
        page.fill_color(@theme.base_font_color)
        page.text("[#{reftext}]", at: {@margin, @current_y - font_size})
        @current_y -= font_size * @theme.base_line_height
      end
      ""
    end

    # =========================================================================
    # Helpers de rendu
    # =========================================================================

    private def render_indented_block(
      node : Asciicrystal::Block,
      left_bar_color : String,
      indent : Float64,
      kind : Symbol = :quote,
    ) : String
      raw = node.content
      html = raw.is_a?(Array) ? raw.join("\n") : raw.to_s

      font_size = @theme.base_font_size
      line_h = font_size * @theme.base_line_height
      content_w = @content_width - indent - 8.0

      # Verse : préserve les sauts de ligne du source (pre-wrap). Chaque
      # ligne du source devient sa propre ligne dans le PDF, et le wrap
      # n'est appliqué qu'aux lignes qui débordent vraiment.
      # Quote : flow continu, retours à la ligne traités comme espaces.
      lines = if kind == :verse
                segs_per_line = html.split('\n').map { |para| parse_inline(para) }
                segs_per_line.flat_map { |segments| wrap_segments(segments, content_w, font_size) }
              else
                wrap_segments(parse_inline(html), content_w, font_size)
              end
      lines = [[] of InlineSegment] if lines.empty?

      block_h = lines.size * line_h + 8.0

      check_page_break(block_h + 12.0)

      page = @current_page.not_nil!
      @current_y -= 6.0

      # Barre de couleur à gauche
      page.fill_color(left_bar_color)
      page.rectangle(@margin, @current_y - block_h, 3.0, block_h)
      page.fill

      # Texte avec markup inline préservé.
      y = @current_y - font_size
      lines.each do |line|
        # Forcer italique pour les segments de quote/verse sauf si déjà
        # italiques (pour ne pas inverser). Pragma : si le segment n'a
        # pas d'italique explicite, on l'ajoute ; sinon on respecte.
        styled_line = line.map do |seg|
          if seg.italic
            seg
          else
            InlineSegment.new(
              text: seg.text,
              bold: seg.bold,
              italic: true,
              mono: seg.mono,
              sup: seg.sup,
              sub: seg.sub,
              mark: seg.mark,
              kbd: seg.kbd,
              button: seg.button,
              menu: seg.menu,
              color: seg.color,
              link: seg.link,
              image_path: seg.image_path,
              image_width: seg.image_width,
              image_height: seg.image_height,
              # Sans ce champ, un segment marqueur de hard break (`+\n`
              # AsciiDoc, généré comme `text: "", line_break: true`)
              # perdait son `line_break` à la reconstruction et
              # devenait un segment vide silencieusement ignoré — le
              # break disparaissait du PDF dans les blocs `[quote]`.
              line_break: seg.line_break,
            )
          end
        end
        render_segment_line(page, styled_line, @margin + indent, y, font_size)
        y -= line_h
      end

      @current_y -= block_h + 6.0

      # Attribution + citetitle. Ruby asciicrystal-pdf accepte les deux
      # via `[quote, Auteur, Titre]`.
      attribution = node.attr("attribution")
      citetitle = node.attr("citetitle")
      if attribution || citetitle
        parts = [] of String
        parts << attribution.to_s if attribution && !attribution.to_s.empty?
        parts << citetitle.to_s if citetitle && !citetitle.to_s.empty?
        unless parts.empty?
          set_font(page, @fn_body, font_size - 1)
          page.fill_color("555555")
          page.text("— #{parts.join(", ")}", at: {@margin + indent, @current_y - font_size})
          @current_y -= font_size + 4.0
        end
      end
      ""
    end

    # =========================================================================
    # Index
    # =========================================================================
    # Rend la page d'index alphabétique à la fin du document.
    # Les entrées sont groupées par lettre initiale et affichées sur plusieurs colonnes.
    # Compresse une liste triée de numéros de pages en chaîne lisible
    # avec ranges : `[12, 13, 14, 15, 17, 20, 21]` → `"12-15, 17, 20-21"`.
    # Comportement Ruby asciicrystal-pdf upstream (option
    # `index_pagenum_sequence_style: range` qui est le défaut).
    private def format_page_ranges(pages : Array(Int32)) : String
      return "" if pages.empty?
      ranges = [] of String
      start_p = pages[0]
      prev_p = pages[0]

      (1...pages.size).each do |i|
        p = pages[i]
        if p == prev_p + 1
          prev_p = p
        else
          ranges << (start_p == prev_p ? start_p.to_s : "#{start_p}-#{prev_p}")
          start_p = p
          prev_p = p
        end
      end
      ranges << (start_p == prev_p ? start_p.to_s : "#{start_p}-#{prev_p}")
      ranges.join(", ")
    end

    private def render_index : Nil
      return if @index_entries.empty?

      # Créer une nouvelle page pour l'index
      new_page
      page = @current_page.not_nil!

      font_size = @theme.index_font_size
      line_h = font_size * 1.5
      col_count = @theme.index_columns.clamp(1, 4)
      col_width = @content_width / col_count
      col_gap = 8.0
      entry_w = col_width - col_gap

      # Titre de l'index
      title_font_size = font_size + 6.0
      set_font(page, @fn_body_bold, title_font_size)
      page.fill_color(@theme.heading_font_color)
      page.text(@theme.index_title, at: {@margin, @page_height - @margin - title_font_size})
      y_start = @page_height - @margin - title_font_size * 2.0

      # Regrouper et trier les entrées
      # Structure : Hash(String, Hash(String, Array(Int32)))
      # lettre => terme => [pages]
      grouped = {} of String => Hash(String, Array(Int32))

      @index_entries.each do |entry|
        term = entry.term.strip
        next if term.empty?
        # Gestion des sous-termes (séparés par virgule : "terme principal, sous-terme")
        parts = term.split(",", 2).map(&.strip)
        primary = parts[0]
        secondary = parts[1]?
        letter = primary[0..0].upcase
        grouped[letter] ||= {} of String => Array(Int32)
        key = secondary ? "#{primary}\t#{secondary}" : primary
        grouped[letter][key] ||= [] of Int32
        grouped[letter][key] << entry.page_number unless grouped[letter][key].includes?(entry.page_number)
      end

      # Trier les lettres et les termes
      sorted_letters = grouped.keys.sort

      # Construire la liste aplatie des lignes à rendre
      # Chaque ligne est un tuple {type, text, pages}
      # type : :letter (en-tête de lettre), :primary, :secondary
      lines = [] of {Symbol, String, Array(Int32)}
      sorted_letters.each do |letter|
        lines << {:letter, letter, [] of Int32}
        sorted_terms = grouped[letter].keys.sort
        sorted_terms.each do |key|
          pages = grouped[letter][key].sort.uniq
          if key.includes?("\t")
            parts = key.split("\t", 2)
            lines << {:primary, parts[0], [] of Int32}
            lines << {:secondary, parts[1], pages}
          else
            lines << {:primary, key, pages}
          end
        end
      end

      # Rendre les lignes en colonnes
      col_idx = 0
      x = @margin + col_idx * col_width
      y = y_start

      lines.each do |type, text, pages|
        # Saut de colonne si nécessaire
        if y < @margin + line_h
          col_idx += 1
          if col_idx >= col_count
            # Nouvelle page
            new_page
            page = @current_page.not_nil!
            col_idx = 0
            y = @page_height - @margin
          else
            y = y_start
          end
          x = @margin + col_idx * col_width
        end

        case type
        when :letter
          # En-tête de lettre (ex. : "A")
          set_font(page, @fn_body_bold, font_size + 1.0)
          page.fill_color(@theme.heading_font_color)
          page.text(text, at: {x, y - (font_size + 1.0)})
          y -= (font_size + 1.0) * 1.8
        when :primary
          # Terme principal
          set_font(page, @fn_body, font_size)
          page.fill_color(@theme.base_font_color)
          entry_text = text
          unless pages.empty?
            page_str = format_page_ranges(pages)
            page_str_w = text_width(page_str, @fn_body, font_size)
            # Texte du terme
            page.text(entry_text, at: {x, y - font_size})
            # Numéros de page alignés à droite
            page.fill_color(@theme.index_page_number_color)
            page.text(page_str, at: {x + entry_w - page_str_w, y - font_size})
            page.fill_color(@theme.base_font_color)
          else
            page.text(entry_text, at: {x, y - font_size})
          end
          y -= line_h
        when :secondary
          # Sous-terme (indenté)
          set_font(page, @fn_body, font_size - 0.5)
          page.fill_color(@theme.base_font_color)
          indent = 10.0
          entry_text = text
          page.text(entry_text, at: {x + indent, y - (font_size - 0.5)})
          unless pages.empty?
            page_str = format_page_ranges(pages)
            page_str_w = text_width(page_str, @fn_body, font_size - 0.5)
            page.fill_color(@theme.index_page_number_color)
            page.text(page_str, at: {x + entry_w - page_str_w, y - (font_size - 0.5)})
            page.fill_color(@theme.base_font_color)
          end
          y -= line_h * 0.9
        end
      end
    end

    # Table des matières
    # =========================================================================
    # Rend la table des matières sur la page réservée (index 0-based).
    # La TOC est rendue après le contenu principal pour avoir les numéros de page corrects.
    private def render_toc(
      page_index : Int32,
      y_start : Float64? = nil,
      render_title : Bool = true,
    ) : Nil
      return if @toc_entries.empty?
      return if page_index < 0 || page_index >= @doc.pages.size

      page = @doc.pages[page_index]
      y = y_start || (@page_height - @margin)
      font_size = @theme.toc_font_size
      # Espacement entre les entrées : au moins 1.5x la taille de police
      line_h = font_size * 1.8
      dot_color = @theme.toc_dot_leader_color
      text_color = @theme.base_font_color

      # Titre de la TOC (sauf si l'appelant l'a déjà dessiné — cas
      # `x-title-page-toc` où le sous-titre TOC est rendu avec la mise en
      # forme générale de la page de garde).
      if render_title
        toc_title_size = font_size + 6.0
        set_font(page, @fn_body_bold, toc_title_size)
        page.fill_color(@theme.heading_font_color)
        page.text(@theme.toc_title, at: {@margin, y - toc_title_size})
        y -= toc_title_size * 2.0
      end

      # Entrées de la TOC
      @toc_entries.each do |entry|
        raw_title, level, page_num, dest_name, _top_y = entry
        title = decode_html_entities(raw_title)
        # Indentation : niveau 1 = 0, niveau 2 = 20pt, niveau 3 = 40pt, etc.
        indent = (level - 1) * 20.0
        entry_x = @margin + indent
        entry_w = @content_width - indent

        # Vérifier qu'il reste de la place sur la page
        if y - line_h < @margin
          # La TOC déborde sur une seule page — on s'arrête ici.
          # (Un support multi-page de la TOC pourrait être ajouté ultérieurement.)
          break
        end

        # Texte du titre
        toc_font_name = level <= 1 ? @fn_body_bold : @fn_body
        set_font(page, toc_font_name, font_size)
        page.fill_color(text_color)
        draw_text_run(page, title, entry_x, y - font_size, toc_font_name, font_size)

        # Numéro de page (aligné à droite). Si la numérotation
        # romaine front-matter est active, on doit afficher le numéro
        # *logique* (i, ii, …) ou *arabe* (1, 2, …) selon la zone où
        # tombe la cible. On retrouve la PageMeta correspondante via
        # `page_num` qui est l'index PDF (1-based).
        page_str = page_num.to_s
        if (target_meta = @page_metas.find { |m| m.number == page_num })
          formatted = format_page_number(target_meta)
          page_str = formatted unless formatted.empty?
        end
        page_num_w = text_width(page_str, toc_font_name, font_size)
        page.fill_color(text_color)
        page.text(page_str, at: {@margin + @content_width - page_num_w, y - font_size})

        # Annotation Link : toute la ligne (titre + dots + numéro) est
        # cliquable et navigue vers la destination nommée enregistrée
        # par `convert_section`. Le rectangle est exprimé dans le
        # repère PDF (origine en bas à gauche).
        rect_top = y + 2.0
        rect_bottom = y - font_size - 2.0
        rect_right = @margin + @content_width
        page.link_dest(
          rect: {entry_x, rect_bottom, rect_right, rect_top},
          dest: dest_name,
        )

        # Pointillés entre le titre et le numéro de page
        title_w = text_width(title, toc_font_name, font_size)
        dot_x_start = entry_x + title_w + 4.0
        dot_x_end = @margin + @content_width - page_num_w - 4.0
        if dot_x_end > dot_x_start
          page.fill_color(dot_color)
          dot_spacing = font_size * 0.5
          dot_x = dot_x_start
          while dot_x < dot_x_end
            page.text(".", at: {dot_x, y - font_size})
            dot_x += dot_spacing
          end
        end

        y -= line_h
      end
    end

    # =========================================================================
    # Page de titre
    # =========================================================================

    # Doit-on rendre une page de garde dédiée ? Trois cas :
    #
    #   :title-page:        ⇒ true (forcé)
    #   :title-page: false  ⇒ false (forcé)  — équivalent fonctionnel
    #                         de `:!title-page:` qui n'est pas
    #                         détectable côté asciicrystal (la
    #                         négation ne laisse pas de trace dans
    #                         `attr?`/`attr`, indiscernable de l'absence)
    #   absent              ⇒ défaut du thème (`title_page_enabled`)
    private def title_page_active?(doc : Asciicrystal::Document) : Bool
      raw = doc.attr("title-page")
      case raw
      when nil
        # Défaut aligné sur asciidoctor standard : une page de garde
        # n'est produite QUE pour un livre (`:doctype: book`). Un
        # `article` (doctype par défaut) n'en a pas — son titre est
        # rendu en haut de la première page, suivi directement du
        # contenu. `title_page_enabled` reste un interrupteur maître
        # du thème (permet de tout désactiver, même pour un livre).
        # Pour FORCER une page de garde sur un article : `:title-page:`.
        @theme.title_page_enabled && doc.doctype == "book"
      when "false", "off", "no", "0"
        false
      else
        true # `:title-page:` explicite ⇒ page de garde même en article
      end
    end

    # Rend le doctitle comme un grand titre en haut de la première
    # page de contenu (mode « article » standard d'AsciiDoc : pas de
    # page de garde, juste un titre suivi du préambule).
    # Le logo `:title-logo-image:`, le sous-titre, l'auteur et la date —
    # quand fournis — sont placés autour du titre comme une mini-
    # manchette d'entête.
    private def render_inline_doctitle(doc : Asciicrystal::Document) : Nil
      ensure_page
      page = @current_page.not_nil!

      # Logo en bandeau supérieur, s'il y en a un. Il vit dans la
      # marge de la zone de contenu (au-dessus du titre).
      logo_h = render_title_logo(doc, page, @current_y)
      if logo_h > 0
        @current_y -= logo_h + 14.0
      end

      # Pleine taille du titre (la même que sur une page de garde),
      # pour que le doctitle ait du poids visuel — c'est lui le
      # premier signal d'identité du document.
      title_font_size = @theme.title_font_size
      title_text = TextTransformer.apply(@document_title, @theme.title_page_text_transform)
      # IMPORTANT : forcer le gras *avant* le wrap, pour que la mesure
      # de largeur utilise les métriques d'Helvetica-Bold (plus larges
      # que regular) — sinon le wrap sous-estime et le titre déborde.
      title_segments = force_bold(parse_inline(title_text))
      title_lines = wrap_segments(title_segments, @content_width, title_font_size)
      title_lines = [[] of InlineSegment] if title_lines.empty?
      title_line_height = title_font_size * 1.2

      page.fill_color(@theme.title_font_color)
      align = resolve_title_align(doc)
      title_lines.each_with_index do |line, i|
        x = title_line_x(line, title_font_size, @fn_body_bold, align)
        y = @current_y - title_font_size - (i * title_line_height)
        render_segment_line(page, line, x, y, title_font_size)
      end
      @current_y -= title_lines.size * title_line_height + 4.0

      # Sous-titre éventuel sous le titre. Aligné comme le titre :
      # quand le titre est centré, ses satellites (subtitle, manchette
      # auteur · date) suivent. Cohérence générique.
      # Passage par InlineRenderer + wrap_segments pour que les
      # `pass:[<br>]` injectés par l'utilisateur soient honorés
      # comme sauts de ligne forcés (mêmes mécaniques que le titre).
      if (subtitle = doc.attr("subtitle"))
        sub_size = @theme.subtitle_font_size
        sub_segments = parse_inline(subtitle)
        # Injecter la couleur thème dans chaque segment qui n'en
        # définit pas explicitement — sinon `render_segment_line`
        # retombe sur `base_font_color`.
        sub_segments = sub_segments.map { |s| force_color(s, @theme.subtitle_font_color) }
        sub_lines = wrap_segments(sub_segments, @content_width, sub_size)
        sub_lines = [[] of InlineSegment] if sub_lines.empty?
        sub_lines.each do |line|
          x = title_line_x(line, sub_size, @fn_body, align)
          render_segment_line(page, line, x, @current_y - sub_size, sub_size)
          @current_y -= sub_size * 1.4
        end
      end

      # Bandeau auteur + date sur une ligne, en gris, façon « manchette ».
      # Aligné comme le titre.
      author = doc.attr("author")
      revdate = doc.attr("revdate")
      if author || revdate
        parts = [] of String
        parts << decode_html_entities(author.to_s) if author
        parts << decode_html_entities(revdate.to_s) if revdate
        bandeau = parts.join("  ·  ")
        small = @theme.base_font_size
        bandeau_segs = [InlineSegment.new(text: bandeau)]
        bandeau_x = title_line_x(bandeau_segs, small, @fn_body, align)
        set_font(page, @fn_body, small)
        page.fill_color("888888")
        draw_text_run(page, bandeau, bandeau_x, @current_y - small, @fn_body, small)
        @current_y -= small * 1.4
      end

      # Trait de séparation, comme une page de garde miniature.
      @current_y -= 6.0
      page.stroke_color("cccccc")
      page.line_width(0.6)
      page.line({@margin, @current_y}, {@margin + @content_width, @current_y})
      page.stroke
      @current_y -= 18.0
    end

    # Indique si la TOC doit être rendue sur la page de garde (option 3).
    # Activée par l'attribut AsciiDoc `:x-title-page-toc:` ou la propriété
    # de thème `x_title_page_with_toc`. L'attribut écrase le thème.
    #
    # Extension non standard du shard — préfixe `x-` à la mode des
    # extensions HTTP/MIME pour signaler explicitement l'absence
    # d'équivalent dans AsciiDoc / Ruby asciicrystal-pdf.
    # Résout l'alignement horizontal du titre H1. Cascade :
    #   1. attribut document `:title-page-align: <left|center|right>`
    #   2. propriété de thème `title_page_align`
    #   3. défaut "left"
    private def resolve_title_align(doc : Asciicrystal::Document) : String
      attr = doc.attr("title-page-align")
      case attr.to_s.downcase
      when "left", "center", "right" then attr.to_s.downcase
      else
        case @theme.title_page_align.downcase
        when "center" then "center"
        when "right"  then "right"
        else               "left"
        end
      end
    end

    # Calcule la position x d'une ligne de titre selon l'alignement.
    # Mesure la largeur totale via les métriques de police (les
    # segments image inline sont peu fréquents dans un titre, mais
    # gérés au passage). Pour `:left`, retourne directement `@margin`.
    private def title_line_x(
      line : Array(InlineSegment),
      font_size : Float64,
      font_name : String,
      align : String,
    ) : Float64
      return @margin if align == "left"
      font = get_font(font_name)
      line_w = line.sum do |s|
        if s.image_path
          (s.image_width || (font_size * 1.2)) + 2.0
        else
          font.string_width(s.text, font_size)
        end
      end
      case align
      when "center" then @margin + (@content_width - line_w) / 2
      when "right"  then @margin + @content_width - line_w
      else               @margin
      end
    end

    # Force la couleur d'un segment vers la valeur donnée s'il n'en
    # définit pas explicitement. Permet d'appliquer la couleur thème
    # (subtitle_font_color, etc.) à un segment issu de
    # `InlineRenderer.parse` qui n'a pas de span couleur explicite.
    private def force_color(seg : InlineSegment, color : String) : InlineSegment
      return seg if seg.color
      InlineSegment.new(
        text: seg.text, bold: seg.bold, italic: seg.italic, mono: seg.mono,
        sup: seg.sup, sub: seg.sub, mark: seg.mark, kbd: seg.kbd,
        button: seg.button, menu: seg.menu,
        color: color, link: seg.link,
        image_path: seg.image_path,
        image_width: seg.image_width,
        image_height: seg.image_height,
        line_break: seg.line_break,
      )
    end

    # Force le flag `bold` sur tous les segments d'une ligne de titre.
    # Le doctitle parsé via `InlineRenderer.parse` peut contenir des
    # segments non-gras (texte simple) ; on les met en gras pour
    # respecter la typographie de titre — sans inverser un éventuel
    # `<em>` (italique), `<code>` (mono), etc.
    private def force_bold(line : Array(InlineSegment)) : Array(InlineSegment)
      line.map do |s|
        next s if s.bold || s.line_break
        InlineSegment.new(
          text: s.text, bold: true, italic: s.italic, mono: s.mono,
          sup: s.sup, sub: s.sub, mark: s.mark, kbd: s.kbd,
          button: s.button, menu: s.menu,
          color: s.color, link: s.link,
          image_path: s.image_path,
          image_width: s.image_width,
          image_height: s.image_height,
          line_break: s.line_break,
        )
      end
    end

    private def title_page_toc_enabled?(doc : Asciicrystal::Document) : Bool
      # `x-title-page-toc` (et le défaut de thème `x_title_page_with_toc`)
      # ne décident que de l'EMPLACEMENT de la TOC (sur la page de
      # garde), pas de sa PRÉSENCE. Celle-ci reste gouvernée par
      # l'attribut standard `toc` : un document qui le désactive
      # (`:toc!:`) ne doit avoir AUCUNE table des matières, y compris
      # sur la page de garde. Sans ce garde-fou, un `:toc!:` restait
      # sans effet quand la config globale posait `x-title-page-toc`.
      return false unless doc.attr?("toc")

      attr = doc.attr("x-title-page-toc")
      case attr
      when nil
        @theme.x_title_page_with_toc
      when "false", "off", "no", "0"
        false
      else
        true
      end
    end

    private def render_title_page(doc : Asciicrystal::Document) : Nil
      # Page de garde sans header / footer / footnotes (convention
      # typographique : la page de titre est « nue »).
      # Garde : pas de chrome ET pas de compteur (sinon elle prend
      # la place du « 1 » du contenu et tout décale d'une unité).
      new_page(chrome: false, numbering: :none)

      if title_page_toc_enabled?(doc)
        render_title_page_with_toc(doc)
      else
        render_title_page_standard(doc)
      end
    end

    private def render_title_page_standard(doc : Asciicrystal::Document) : Nil
      page = @current_page.not_nil!
      center_x = @page_width / 2

      # Logo de garde optionnel. Conforme à l'attribut Ruby asciicrystal-pdf
      # `:title-logo-image:` (présent depuis la 2.3) : posé dans la moitié
      # supérieure de la page, centré par défaut. Le titre garde sa
      # position habituelle (mi-hauteur) — les deux ne se chevauchent pas
      # tant que le logo reste raisonnable (~150-250pt de hauteur).
      render_title_logo(doc, page, @page_height - @margin - 20.0)

      # Titre principal — wrap long titles + respect des `<br>` internes
      # (`+\n` AsciiDoc → `<br>` HTML → saut de ligne forcé).
      title = TextTransformer.apply(@document_title, @theme.title_page_text_transform)
      title_font_size = @theme.title_font_size
      page.fill_color(@theme.title_font_color)
      title_y = @page_height * 0.55

      align = resolve_title_align(doc)
      # Forcer le gras avant le wrap : sinon la mesure de largeur
      # utilise Helvetica regular (sous-estime) et le titre déborde.
      title_segments = force_bold(parse_inline(title))
      title_lines = wrap_segments(title_segments, @content_width, title_font_size)
      title_lines = [[] of InlineSegment] if title_lines.empty?
      title_line_height = title_font_size * 1.3

      title_lines.each_with_index do |line, i|
        x = title_line_x(line, title_font_size, @fn_body_bold, align)
        render_segment_line(page, line, x, title_y - (i * title_line_height) - title_font_size, title_font_size)
      end
      title_total_height = title_lines.size * title_line_height

      # Sous-titre — REPLIÉ sur plusieurs lignes si trop long
      # (auparavant rendu en un seul `draw_text_run` qui débordait
      # hors page). Même mécanique que le titre et que le sous-titre
      # du mode inline : parse inline + `wrap_segments` +
      # `render_segment_line`, en suivant l'alignement du titre.
      # Bas du bloc titre+sous-titre, qui détermine la position du
      # séparateur. Sans sous-titre : offset fixe sous le titre.
      title_block_bottom_y = title_y - title_total_height - 30.0
      if (subtitle = doc.attr("subtitle"))
        sub_size = @theme.subtitle_font_size
        sub_segments = parse_inline(subtitle).map { |s| force_color(s, @theme.subtitle_font_color) }
        sub_lines = wrap_segments(sub_segments, @content_width, sub_size)
        sub_y = title_y - title_total_height - 10.0 - sub_size
        sub_lines.each do |line|
          x = title_line_x(line, sub_size, @fn_body, align)
          render_segment_line(page, line, x, sub_y, sub_size)
          sub_y -= sub_size * 1.4
        end
        # Le séparateur passe SOUS la dernière ligne du sous-titre
        # (et non à un offset fixe qui le ferait traverser un
        # sous-titre replié sur plusieurs lignes).
        title_block_bottom_y = sub_y - 2.0
      end

      # Auteur
      if (author = doc.attr("author"))
        set_font(page, @fn_body, @theme.author_font_size)
        page.fill_color(@theme.author_font_color)
        draw_text_run(page, decode_html_entities(author), @margin, @page_height * 0.35, @fn_body, @theme.author_font_size)
      end

      # Date
      if (revdate = doc.attr("revdate"))
        set_font(page, @fn_body, @theme.base_font_size)
        page.fill_color("888888")
        draw_text_run(page, decode_html_entities(revdate), @margin, @page_height * 0.35 - @theme.author_font_size - 8.0, @fn_body, @theme.base_font_size)
      end

      # Ligne de séparation, sous le bloc titre+sous-titre.
      page.stroke_color("cccccc")
      page.line_width(1.0)
      page.line({@margin, title_block_bottom_y}, {@margin + @content_width, title_block_bottom_y})
      page.stroke
    end

    # Mode « page de garde + sommaire » (option `:x-title-page-toc:`).
    # Mise en page :
    #   ┌──────────────────────────┐
    #   │ [logo]                   │  ← haut, optionnel
    #   │ Titre                    │  ← gauche, juste sous logo
    #   │ Sous-titre               │
    #   │ ──────────────────────── │  ← séparateur
    #   │ Sommaire                 │
    #   │ Section A ........ p. N  │  ← rendu en post-traitement
    #   │ Section B ........ p. N  │     par render_toc
    #   │                          │
    #   │ ──────────────────────── │  ← séparateur bas
    #   │ Auteur / Date            │  ← bas
    #   └──────────────────────────┘
    private def render_title_page_with_toc(doc : Asciicrystal::Document) : Nil
      page = @current_page.not_nil!

      # Logo (optionnel) tout en haut.
      logo_top = @page_height - @margin
      logo_h = render_title_logo(doc, page, logo_top)
      cursor_y = logo_top - logo_h
      cursor_y -= 24.0 if logo_h > 0

      # Titre — alignement configurable + support des `<br>` (`+\n`).
      title = TextTransformer.apply(@document_title, @theme.title_page_text_transform)
      title_font_size = @theme.title_font_size
      # Forcer gras avant wrap (cf. render_inline_doctitle pour le rationale).
      title_segments = force_bold(parse_inline(title))
      title_lines = wrap_segments(title_segments, @content_width, title_font_size)
      title_lines = [[] of InlineSegment] if title_lines.empty?
      title_line_height = title_font_size * 1.3

      page.fill_color(@theme.title_font_color)
      align = resolve_title_align(doc)
      title_lines.each_with_index do |line, i|
        x = title_line_x(line, title_font_size, @fn_body_bold, align)
        y = cursor_y - title_line_height + (title_line_height - title_font_size) - (i * title_line_height)
        render_segment_line(page, line, x, y, title_font_size)
      end
      cursor_y -= title_lines.size * title_line_height

      # Sous-titre éventuel.
      if (subtitle = doc.attr("subtitle"))
        cursor_y -= 4.0
        set_font(page, @fn_body, @theme.subtitle_font_size)
        page.fill_color(@theme.subtitle_font_color)
        draw_text_run(page, decode_html_entities(subtitle), @margin, cursor_y - @theme.subtitle_font_size, @fn_body, @theme.subtitle_font_size)
        cursor_y -= @theme.subtitle_font_size * 1.3
      end

      # Séparateur entre l'en-tête de garde et la TOC.
      cursor_y -= 16.0
      page.stroke_color("cccccc")
      page.line_width(1.0)
      page.line({@margin, cursor_y}, {@margin + @content_width, cursor_y})
      page.stroke
      cursor_y -= 18.0

      # Sous-titre « Sommaire » (la même typographie que le titre TOC
      # standard, mais on le rend ici pour qu'il s'inscrive dans la
      # mise en page de la garde).
      toc_title_size = @theme.toc_font_size + 4.0
      set_font(page, @fn_body_bold, toc_title_size)
      page.fill_color(@theme.heading_font_color)
      draw_text_run(page, @theme.toc_title, @margin, cursor_y - toc_title_size, @fn_body_bold, toc_title_size)
      cursor_y -= toc_title_size * 1.6

      # Mémoriser l'état pour le post-rendu : la TOC sera dessinée
      # ici quand `@toc_entries` aura été collectée.
      @title_page_toc_index = @page_number - 1 # PDF index 0-based
      @title_page_toc_y_start = cursor_y

      # Auteur + date en bas de page.
      bottom_y = @margin + 12.0
      if (revdate = doc.attr("revdate"))
        set_font(page, @fn_body, @theme.base_font_size)
        page.fill_color("888888")
        draw_text_run(page, decode_html_entities(revdate), @margin, bottom_y, @fn_body, @theme.base_font_size)
        bottom_y += @theme.base_font_size + 4.0
      end
      if (author = doc.attr("author"))
        set_font(page, @fn_body, @theme.author_font_size)
        page.fill_color(@theme.author_font_color)
        draw_text_run(page, decode_html_entities(author), @margin, bottom_y, @fn_body, @theme.author_font_size)
      end
    end

    # Rend le logo de garde quand `:title-logo-image:` est défini.
    # Format upstream Ruby asciicrystal-pdf, accepté ici à l'identique :
    #
    #     :title-logo-image: image::path/logo.svg[align=center, pdfwidth=200]
    #
    # Le format court `:title-logo-image: path/logo.svg` est aussi
    # accepté (pas d'options ⇒ défauts : centré, largeur 200pt).
    #
    # `y_top` est l'ordonnée du **haut** de l'image (repère PDF, origine
    # en bas-gauche). Attention aux deux conventions d'ancrage des
    # primitives : `page.svg` prend y comme bord SUPÉRIEUR, `page.image`
    # comme bord INFÉRIEUR — d'où le `y_top - logo_h` du chemin bitmap.
    # Retourne la hauteur effectivement consommée par le logo, ou 0.0
    # si rien n'a été dessiné.
    private def render_title_logo(
      doc : Asciicrystal::Document, page : PDF::Page, y_top : Float64,
    ) : Float64
      raw = doc.attr("title-logo-image")
      return 0.0 if raw.nil?
      raw_str = raw.to_s.strip
      return 0.0 if raw_str.empty?

      target, opts = parse_title_logo_macro(raw_str)
      return 0.0 if target.empty?

      image_path = resolve_image_path_str(doc, target)
      return 0.0 unless image_path && File.exists?(image_path)

      pdfwidth = parse_logo_length(opts["pdfwidth"]? || opts["width"]?) || 200.0
      pdfwidth = pdfwidth.clamp(0.0, @content_width)
      align = opts["align"]? || "center"

      begin
        if svg_target?(target)
          svg_data = File.read(image_path)
          parser = @doc.svg_parser_for(svg_data)
          svg_w = parser.width
          svg_h = parser.height
          if vb = parser.viewbox
            svg_w = vb[2] if vb[2] > 0
            svg_h = vb[3] if vb[3] > 0
          end
          ratio = pdfwidth / svg_w
          logo_h = svg_h * ratio
          logo_x = align_logo_x(align, pdfwidth)
          page.svg(svg_data, at: {logo_x, y_top}, width: pdfwidth, height: logo_h)
          logo_h
        else
          img = PDF::Images::Image.load(image_path)
          ratio = pdfwidth / img.width.to_f
          logo_h = img.height.to_f * ratio
          logo_x = align_logo_x(align, pdfwidth)
          # `page.image` ancre l'image par son coin INFÉRIEUR gauche
          # (convention PDF : la matrice `cm` translate en y du bas),
          # alors que `page.svg` ancre par le HAUT. Sans la soustraction
          # de `logo_h`, un logo bitmap était dessiné au-dessus de
          # `y_top` : il empiétait sur la marge et, en tête de page, il
          # était tronqué par le bord supérieur de la feuille.
          page.image(img, at: {logo_x, y_top - logo_h}, width: pdfwidth)
          logo_h
        end
      rescue
        # Logo introuvable / illisible : on laisse la page de garde
        # se rendre sans logo, plutôt que de faire planter la conversion.
        0.0
      end
    end

    # Parse une longueur de mise en page avec unité optionnelle
    # (`4cm`, `40mm`, `1in`, `113pt`, ou nombre nu = points). Renvoie
    # la valeur en POINTS PDF, ou `nil` si non parsable. Sans cette
    # conversion, `pdfwidth=4cm` (forme courante d'asciicrystal-pdf)
    # échouait silencieusement (`"4cm".to_f?` = nil ⇒ largeur par
    # défaut) et le logo était mal dimensionné.
    private def parse_logo_length(s : String?) : Float64?
      return nil unless s
      v = s.strip.downcase
      if v.ends_with?("cm")
        v[0...-2].to_f?.try { |n| n * 28.3464567 }
      elsif v.ends_with?("mm")
        v[0...-2].to_f?.try { |n| n * 2.83464567 }
      elsif v.ends_with?("in")
        v[0...-2].to_f?.try { |n| n * 72.0 }
      elsif v.ends_with?("pt")
        v[0...-2].to_f?
      else
        v.to_f?
      end
    end

    # Parse une valeur d'attribut au format `image::PATH[OPTS]` ou un
    # chemin nu. Retourne `{target, options}`.
    private def parse_title_logo_macro(raw : String) : {String, Hash(String, String)}
      opts = {} of String => String
      s = raw
      # Retire le préfixe de macro image, sous ses DEUX formes :
      #   - `image::cible[…]` (macro bloc, double `:`)
      #   - `image:cible[…]`  (macro inline, simple `:`) ← forme
      #     standard d'asciicrystal-pdf pour `:title-logo-image:`
      # Sans la prise en charge du simple `:`, le préfixe `image:`
      # restait collé au chemin (`image:logo.svg`), la résolution
      # échouait et le logo n'apparaissait pas (échec silencieux).
      if s.starts_with?("image::")
        s = s[7..]
      elsif s.starts_with?("image:")
        s = s[6..]
      end
      if (idx = s.index('['))
        target = s[0...idx]
        body = s[idx + 1..]
        body = body.rchop(']') if body.ends_with?(']')
        body.split(',').each do |kv|
          kv = kv.strip
          next if kv.empty?
          if (eq = kv.index('='))
            opts[kv[0...eq].strip] = kv[eq + 1..].strip
          end
        end
        return {target, opts}
      end
      {s, opts}
    end

    private def resolve_image_path_str(doc : Asciicrystal::Document, target : String) : String?
      return nil if target.empty?
      return target if File.exists?(target)

      # Répertoires candidats pour un chemin relatif, dans l'ordre :
      #   1. `docdir` (répertoire source déclaré),
      #   2. dossier du `docfile` — fallback indispensable car le
      #      safe mode d'asciidoctor VIDE souvent `docdir` (« hidden
      #      in SERVER mode »). Sans ce repli, un `:title-logo-image:`
      #      ou une `image:` à chemin relatif ne se résolvait que si
      #      la commande était lancée depuis le dossier du `.adoc`.
      dirs = [] of String
      if (docdir = doc.attr("docdir")) && !docdir.empty?
        dirs << docdir
      end
      if (docfile = doc.attr("docfile")) && !docfile.empty?
        dirs << File.dirname(docfile)
      end

      dirs.each do |dir|
        candidate = File.join(dir, target)
        return candidate if File.exists?(candidate)
        candidate2 = File.join(dir, "images", target)
        return candidate2 if File.exists?(candidate2)
      end
      nil
    end

    private def align_logo_x(align : String, w : Float64) : Float64
      case align
      when "center" then (@page_width - w) / 2
      when "right"  then @page_width - @margin - w
      else               @margin
      end
    end

    # =========================================================================
    # En-têtes et pieds de page
    # =========================================================================

    private def render_headers_footers : Nil
      return unless @theme.header_enabled || @theme.footer_enabled

      @page_metas.each do |meta|
        # Pages marquées sans chrome (page de garde) : ni header,
        # ni footer, ni footnotes — typographie « nue ».
        next unless meta.chrome

        page_idx = meta.number - 1
        next if page_idx < 0 || page_idx >= @doc.pages.size
        page = @doc.pages[page_idx]

        # Notes de bas de page
        render_page_footnotes(page, meta.number)

        if @theme.footer_enabled
          render_page_footer(page, meta)
        end
        if @theme.header_enabled
          render_page_header(page, meta)
        end
      end
    end

    private def render_page_footer(page : PDF::Page, meta : PageMeta) : Nil
      y = @margin / 2
      font_size = @theme.footer_font_size

      page.stroke_color(@theme.footer_border_color)
      page.line_width(@theme.footer_border_width)
      page.line({@margin, y + @theme.footer_height}, {@margin + @content_width, y + @theme.footer_height})
      page.stroke

      set_font(page, @fn_body, font_size)
      page.fill_color(@theme.footer_font_color)

      l, c, r = footer_templates_for(meta)
      left = resolve_page_vars(l, meta)
      center = resolve_page_vars(c, meta)
      right = resolve_page_vars(r, meta)

      page.text(left, at: {@margin, y + font_size}) unless left.empty?
      page.text(center, at: {@page_width / 2 - 20.0, y + font_size}) unless center.empty?
      page.text(right, at: {@margin + @content_width - 20.0, y + font_size}) unless right.empty?
    end

    private def render_page_header(page : PDF::Page, meta : PageMeta) : Nil
      y = @page_height - @margin / 2
      font_size = @theme.header_font_size

      page.stroke_color(@theme.header_border_color)
      page.line_width(@theme.header_border_width)
      page.line({@margin, y - @theme.header_height}, {@margin + @content_width, y - @theme.header_height})
      page.stroke

      set_font(page, @fn_body, font_size)
      page.fill_color(@theme.header_font_color)

      l, c, r = header_templates_for(meta)
      left = resolve_page_vars(l, meta)
      center = resolve_page_vars(c, meta)
      right = resolve_page_vars(r, meta)

      page.text(left, at: {@margin, y - font_size}) unless left.empty?
      page.text(center, at: {@page_width / 2 - 20.0, y + font_size}) unless center.empty?
      page.text(right, at: {@margin + @content_width - 20.0, y - font_size}) unless right.empty?
    end

    # Choisit les trois zones (left, center, right) du header pour
    # une page donnée, en appliquant l'override recto/verso si
    # défini dans le thème (chaîne non vide). La parité s'évalue sur
    # le numéro PDF (1-based) — page 1 = recto, page 2 = verso, etc.
    # Cohérent avec la convention typographique d'imprimerie où
    # une feuille se plie avec le recto à droite.
    private def header_templates_for(meta : PageMeta) : {String, String, String}
      recto = meta.number.odd?
      l = recto ? @theme.header_recto_left : @theme.header_verso_left
      c = recto ? @theme.header_recto_center : @theme.header_verso_center
      r = recto ? @theme.header_recto_right : @theme.header_verso_right
      {
        l.empty? ? @theme.header_left : l,
        c.empty? ? @theme.header_center : c,
        r.empty? ? @theme.header_right : r,
      }
    end

    private def footer_templates_for(meta : PageMeta) : {String, String, String}
      recto = meta.number.odd?
      l = recto ? @theme.footer_recto_left : @theme.footer_verso_left
      c = recto ? @theme.footer_recto_center : @theme.footer_verso_center
      r = recto ? @theme.footer_recto_right : @theme.footer_verso_right
      {
        l.empty? ? @theme.footer_left : l,
        c.empty? ? @theme.footer_center : c,
        r.empty? ? @theme.footer_right : r,
      }
    end

    private def resolve_page_vars(template : String, meta : PageMeta) : String
      # `{page_number}` affiche le numéro **logique** (compteur roman
      # ou arabic redémarrant à 1 selon la zone), pas l'index PDF
      # absolu. `{page_number_pdf}` reste accessible pour les rares
      # cas où on veut l'index brut.
      displayed = format_page_number(meta)
      # Le doctitle peut contenir des balises HTML inline issues du
      # parser (ex. `<br>` pour `+\n`). Les stripper pour les
      # header/footer où on n'a pas de mécanisme de saut de ligne.
      doctitle_clean = @document_title.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
      template
        .gsub("{page_number}", displayed)
        .gsub("{page_number_pdf}", meta.number.to_s)
        .gsub("{section_title}", meta.section_title)
        .gsub("{document_title}", doctitle_clean)
        # Replace U+00A0 with ASCII space just before the string is
        # handed to `page.text` in header/footer rendering (those
        # paths don't go through `draw_text_run`).
        .gsub('\u00A0', ' ')
    end

    # Rend le numéro de page selon le style de la PageMeta :
    #   :none   → "" (page non numérotée, ex. garde)
    #   :roman  → "i", "ii", "iii", … (front-matter)
    #   :arabic → "1", "2", "3", …    (corps de doc)
    private def format_page_number(meta : PageMeta) : String
      case meta.numbering
      when :none   then ""
      when :roman  then RomanNumeral.format(meta.displayed_number)
      when :arabic then meta.displayed_number.to_s
      else              meta.displayed_number.to_s
      end
    end

    # Calcule `displayed_number` pour chaque PageMeta après que la
    # passe de rendu ait posé toutes les pages. Compteur roman et
    # arabic indépendants, chacun reparti de 1 ; `:none` reste à 0.
    # À appeler avant `render_headers_footers`.
    private def assign_displayed_numbers : Nil
      roman_counter = 0
      arabic_counter = 0
      @page_metas.each do |meta|
        case meta.numbering
        when :none
          meta.displayed_number = 0
        when :roman
          roman_counter += 1
          meta.displayed_number = roman_counter
        else # :arabic
          arabic_counter += 1
          meta.displayed_number = arabic_counter
        end
      end
    end

    # =========================================================================
    # Gestion des pages
    # =========================================================================

    private def new_page(chrome : Bool = true, numbering : Symbol = :arabic) : Nil
      @page_number += 1
      @current_page = @doc.page(@page_width, @page_height) do |p|
        # Le bloc est requis, mais le contenu est ajouté de manière séquentielle.
      end
      @current_y = @page_height - @margin
      @page_metas << PageMeta.new(@page_number, @current_section_title, chrome, numbering)
    end

    private def ensure_page : Nil
      new_page if @current_page.nil?
    end

    private def check_page_break(needed_height : Float64) : Nil
      return unless @current_page
      if @current_y - needed_height < @margin + 20.0
        new_page
        # Re-dessine l'en-tête du tableau en cours sur la nouvelle page. On
        # se désarme le temps du re-rendu : `render_table_row` rappelle
        # `check_page_break`, sinon ce serait une récursion infinie.
        if cb = @repeat_table_header
          @repeat_table_header = nil
          cb.call
          @repeat_table_header = cb
        end
      end
    end

    # =========================================================================
    # Bookmarks PDF (outline)
    # =========================================================================

    # Génère le document outline (bookmarks) à partir des entrées TOC collectées.
    # Chaque section devient un bookmark dans le panneau de navigation, et
    # le clic amène le lecteur précisément au début du titre (et non au
    # haut de la page entière), grâce à la coordonnée Y mémorisée par
    # `convert_section`.
    private def generate_pdf_outline : Nil
      return if @toc_entries.empty?

      @doc.outline.define do |o|
        @toc_entries.each do |entry|
          title, _level, page_num, _dest_name, top_y = entry
          page_idx = page_num - 1
          next if page_idx < 0 || page_idx >= @doc.pages.size

          page_ref = @doc.pages[page_idx].page_reference
          dest = PDF::Destination.xyz(page_ref, top: top_y)

          # Niveaux 1 = sections principales, reste = items plats
          # (une arborescence complète nécessiterait de tracker les niveaux,
          #  on simplifie pour l'instant)
          o.item(title, dest: dest)
        end
      end
    end

    # =========================================================================
    # Écriture du PDF
    # =========================================================================

    private def write_pdf : Nil
      File.write(@output_path, @doc.to_slice)
    end

    private def determine_output_path(doc : Asciicrystal::Document) : String
      if (outfile = doc.attr("outfile"))
        outfile
      elsif (docfile = doc.attr("docfile"))
        File.join(File.dirname(docfile), File.basename(docfile, File.extname(docfile)) + ".pdf")
      else
        "output.pdf"
      end
    end

    # =========================================================================
    # Utilitaires de texte
    # =========================================================================

    # Rend le contenu HTML inline ligne par ligne sur la page PDF courante.
    # Gère le retour à la ligne automatique et le rendu des segments stylisés.
    # Tous les attributs (sup, sub, mark, kbd, button, menu, link, color)
    # sont préservés lors du wrapping — `wrap_segments` clone fidèlement
    # le segment d'origine, là où l'ancienne implémentation locale ne
    # propageait que bold/italic/mono/color/link et perdait les nouveaux.
    private def render_inline_lines(
      page : PDF::Page,
      html : String,
      x : Float64,
      width : Float64,
      font_size : Float64,
      line_h : Float64,
    ) : Nil
      segments = parse_inline(html)
      lines = wrap_segments(segments, width, font_size)
      # Pour justify : on alimente `target_w` (largeur cible) sur
      # toutes les lignes sauf la dernière (la dernière reste
      # alignée à gauche pour ne pas étirer un texte court orphelin).
      # On transmet aussi le `natural_width` exact du composer pour
      # que la justification soit cohérente avec le découpage.
      last_idx = lines.size - 1
      lines.each_with_index do |line, idx|
        line_align = idx == last_idx ? "left" : @theme.base_text_align
        render_segment_line(page, line, x, @current_y - font_size, font_size,
          target_w: width, align: line_align)
        @current_y -= line_h
      end
    end

    # Dessine une image inline (raster ou SVG) à la position courante
    # de la ligne. Hauteur calée sur la taille de police pour donner
    # un comportement « icône inline » par défaut.
    private def render_inline_image(
      seg : InlineSegment,
      img_path : String,
      x : Float64,
      y : Float64,
      font_size : Float64,
    ) : Nil
      page = @current_page.not_nil!
      display_w = seg.image_width || (font_size * 1.2)
      display_h = seg.image_height || display_w
      begin
        if svg_target?(img_path)
          svg_data = File.read(img_path)
          parser = @doc.svg_parser_for(svg_data)
          svg_w = parser.width
          svg_h = parser.height
          if vb = parser.viewbox
            svg_w = vb[2] if vb[2] > 0
            svg_h = vb[3] if vb[3] > 0
          end
          # Ratio préservé si seul width est précisé.
          unless seg.image_height
            display_h = svg_h * (display_w / svg_w)
          end
          # `page.svg` interprète y comme le HAUT du SVG → on offset.
          page.svg(svg_data, at: {x, y + display_h}, width: display_w, height: display_h)
        else
          img = PDF::Images::Image.load(img_path)
          unless seg.image_height
            display_h = img.height.to_f * (display_w / img.width.to_f)
          end
          # `page.image` traite y comme le HAUT — même offset.
          page.image(img, at: {x, y + display_h}, width: display_w)
        end
      rescue ex
        # Fallback : texte alt sans formatage particulier.
        draw_text_run(page, seg.text, x, y, @fn_body, font_size)
      end
    end

    # Découpe un flux de segments inline en lignes selon une largeur
    # donnée. Préserve les attributs de style (gras, italique, mono,
    # couleur, lien) — ce que `wrap_text` ne sait pas faire car il
    # travaille sur du texte brut.
    #
    # Implémentation : délègue à `ParagraphComposer` qui transforme
    # les segments en flux de tokens TeX (Box/Glue/Penalty) puis
    # compose les lignes via un algorithme first-fit. La structure
    # typée prépare le passage à Knuth-Plass + Liang hyphenation
    # (J3). Bénéfice immédiat : les espaces insécables (NBSP) sont
    # absorbés dans la Box voisine et garantis insécables —
    # « deploy : il » ne peut plus être cassé sur le `:`.
    private def wrap_segments(
      segments : Array(InlineSegment),
      width : Float64,
      font_size : Float64,
    ) : Array(Array(InlineSegment))
      # Résout l'hyphenator pour la langue du document.
      # Renvoie `nil` si la langue est inconnue / absente : le
      # composer fonctionne alors sans césure (comportement
      # gracieux, pas d'erreur).
      hyphenator = @document_lang.try { |l| Hyphenation::Loader.for(l) }

      tokens = ParagraphComposer.tokenize(segments, font_size, hyphenator) do |seg, text|
        # Mesure de largeur dans la police résolue du segment, à
        # `font_size` brut (sans ajustement sup/sub/kbd) — conforme
        # au comportement historique de `wrap_segments`.
        #
        # CJK : si le texte est un seul caractère CJK
        # (≥ U+3000) et que `font_cjk` sait le rendre, on mesure
        # avec `font_cjk` plutôt qu'avec la police principale qui
        # retournerait 0 / ε (Noto Sans Latin ne contient pas
        # les glyphes CJK). Cohérent avec la stratégie de rendu
        # qui bascule sur `font_cjk` dans `draw_text_run`.
        base_w = if text.size == 1 && (c = text[0]) && c.ord >= 0x3000 && (cjk_f = font_cjk) && cjk_f.has_glyph?(c)
                   cjk_f.string_width(text, font_size)
                 else
                   get_font(resolve_inline_font(seg)).string_width(text, font_size)
                 end

        # Compensation codespan : le rendu ajoute
        # `codespan_padding_x` à `current_x` après chaque
        # codespan/kbd/button/mark pour que le BG ne touche pas le
        # prochain caractère (cf. `render_segment_line` ligne ~4030).
        # Le composer ne voit pas ce padding et accepte donc des
        # lignes qui débordent de quelques points la marge. On
        # gonfle la mesure de la Box pour anticiper ce padding —
        # conservateur (sur-estime pour les codespans adjacents),
        # mais évite les `margin_overflow` détectés par pdf-audit
        # sur le README beryl (42 occurrences au 2026-06-04 avant
        # ce fix).
        if seg.mono && !seg.kbd && !@theme.codespan_background_color.empty?
          base_w += @theme.codespan_padding_x
        end
        base_w += 4.0 if seg.kbd || seg.button
        base_w += 2.0 if seg.mark

        base_w
      end
      # Knuth-Plass par défaut depuis v2.3.24.82 (2026-06-04) :
      # ré-introduit avec un garde-fou emergency (|adjustment_ratio|
      # > MAX_KP_RATIO ⇒ fallback automatique sur first-fit pour
      # le paragraphe entier). Voir `paragraph_composer.cr`
      # compose_knuth_plass pour la logique du garde-fou.
      ParagraphComposer.compose_knuth_plass(tokens, width).map(&.segments)
    end

    # Rend une ligne de segments inline sur la page PDF.
    # Utilise les métriques exactes des polices pour l'avancement horizontal.
    # Gère sub/sup (taille réduite + décalage Y), mark (fond surligné),
    # kbd (mono + petite police).
    private def render_segment_line(
      page : PDF::Page,
      segments : Array(InlineSegment),
      x : Float64,
      y : Float64,
      font_size : Float64,
      target_w : Float64? = nil,
      align : String = "left",
    ) : Nil
      # Justify : calcule l'espace inutilisé sur la ligne et le
      # distribue entre les espaces inter-mots. Les espaces
      # insécables (U+00A0 — typographie française) ne sont PAS
      # comptés (split sur ' ' seulement), donc le NBSP reste de
      # largeur normale.
      #
      # Garde-fou `max_extra_factor = 2.5` : si l'extra par espace
      # dépasse 2.5× la largeur d'un espace normal, on bascule en
      # alignement gauche pour la ligne. Évite les lignes très
      # étalées (paragraphe court justifié sur une largeur
      # disproportionnée). Cette borne empirique préserve la
      # qualité visuelle des paragraphes typiques tout en bloquant
      # les pathologies — réintroduit lors du revert v2.3.24.81
      # (2026-06-04) après régressions K-P sur le README beryl.
      extra_per_space = 0.0
      max_extra_factor = 2.5
      # `extra_per_cjk_glyph` (v2.3.24.75) : étirement à appliquer
      # entre chaque glyphe CJK quand la ligne ne contient AUCUN
      # espace ASCII (cas typique : « 中文两端对齐 ») mais qu'on
      # doit quand même justifier. Émis via l'opérateur PDF `Tc`
      # (ISO 32000-1 § 9.3.2), convention typographique chinoise/
      # japonaise/coréenne dite « 両端揃え / 两端对齐 ». Tc
      # s'applique à tous les glyphes — pour les lignes mixtes
      # (CJK + latin avec espaces), on conserve l'étirement des
      # espaces ASCII (`extra_per_space` / `Tw` / `TJ`) et le CJK
      # n'est pas étiré entre glyphes.
      extra_per_cjk_glyph = 0.0
      # Calcul de `natural_w` / `n_spaces` est utile dans deux cas :
      # (a) `align == justify` → on étire les espaces ASCII (chemin
      # habituel), (b) la ligne ne contient AUCUN espace ASCII mais
      # est en CJK pur et `target_w` est défini → on étire entre les
      # glyphes CJK via `Tc` (convention typographique 両端揃え,
      # même si la ligne est la dernière du paragraphe — les
      # paragraphes CJK pure sont systématiquement justifiés au
      # bord droit en typographie sino-japonaise).
      needs_metric = (align == "justify" || target_w) && target_w
      if needs_metric && (tw = target_w)
        natural_w = 0.0
        n_spaces = 0
        segments.each_with_index do |seg, seg_idx|
          if seg.image_path
            natural_w += seg.image_width || (font_size * 1.2)
          elsif !seg.text.empty?
            font_name = resolve_inline_font(seg)
            font = get_font(font_name)
            eff_size = seg.sup || seg.sub ? font_size * 0.75 : (seg.kbd ? font_size * 0.9 : font_size)
            # Mesure précise par run : la police principale (Noto
            # Sans Latin) ne contient pas les glyphes CJK et
            # retourne 0 / ε pour eux, ce qui sous-estimait
            # `natural_w` et faussait `extra_per_cjk_glyph` (bloqué
            # par le garde-fou car « candidat » = très grand).
            # On délègue à `text_with_emoji_segments` la
            # segmentation par police et on somme les widths avec
            # la bonne fonte selon le `kind`.
            if seg.text.each_char.any? { |c| c.ord >= 0x3000 } && font_cjk
              softened = seg.text.gsub(' ', ' ')
              text_with_emoji_segments(softened).each do |(kind, val)|
                if kind == :cjk
                  natural_w += font_cjk.not_nil!.string_width(val, eff_size)
                else
                  natural_w += font.string_width(val, eff_size)
                end
              end
            else
              natural_w += font.string_width(seg.text, eff_size)
            end
            n_spaces += seg.text.count(' ')

            # Padding de badge RÉELLEMENT rendu — réplique EXACTE
            # de la condition de rendu (cf. plus bas, « Padding
            # inter-segments pour les badges »). Le padding
            # codespan/kbd/mark n'est ajouté au curseur QUE si le
            # segment suivant ne « colle » pas (ni espace, ni
            # ponctuation finale) ET n'est pas lui-même un mono
            # contigu (fragments d'un codespan coupé). En comptant
            # ici EXACTEMENT les mêmes paddings, `natural_w` égale
            # la largeur effectivement dessinée (notée `R`), donc la
            # justification `extra = (tw - natural_w) / n_spaces`
            # remplit la ligne PILE jusqu'à `target_w`.
            #
            # Si on comptait les paddings INCONDITIONNELLEMENT (comme
            # `tokenize` le fait pour la décision de coupure), on
            # sur-estimerait `natural_w` ⇒ `extra` trop petit ⇒
            # ligne justifiée qui s'arrête AVANT la marge (défaut
            # visuel signalé sur le README beryl). À l'inverse, ne
            # rien compter sous-estimerait ⇒ débordement. Le calcul
            # conditionnel est le seul exact. NB : le composer garde
            # SA mesure gonflée (inconditionnelle) pour casser de
            # façon conservatrice et garantir `R <= target_w`.
            next_seg = segments[seg_idx + 1]?
            next_clings = if (nx = next_seg) && !nx.text.empty?
                            fc = nx.text[0]
                            fc == ' ' || ".,;:!?)]}»".includes?(fc)
                          else
                            true
                          end
            next_is_mono = next_seg && next_seg.mono && !next_seg.kbd
            unless next_clings || next_is_mono
              natural_w += 4.0 if seg.kbd || seg.button
              natural_w += 2.0 if seg.mark
              natural_w += @theme.codespan_padding_x if seg.mono && !seg.kbd
            end
          end
        end
        if n_spaces > 0 && tw > natural_w && align == "justify"
          candidate = (tw - natural_w) / n_spaces
          # Garde-fou max_extra_factor : si l'extra par espace
          # dépasse 2.5× la largeur d'un espace normal de la
          # police de base, on bascule en alignement gauche (la
          # ligne serait visuellement trop étalée). Calibré
          # empiriquement v2.3.24.68 ; réintroduit après le
          # revert J3 du 2026-06-04.
          normal_space_w = get_font(@fn_body).string_width(" ", font_size)
          if candidate <= normal_space_w * max_extra_factor
            extra_per_space = candidate
          end
          # Sinon : extra_per_space reste à 0 → rendu en `left`.
        elsif n_spaces == 0 && tw > natural_w && (cjk_f = font_cjk)
          # Pas d'espace ASCII : tentative justification CJK. On
          # compte les glyphes que la police CJK peut rendre dans
          # la ligne entière, et on calcule un Tc qui les étire à
          # parts égales sur target_w.
          n_cjk = 0
          segments.each do |seg|
            next if seg.image_path
            next if seg.text.empty?
            seg.text.each_char do |c|
              next if c.ord < 0x3000
              n_cjk += 1 if cjk_f.has_glyph?(c)
            end
          end
          if n_cjk > 1
            candidate = (tw - natural_w) / (n_cjk - 1)
            typical_cjk_w = cjk_f.string_width("中", font_size)
            extra_per_cjk_glyph = candidate if candidate <= typical_cjk_w * 0.75
          end
        end
      end

      current_x = x
      segments.each_with_index do |seg, seg_idx|
        # Image inline (raster ou SVG) : route vers `page.svg` ou
        # `page.image` selon l'extension. La taille est calculée à
        # partir des attrs (pdfwidth/width/height) ; à défaut on prend
        # une icône inline ~ taille de la ligne.
        if (img_path = seg.image_path)
          render_inline_image(seg, img_path, current_x, y, font_size)
          img_w = seg.image_width || (font_size * 1.2)
          current_x += img_w + 2.0
          next
        end
        next if seg.text.empty?
        font_name = resolve_inline_font(seg)

        # Sub / sup : taille réduite + décalage Y (sup remonte, sub
        # descend). Kbd : police légèrement réduite pour singulariser.
        eff_font_size = font_size
        eff_y = y
        if seg.sup
          eff_font_size = font_size * 0.75
          eff_y = y + font_size * 0.35
        elsif seg.sub
          eff_font_size = font_size * 0.75
          eff_y = y - font_size * 0.15
        elsif seg.kbd
          eff_font_size = font_size * 0.9
        end

        font = get_font(font_name)
        set_font(page, font_name, eff_font_size)

        # Mesurer d'abord pour dessiner d'éventuels arrière-plans.
        # Pour les segments contenant des chars CJK (issus du
        # tokenize_segment_with_cjk qui split chaque char en Box
        # séparée), on doit mesurer chaque run avec la bonne
        # police — Noto Sans Latin retourne 0 / ε pour les
        # glyphes CJK alors que `font_cjk` (Noto CJK) donne la
        # vraie largeur. Sans cette correction, `current_x`
        # n'avançait pas entre 2 chars CJK et tous les glyphes
        # se superposaient à la même position.
        seg_w = if seg.text.each_char.any? { |c| c.ord >= 0x3000 } && (cjk_meas = font_cjk)
                  total = 0.0
                  text_with_emoji_segments(seg.text).each do |(kind, val)|
                    total += (kind == :cjk ? cjk_meas.string_width(val, eff_font_size) : font.string_width(val, eff_font_size))
                  end
                  total
                else
                  font.string_width(seg.text, eff_font_size)
                end
        before = current_x

        # Le `ParagraphComposer` peut préfixer le texte d'un espace
        # ASCII (rendu de la Glue précédente). Cet espace doit
        # apparaître dans le draw_text final (séparation visuelle
        # entre mots, base de la justification), mais ne doit PAS
        # hériter du fond gris des badges (mark / codespan / kbd /
        # button) — le fond démarre au premier vrai caractère du
        # segment et s'arrête au dernier. On calcule donc un offset
        # `leading_space_w` qui décale les 4 rectangles de fond.
        #
        # J4 (v2.3.24.73) : en mode justify, l'espace de tête est
        # étiré (`extra_per_space`) — on doit décaler `badge_x` du
        # même montant pour que le BG suive le texte effectivement
        # dessiné, sinon le BG est avancé seulement de la largeur
        # naturelle de l'espace alors que le texte est plus loin.
        leading_space_w = seg.text.starts_with?(' ') ? font.string_width(" ", eff_font_size) : 0.0
        extra_for_leading = (leading_space_w > 0 && extra_per_space > 0.0) ? extra_per_space : 0.0
        badge_x = before + leading_space_w + extra_for_leading
        badge_w = seg_w - leading_space_w

        # Mark : surlignage jaune pâle derrière le texte. Le segment
        # garde sa couleur de texte d'origine.
        if seg.mark
          mark_pad = 1.5
          page.fill_color("fff59d") # jaune pastel
          page.rectangle(badge_x - mark_pad, eff_y - 2, badge_w + 2 * mark_pad, eff_font_size + 4)
          page.fill
        end
        # Code inline (codespan) : fond grisé optionnel +
        # bordure optionnelle, à la manière du rendu HTML `<code>`.
        # Conforme à la spec asciicrystal-pdf Ruby — catégorie de
        # thème `codespan_*`. Le badge `kbd` (touche de clavier) est
        # un cas dédié juste en dessous, prioritaire sur codespan.
        if seg.mono && !seg.kbd && !@theme.codespan_background_color.empty?
          px = @theme.codespan_padding_x
          py = @theme.codespan_padding_y
          page.fill_color(@theme.codespan_background_color)
          page.rectangle(badge_x - px, eff_y - py, badge_w + 2 * px, eff_font_size + 2 * py)
          page.fill
          if !@theme.codespan_border_color.empty? && @theme.codespan_border_width > 0.0
            page.stroke_color(@theme.codespan_border_color)
            page.line_width(@theme.codespan_border_width)
            page.rectangle(badge_x - px, eff_y - py, badge_w + 2 * px, eff_font_size + 2 * py)
            page.stroke
          end
        end
        # Kbd : encadré gris clair façon « touche de clavier ».
        if seg.kbd
          kbd_pad_x = 3.0
          kbd_pad_y = 1.0
          page.fill_color("f5f5f5")
          page.rectangle(badge_x - kbd_pad_x, eff_y - kbd_pad_y, badge_w + 2 * kbd_pad_x, eff_font_size + 2 * kbd_pad_y)
          page.fill
          page.stroke_color("cccccc")
          page.line_width(0.4)
          page.rectangle(badge_x - kbd_pad_x, eff_y - kbd_pad_y, badge_w + 2 * kbd_pad_x, eff_font_size + 2 * kbd_pad_y)
          page.stroke
        end
        # Bouton : encadré gris pâle à coins arrondis simulés
        # (rectangle plat — le PDF natif ne fait pas les coins
        # arrondis sans Bezier dédié, on garde simple).
        if seg.button
          page.fill_color("e0e0e0")
          page.rectangle(badge_x - 3, eff_y - 1.5, badge_w + 6, eff_font_size + 3)
          page.fill
        end

        # Choix de la couleur du texte : un codespan peut imposer
        # sa propre couleur (`codespan_font_color`) ; sinon on garde
        # la couleur explicite du segment puis le fallback du thème.
        text_color = if seg.mono && !seg.kbd && !@theme.codespan_font_color.empty?
                       @theme.codespan_font_color
                     else
                       seg.color || @theme.base_font_color
                     end
        page.fill_color(text_color)

        # Justify : pour un segment de texte régulier (sans badge
        # mark/kbd/button/mono), on dessine *mot par mot* en élargissant
        # chaque espace de `extra_per_space`. Les segments avec badge
        # conservent leur dessin compact (le badge a une taille fixe)
        # et l'extra est juste comptabilisé pour `current_x`.
        has_badge = seg.mark || seg.kbd || seg.button || seg.mono
        if extra_per_space > 0.0 && !has_badge && seg.text.includes?(' ')
          # J4.B (v2.3.24.74) : tente d'abord le chemin PDF natif —
          # `Tw` (ISO 32000-1 § 9.3.3) pour les polices simples,
          # `TJ` (§ 9.4.3) avec déplacements explicites pour les
          # polices composites (TTF / CID) où `Tw` ne s'applique pas
          # au byte 32 des codes multi-octets. Une seule opération
          # PDF par segment au lieu d'un `Tj` par mot — flux plus
          # compact et émission conforme à la pratique standard.
          # Fallback sur l'avancement manuel mot-par-mot quand le
          # texte contient des éléments inline mixtes (drapeaux,
          # emojis, runs CJK) qui demandent un dessin segmenté.
          if (advanced = try_native_justified_text(page, seg.text, current_x, eff_y, font_name, eff_font_size, extra_per_space))
            current_x += advanced
          else
            parts = seg.text.split(' ')
            space_w = font.string_width(" ", eff_font_size)
            parts.each_with_index do |part, i|
              if i > 0
                current_x += space_w + extra_per_space
              end
              next if part.empty?
              draw_text_run(page, part, current_x, eff_y, font_name, eff_font_size, cjk_char_spacing: extra_per_cjk_glyph)
              # Mesure de l'avancement : si `part` contient des
              # chars CJK, on splitte par run pour utiliser
              # `font_cjk` sur les glyphes CJK (la police
              # principale Noto Sans Latin retourne 0 / ε pour
              # eux). Bug corrigé : sans ce split, l'avancement
              # était ≈ 0 entre chars CJK et tous les glyphes
              # se superposaient à la même position visuelle.
              part_w = if part.each_char.any? { |c| c.ord >= 0x3000 } && (cjk_part_f = font_cjk)
                         total = 0.0
                         text_with_emoji_segments(part).each do |(kind, val)|
                           total += (kind == :cjk ? cjk_part_f.string_width(val, eff_font_size) : font.string_width(val, eff_font_size))
                         end
                         total
                       else
                         font.string_width(part, eff_font_size)
                       end
              # Pour un run CJK : ajouter aussi le Tc cumulé
              # (étirement entre glyphes appliqué par PDF via Tc).
              if extra_per_cjk_glyph > 0
                cjk_count = part.each_char.count { |c| c.ord >= 0x3000 }
                part_w += (cjk_count - 1) * extra_per_cjk_glyph if cjk_count > 1
              end
              current_x += part_w
            end
          end
        else
          # J4 (v2.3.24.73) : si le segment porte un préfixe espace
          # (rendu de la Glue) ET qu'on est en mode justify
          # (`extra_per_space > 0`), on **étire l'espace de tête
          # AVANT** de dessiner le segment, plutôt que d'ajouter
          # un extra APRÈS via `count(' ')`. Sans ce fix, le
          # segment précédent (souvent un codespan suivi d'une
          # ponctuation collante : `(ex : `code`)`) voyait un gap
          # de `extra_per_space` entre la fin du badge et la
          # ponctuation suivante. Avec ce fix, l'extra est consommé
          # AVANT le texte du segment — le `current_x` à la fin du
          # draw correspond exactement à la fin visuelle du texte,
          # et la ponctuation suivante colle naturellement.
          if extra_per_space > 0.0 && seg.text.starts_with?(' ')
            prefix_w = font.string_width(" ", eff_font_size)
            current_x += prefix_w + extra_per_space
            rest = seg.text[1..]
            draw_text_run(page, rest, current_x, eff_y, font_name, eff_font_size, cjk_char_spacing: extra_per_cjk_glyph)
            current_x += font.string_width(rest, eff_font_size)
            # Espaces internes restants (très rares pour les badges
            # puisque le composer fragmente — mais on couvre).
            internal_spaces = rest.count(' ')
            current_x += extra_per_space * internal_spaces if internal_spaces > 0
          else
            # Route through `draw_text_run` so emojis & unrenderable chars
            # get the same treatment as the rest of the engine.
            draw_text_run(page, seg.text, current_x, eff_y, font_name, eff_font_size, cjk_char_spacing: extra_per_cjk_glyph)
            # Avancement horizontal : la mesure est faite à `eff_font_size`,
            # plus une petite réserve pour kbd/button/mark/mono afin que
            # les encadrés ne se touchent pas du segment suivant.
            current_x = before + seg_w
            current_x += extra_per_space * seg.text.count(' ') if extra_per_space > 0.0
            # Avancement Tc CJK : chaque glyphe CJK consume une
            # largeur de `Tc` supplémentaire (le moteur PDF
            # l'applique après chaque glyphe). Le curseur Crystal
            # doit suivre pour positionner correctement le segment
            # suivant. Le Tc après le dernier glyphe est invisible
            # (offset cursor sans contenu).
            if extra_per_cjk_glyph > 0
              n_cjk_in_seg = seg.text.each_char.count { |c| c.ord >= 0x3000 }
              current_x += n_cjk_in_seg * extra_per_cjk_glyph
            end
          end

          # Padding inter-segments pour les badges : nécessaire quand
          # le segment suivant est un mot ordinaire (sinon le BG/
          # encadré du badge chevaucherait le 1er caractère du mot
          # suivant). À SUPPRIMER quand le suivant commence par un
          # espace (séparation déjà fournie par la Glue rendue) ou
          # par une ponctuation collante (`.,;:!?)]}»`) — sans cette
          # exception, on voit un trou avant la ponctuation, ex.
          # « (ex : `code` ) » au lieu de « (ex : `code`) ».
          next_seg = segments[seg_idx + 1]?
          next_clings = if (n = next_seg) && !n.text.empty?
                          first = n.text[0]
                          first == ' ' || ".,;:!?)]}»".includes?(first)
                        else
                          true # dernier segment de la ligne — pas de padding
                        end
          # Pas de padding entre 2 segments mono adjacents : ils
          # forment visuellement la suite d'un même codespan
          # (cas des fragments produits par
          # `split_at_codespan_hinges` du composer pour la
          # coupure douce des codespans longs type
          # `beryl scan aloli/9783...`). Sans cette exception,
          # un trou de `codespan_padding_x` apparaissait entre
          # `aloli/` et `9783705f-` rendant le codespan illisible.
          next_is_mono = next_seg && next_seg.mono && !next_seg.kbd
          unless next_clings || next_is_mono
            current_x += 4.0 if seg.kbd || seg.button
            current_x += 2.0 if seg.mark
            current_x += @theme.codespan_padding_x if seg.mono && !seg.kbd
          end
        end

        # Annotation lien
        if (link = seg.link) && !link.empty?
          page.link_uri(
            rect: {before, y - 2, current_x, y + font_size},
            uri: link
          )
        end
      end
    end

    # Applique la convention typographique française au texte
    # *avant* parsing inline : un espace ordinaire devant `:`, `;`,
    # `!`, `?`, `»` ou après `«` devient un espace insécable (U+00A0).
    # Activé par la propriété de thème `x_french_typography` (true
    # dans `themes/fr.yml`, false dans le thème par défaut).
    # Empêche les sauts de ligne inopportuns (« 12 :30 » →
    # « 12<NBSP>:30 ») et respecte la règle de l'Imprimerie nationale.
    # Hors-spec asciicrystal-pdf Ruby — extension ALOLI, préfixe `x-`.
    private def apply_french_typography(text : String) : String
      return text unless @theme.x_french_typography
      text
        .gsub(/ ([:;!?»])/, " \\1")
        .gsub(/(«) /, "« ")
    end

    # Wrapper autour de `InlineRenderer.parse` qui applique
    # `apply_french_typography` si la propriété de thème est active.
    private def parse_inline(html : String) : Array(InlineSegment)
      InlineRenderer.parse(apply_french_typography(html))
    end

    # Résout le nom de la police à partir des attributs d'un segment inline.
    # Utilise les polices TTF du thème si disponibles.
    private def resolve_inline_font(seg : InlineSegment) : String
      if seg.mono
        @fn_mono
      elsif seg.bold && seg.italic
        @fn_body_bold_italic
      elsif seg.bold
        @fn_body_bold
      elsif seg.italic
        @fn_body_italic
      else
        @fn_body
      end
    end

    # Décode les entités HTML courantes en leurs caractères Unicode.
    # Couvre les entités nommées et numériques les plus fréquentes.
    private def decode_html_entities(text : String) : String
      text
        .gsub(/&#8217;/, "\u2019") # right single quotation mark
        .gsub(/&#8216;/, "\u2018") # left single quotation mark
        .gsub(/&#8220;/, "\u201C") # left double quotation mark
        .gsub(/&#8221;/, "\u201D") # right double quotation mark
        .gsub(/&#8212;/, "\u2014") # em dash
        .gsub(/&#8211;/, "\u2013") # en dash
        .gsub(/&#8230;/, "\u2026") # ellipsis
        .gsub(/&#39;/, "'")        # apostrophe
        .gsub(/&quot;/, "\"")
        .gsub(/&lt;/, "<")
        .gsub(/&gt;/, ">")
        .gsub(/&amp;/, "&")
        # Non-breaking space: replace with a regular space. The Type1
        # standard fonts used by the inline renderer don't always
        # expose a drawable NBSP glyph, so a real U+00A0 character
        # shows up as a tofu box in the PDF. Swapping it for an
        # ordinary space keeps the layout visually correct at the
        # cost of losing the non-break property.
        .gsub(/&#160;/, " ")
        .gsub(/&nbsp;/, " ")
        .gsub('\u00A0', " ")
        # Collapse newlines / whitespace runs introduced by the HTML
        # paragraph formatting. A bare `\n` would otherwise end up
        # in the drawn string and render as a tofu glyph.
        .gsub(/\s+/, " ")
    end

    # Supprime le markup inline HTML généré par asciidoctor et résout
    # les entités. Délègue au module `Sanitizer` (`sanitizer.cr`),
    # portage 1:1 du `sanitizer.rb` upstream Ruby asciicrystal-pdf.
    #
    # ATTENTION : ce n'est PAS une protection contre XSS. Le shard
    # destiné à la sanitisation de sécurité est `aloli-crystal/sanitizer-html`
    # (voir CRYSTAL-SANITIZER-HTML-SPECS.adoc).
    private def strip_inline_markup(text : String) : String
      Sanitizer.sanitize(text)
    end

    # Charge les polices TTF définies dans le thème.
    # Si aucun chemin n'est défini, les polices Type1 standard sont utilisées.
    private def load_theme_fonts : Nil
      if (path = @theme.base_font_path) && File.exists?(path)
        ttf = @doc.load_font(path)
        @font_body = ttf
        @fn_body = ttf.name
      end
      if (path = @theme.base_font_bold_path) && File.exists?(path)
        ttf = @doc.load_font(path)
        @font_body_bold = ttf
        @fn_body_bold = ttf.name
        @fn_heading = ttf.name
      end
      if (path = @theme.base_font_italic_path) && File.exists?(path)
        ttf = @doc.load_font(path)
        @font_body_italic = ttf
        @fn_body_italic = ttf.name
      end
      if (path = @theme.base_font_bold_italic_path) && File.exists?(path)
        ttf = @doc.load_font(path)
        @font_body_bold_italic = ttf
        @fn_body_bold_italic = ttf.name
      end
      if (path = @theme.mono_font_path) && File.exists?(path)
        ttf = @doc.load_font(path)
        @font_mono = ttf
        @fn_mono = ttf.name
      end
      if (path = @theme.mono_font_bold_path) && File.exists?(path)
        ttf = @doc.load_font(path)
        @font_mono_bold = ttf
        @fn_mono_bold = ttf.name
      end

      # Police CJK optionnelle. Si l'utilisateur a peuplé le cache
      # noto-cjk (via `noto-cjk pull` ou `NotoCjk::Cache.pull`), on
      # mémorise le chemin de la première variante installée. La
      # fonte sera *chargée paresseusement* au premier caractère CJK
      # rencontré dans le document (cf. `font_cjk` plus bas).
      #
      # Bénéfice : un document sans CJK ne paye pas le coût du
      # chargement (les Noto CJK `.otf` font ~15 Mo et leur subset
      # embarqué ~1 Mo ; inutile de l'inclure dans un PDF sans CJK).
      if (cjk_path = NotoCjk.font_path) && File.exists?(cjk_path)
        @cjk_font_path = cjk_path
      end
    end

    # Accesseur paresseux à la police CJK. Charge la fonte au
    # premier appel ; retourne `nil` si aucune fonte n'est dispo
    # (cache vide). Les appels suivants retournent la valeur cachée.
    #
    # Depuis pdf 0.6.4 les fontes OpenType/CFF (`.otf`, format de
    # toutes les Noto CJK) sont supportées nativement : elles sont
    # sous-settées et embarquées en `CIDFontType0`/`FontFile3`. Le
    # `rescue UnsupportedFontFormat` ci-dessous reste comme filet de
    # sécurité pour une fonte réellement corrompue ou d'un flavour
    # sfnt exotique, pas comme chemin nominal du CJK.
    private def font_cjk : PDF::Fonts::TrueTypeFont?
      cached = @font_cjk
      return cached if cached
      return nil if @cjk_load_attempted
      @cjk_load_attempted = true

      path = @cjk_font_path
      return nil unless path && File.exists?(path)

      begin
        ttf = @doc.load_font(path)
        @font_cjk = ttf
        @fn_cjk = ttf.name
        ttf
      rescue ex : PDF::Fonts::TrueTypeFont::UnsupportedFontFormat
        STDERR.puts "Avertissement : police CJK '#{File.basename(path)}' non chargeable (#{ex.message.try(&.lines.first)}). Les caractères CJK seront substitués par '?'."
        nil
      end
    end

    # Applique une police sur la page courante, en utilisant l'objet TTF si disponible.
    # Ceci est nécessaire car page.font(String) ne fonctionne que pour les Type1,
    # alors que page.font(TrueTypeFont) est requis pour les polices TTF.
    private def set_font(page : PDF::Page, font_name : String, size : Float64) : Nil
      ttf = font_object_for(font_name)
      if ttf && ttf.is_a?(PDF::Fonts::TrueTypeFont)
        page.font(ttf, size: size)
      else
        page.font(font_name, size: size)
      end
    end

    # Retourne l'objet police pour la mesure de texte.
    # Utilise les polices TTF chargées si disponibles, sinon les Type1.
    private def get_font(font_name : String) : PDF::Fonts::Base
      # Vérifier d'abord les polices TTF chargées
      case font_name
      when @fn_body             then @font_body || @doc.font("Helvetica")
      when @fn_body_bold        then @font_body_bold || @doc.font("Helvetica-Bold")
      when @fn_body_italic      then @font_body_italic || @doc.font("Helvetica-Oblique")
      when @fn_body_bold_italic then @font_body_bold_italic || @doc.font("Helvetica-BoldOblique")
      when @fn_mono             then @font_mono || @doc.font("Courier")
      when @fn_mono_bold        then @font_mono_bold || @doc.font("Courier-Bold")
      when @fn_heading          then @font_body_bold || @doc.font("Helvetica-Bold")
      else                           @doc.font(font_name)
      end
    end

    # Mesure la largeur d'un texte en points en utilisant les métriques
    # exactes des polices (Type1 ou TrueType). Les drapeaux emoji
    # (paires de regional indicators, rendus comme SVG via
    # flags) comptent pour une largeur fixe dérivée de la
    # taille de police, pas comme les glyphes `.notdef` de la police
    # texte.
    private def text_width(text : String, font_name : String, font_size : Float64) : Float64
      measure_width(text, get_font(font_name), font_size)
    end

    # Même mesure que `text_width` mais prend un objet `PDF::Fonts::Base`
    # déjà résolu. Utilisé en interne par `wrap_text` et
    # `break_long_word`.
    private def measure_width(text : String, font : PDF::Fonts::Base, font_size : Float64) : Float64
      total = 0.0
      InlineFlags.segments(text).each do |(kind, value)|
        total += if kind == :flag
                   InlineFlags.flag_width(font_size)
                 else
                   font.string_width(value, font_size)
                 end
      end
      total
    end

    # Sanitise `text` pour qu'il puisse être rendu par la police
    # actuellement active. Tout caractère sans glyphe est remplacé
    # par `?` et l'auteur est prévenu via STDERR — une seule fois
    # par caractère et par conversion, pour ne pas spammer la
    # sortie quand un même emoji apparaît N fois.
    #
    # Algorithme de couverture :
    #
    # * Si la police active est une `PDF::Fonts::TrueTypeFont`
    #   (typiquement DejaVu Sans embarquée par défaut), on lui
    #   demande directement `has_glyph?(char)`. Cela couvre
    #   correctement Latin étendu, Cyrillique, Grec, Hébreu, Arabe,
    #   les dingbats simples (✓ ✗ ★) — bref tout ce que la police
    #   peut effectivement rendre.
    # * Si la police est Type1 standard (Helvetica, Courier — pas
    #   d'embedding, fallback automatique), on retombe sur le test
    #   WinAnsi statique du module `WinAnsi`.
    #
    # Avant cette logique (v2.3.24.10), on utilisait WinAnsi de
    # façon inconditionnelle, ce qui rejetait à tort les caractères
    # que DejaVu Sans pouvait rendre.
    def safe_text(text : String, font_name : String = @fn_body) : String
      ttf = font_object_for(font_name)
      String.build do |io|
        text.each_char do |char|
          if char_renderable_by?(char, ttf)
            io << char
          else
            io << '?'
            warn_unrenderable(char)
          end
        end
      end
    end

    # Returns true when `char` can be rendered by the given font.
    # `ttf` is `nil` when the font is a Type1 standard (no embedded
    # TrueType available) — in that case we fall back to the
    # static WinAnsi coverage table.
    private def char_renderable_by?(char : Char, ttf : PDF::Fonts::Base?) : Bool
      if ttf && ttf.is_a?(PDF::Fonts::TrueTypeFont)
        ttf.has_glyph?(char)
      else
        WinAnsi.representable?(char)
      end
    end

    # Resolves a font name (string registered in `@fn_*`) to its
    # underlying `PDF::Fonts::Base` instance. Returns `nil` when the
    # font is not a TrueType (i.e. fall back to Type1 + WinAnsi).
    private def font_object_for(font_name : String) : PDF::Fonts::Base?
      case font_name
      when @fn_body             then @font_body
      when @fn_body_bold        then @font_body_bold
      when @fn_body_italic      then @font_body_italic
      when @fn_body_bold_italic then @font_body_bold_italic
      when @fn_mono             then @font_mono
      when @fn_mono_bold        then @font_mono_bold
      when @fn_heading          then @font_body_bold
      else                           nil
      end
    end

    private def warn_unrenderable(char : Char) : Nil
      return if @warned_chars.includes?(char)
      @warned_chars << char
      hex = char.ord.to_s(16).upcase.rjust(4, '0')
      STDERR.puts %(Avertissement : caractère « #{char} » (U+#{hex}) sans glyphe dans la police active, remplacé par « ? » dans le PDF.)
    end

    # Affiche un récapitulatif en fin de conversion quand des
    # caractères ont été substitués par '?'. Suggère les actions
    # disponibles : peupler le cache emojis (couvre les emojis), ou
    # patienter pour un futur shard CJK (couvre les idéogrammes).
    #
    # Le message vise à donner à l'auteur la bonne commande à
    # copier-coller, sans interrompre le flow de la commande
    # (pas de prompt interactif — on respecte les scripts CI).
    private def report_unrenderable_chars : Nil
      return if @warned_chars.empty?

      sample = @warned_chars.first(10).map(&.to_s).join(' ')
      STDERR.puts ""
      STDERR.puts "──────────────────────────────────────────────────────────────"
      STDERR.puts "Bilan : #{@warned_chars.size} caractère(s) substitué(s) par '?' dans le PDF."
      STDERR.puts "Échantillon : #{sample}"
      STDERR.puts ""
      STDERR.puts "Pour rendre les emojis en couleur, peuplez le cache local :"
      STDERR.puts "  emojis pull"
      STDERR.puts ""
      STDERR.puts "Cela téléchargera l'ensemble des SVG Twemoji (~4000, ~18 Mo)"
      STDERR.puts "depuis https://github.com/jdecked/twemoji vers"
      STDERR.puts "  #{Emojis::Cache.dir}"
      STDERR.puts ""
      STDERR.puts "Pour les caractères CJK (idéogrammes chinois, japonais,"
      STDERR.puts "coréens), peuplez le cache noto-cjk :"
      STDERR.puts "  noto-cjk pull               # défaut : Chinois Simplifié"
      STDERR.puts "  noto-cjk pull --variant jp  # Japonais"
      STDERR.puts "  noto-cjk pull --variant all # les 4 variantes"
      STDERR.puts ""
      STDERR.puts "Cache CJK actuel : #{NotoCjk::Cache.dir}"
      STDERR.puts "Variantes installées : #{NotoCjk::Cache.installed.empty? ? "(aucune)" : NotoCjk::Cache.installed.map(&.to_s).join(", ")}"
      STDERR.puts "──────────────────────────────────────────────────────────────"
    end

    # Dessine `text` à la position `(x, y)` sur `page`. Les drapeaux
    # emoji sont rendus comme SVG (via `flags`) au lieu du
    # tofu produit par une police texte standard qui n'a pas de
    # glyphes pour ces codepoints. Le curseur X avance de la largeur
    # exacte de chaque segment (texte ou drapeau) pour que les runs
    # suivants soient positionnés correctement.
    private def draw_text_run(page : PDF::Page, text : String, x : Float64, y : Float64, font_name : String, font_size : Float64, cjk_char_spacing : Float64 = 0.0) : Nil
      font = get_font(font_name)
      cursor = x
      flag_w = InlineFlags.flag_width(font_size)
      flag_h = InlineFlags.flag_height(font_size)

      InlineFlags.segments(text).each do |(kind, value)|
        if kind == :flag
          if (svg_data = CountryFlags.svg(value))
            # `page.svg(at: {x, y})` treats `y` as the top of the SVG
            # bounding box (the renderer flips y internally). To align
            # the flag with the text's x-height, position the top of
            # the flag at `y + flag_h` (so its bottom sits on the
            # baseline, matching the visual height of a capital).
            page.svg(svg_data, at: {cursor, y + flag_h}, width: flag_w, height: flag_h)
          else
            # Fallback : afficher le code ISO en texte quand le drapeau
            # n'est pas disponible (ex : pays invalide ou absent du set).
            page.text("[#{value}]", at: {cursor, y})
          end
          cursor += flag_w
        else
          # Substitue U+00A0 par un espace ASCII au moment du dessin.
          # Le NBSP a été préservé jusqu'ici pour que `wrap_text` ne
          # casse pas dessus (insécabilité conservée) ; l'emit PDF
          # utilise un espace ordinaire pour éviter un tofu avec les
          # polices qui n'ont pas de glyphe NBSP.
          softened = value.gsub('\u00A0', ' ')
          # Coupe la chaîne autour de chaque emoji connu de
          # emojis-lite : le texte plain est rendu via
          # `page.text` (avec sanitize WinAnsi pour les caractères
          # restant hors plage), les emojis comme glyphes SVG
          # alignés sur la baseline (mêmes dimensions qu un
          # drapeau pour rester cohérent visuellement).
          emoji_w = flag_w
          emoji_h = flag_h
          text_with_emoji_segments(softened).each do |(kind2, value2)|
            case kind2
            when :emoji
              if (svg_data = Emojis.svg(value2[0]))
                page.svg(svg_data, at: {cursor, y + emoji_h}, width: emoji_w, height: emoji_h)
                cursor += emoji_w
              else
                printable = safe_text(value2, font_name)
                page.text(printable, at: {cursor, y})
                cursor += font.string_width(printable, font_size)
              end
            when :cjk
              # Bascule temporairement la police courante sur
              # @font_cjk, dessine, puis remet la police principale
              # pour les segments suivants. Le sanitize WinAnsi
              # n'intervient pas — la police CJK couvre par
              # définition les caractères concernés.
              #
              # Si `cjk_char_spacing > 0` (mode justify CJK sans
              # espaces ASCII), on émet via `page.text(..., char_spacing:)`
              # qui pose l'opérateur PDF natif `Tc` (ISO 32000-1
              # § 9.3.2). Le moteur PDF translate le curseur de
              # `glyph_w + cjk_char_spacing` après chaque glyphe.
              # On avance notre curseur Crystal de `string_width +
              # (n - 1) × spacing` pour qu'il pointe à la position
              # *visuelle* finale du dernier glyphe (le Tc ajouté
              # par PDF après le dernier glyphe est invisible — il
              # n'affecte que le prochain Tj/TJ, qui sera reset à
              # 0 par le shard pdf).
              cjk_font = font_cjk.not_nil!
              page.font(cjk_font, size: font_size)
              if cjk_char_spacing > 0
                page.text(value2, at: {cursor, y}, char_spacing: cjk_char_spacing)
                n_chars = value2.size
                cursor += cjk_font.string_width(value2, font_size) + (n_chars - 1) * cjk_char_spacing
              else
                page.text(value2, at: {cursor, y})
                cursor += cjk_font.string_width(value2, font_size)
              end
              # Remet la police principale du run.
              set_font(page, font_name, font_size)
            else
              printable = safe_text(value2, font_name)
              page.text(printable, at: {cursor, y})
              cursor += font.string_width(printable, font_size)
            end
          end
        end
      end
    end

    # Découpe un texte en lignes selon la largeur disponible.
    # Utilise les métriques de police exactes pour le calcul.
    # Les mots qui dépassent seuls la largeur disponible (par exemple un
    # nom propre long dans une colonne étroite) sont découpés caractère
    # Découpe `text` en alternance de segments :text et :emoji selon
    # ce que `emojis` et la police CJK optionnelle
    # reconnaissent. Trois familles de segments :
    #
    #   * `{:text,  "..."}` — texte rendable par la police principale
    #   * `{:emoji, "X"}`   — un emoji rendu en SVG (page.svg)
    #   * `{:cjk,   "..."}` — un run de caractères CJK rendu avec la
    #                         police @font_cjk (uniquement quand
    #                         noto-cjk a une variante en cache)
    #
    # Sans police CJK chargée, les caractères CJK retombent dans
    # `:text` et seront substitués par `?` au sanitize.
    private def text_with_emoji_segments(text : String) : Array({Symbol, String})
      result = [] of {Symbol, String}
      buf = String::Builder.new
      cjk_buf = String::Builder.new
      flush_text = -> {
        unless buf.bytesize == 0
          result << {:text, buf.to_s}
          buf = String::Builder.new
        end
      }
      flush_cjk = -> {
        unless cjk_buf.bytesize == 0
          result << {:cjk, cjk_buf.to_s}
          cjk_buf = String::Builder.new
        end
      }

      # `font_cjk` est chargée paresseusement (cf. accesseur) — on
      # ne tente le chargement que pour un caractère *plausiblement
      # CJK* (ord >= 0x3000 = début de l'espace « CJK Symbols and
      # Punctuation »). En-dessous, on est sur du Latin / typographique
      # européen / ponctuation générique que la fonte CJK ne couvre
      # pas de toute façon — inutile de la charger juste pour s'en
      # rendre compte (et inutile de lever l'avertissement
      # `UnsupportedFontFormat` quand la fonte est un `.otf` CFF).
      text.each_char do |char|
        if Emojis.includes?(char)
          flush_text.call
          flush_cjk.call
          result << {:emoji, char.to_s}
        elsif char.ord >= 0x3000 && !WinAnsi.representable?(char) && (cjk_font = font_cjk) && cjk_font.has_glyph?(char)
          # Le CJK est défini comme : char hors WinAnsi, dans la zone
          # CJK Unicode, et que la police CJK sait rendre. Le test
          # WinAnsi évite de « voler » les caractères Latin que les
          # deux polices connaissent (DejaVu reste la police par
          # défaut pour ceux-là, plus cohérent stylistiquement).
          flush_text.call
          cjk_buf << char
        else
          flush_cjk.call
          buf << char
        end
      end
      flush_text.call
      flush_cjk.call
      result
    end

    # Texte « rendable nativement » par le moteur PDF = sans drapeau
    # pays, sans emoji, sans run CJK. Pour ces textes, on peut
    # déléguer la justification au PDF (`Tw` ou `TJ`) au lieu de
    # passer par `draw_text_run` mot-par-mot. Les éléments inline
    # mixtes nécessitent en effet la pipeline `draw_text_run` qui
    # bascule sur des dessins SVG (drapeaux, emojis) ou sur la
    # police CJK secondaire. La NBSP (U+00A0) est tolérée — elle
    # sera substituée par un espace ASCII au moment de l'émission.
    private def native_renderable?(text : String) : Bool
      flag_segs = InlineFlags.segments(text)
      return false if flag_segs.size != 1 || flag_segs[0][0] != :text
      emoji_segs = text_with_emoji_segments(text.gsub(' ', ' '))
      emoji_segs.size == 1 && emoji_segs[0][0] == :text
    end

    # J4.B (v2.3.24.74) : tente une émission PDF native d'un texte
    # justifié. Renvoie la largeur consommée si succès, `nil` si on
    # doit retomber sur le chemin manuel mot-par-mot.
    #
    # Pour les polices simples (Type1 / AFM standard, ex. Helvetica) :
    # `page.text(content, word_spacing: extra)` émet l'opérateur PDF
    # natif `Tw` (ISO 32000-1 § 9.3.3). Une seule opération par
    # segment, le moteur PDF applique l'extra à chaque octet 0x20.
    #
    # Pour les polices composites (TrueType / CID, Noto Sans etc.) :
    # `Tw` ne s'applique PAS (cf. spec § 9.3.3 « word spacing shall
    # not apply to occurrences of the byte value 32 in multiple-byte
    # codes »). On utilise alors `page.text_positioned(runs)` qui
    # émet l'opérateur `TJ` (§ 9.4.3) avec des déplacements
    # explicites entre chaque mot : `[mot, " ", -delta, mot, …] TJ`.
    # Le delta est négatif en text space units car la convention
    # PDF est d'inverser le signe (déplacement à droite = nombre
    # négatif soustrait à la position).
    #
    # Tests en aval via bbox-extraction : le rendu visuel doit
    # rester identique au chemin manuel mot-par-mot.
    private def try_native_justified_text(
      page : PDF::Page,
      text : String,
      x : Float64,
      y : Float64,
      font_name : String,
      font_size : Float64,
      extra_per_space : Float64,
    ) : Float64?
      return nil unless native_renderable?(text)

      font = get_font(font_name)
      set_font(page, font_name, font_size)
      space_w = font.string_width(" ", font_size)

      # Split sur ESPACE ASCII STRICT (v2.3.24.84 bis — fix
      # débordement `mot<NBSP>:`). Le NBSP (U+00A0) reste DANS
      # les morceaux : il n'est JAMAIS un point de
      # justification. Convention typographique française :
      # seul l'espace ASCII entre deux mots est étirable ; le
      # NBSP entre `mot` et `:` (ou `;`, `!`, `?`) est
      # insécable ET de largeur FIXE.
      #
      # `split_ascii_keep_nbsp` remplace le NBSP par un espace
      # ASCII pour le rendu (glyphe visible) APRÈS le split :
      # sa largeur reste donc naturelle, sans `extra`. Avant ce
      # fix, le `gsub` NBSP→espace était fait AVANT le split, le
      # NBSP devenait un séparateur, et un `extra_tj` était
      # inséré entre `source` et `:` — poussant le `:` de
      # quelques points au-delà de la marge droite (3 cas
      # observés sur le README beryl : `source :`, `il lit`,
      # `via l'API`).
      parts = split_ascii_keep_nbsp(text).map { |p| safe_text(p, font_name) }

      if page.composite_font?
        # TJ array : on émet chaque morceau séparément,
        # entrecoupé d'un espace ASCII puis d'un déplacement
        # `extra_tj`. Seuls les espaces ASCII (jointures
        # inter-morceaux) reçoivent l'`extra` ; les NBSP,
        # désormais inclus DANS les morceaux, gardent leur
        # largeur naturelle.
        extra_tj = -extra_per_space * 1000.0 / font_size
        runs = [] of PDF::Page::TextRun
        parts.each_with_index do |part, i|
          if i > 0
            runs << " "
            runs << extra_tj
          end
          runs << part unless part.empty?
        end
        page.text_positioned(runs, at: {x, y})
      else
        # Police simple : positionnement manuel plutôt que
        # `Tw`. `Tw` (ISO 32000-1 § 9.3.3) s'applique à TOUS
        # les octets 32, y compris les espaces issus du NBSP
        # qu'on vient de convertir — ce qui réintroduirait
        # l'`extra` sur un espace censé être insécable. On
        # dessine chaque morceau et on avance `cx` à la main,
        # en n'ajoutant l'`extra` qu'aux jointures ASCII.
        cx = x
        parts.each_with_index do |part, i|
          cx += space_w + extra_per_space if i > 0
          next if part.empty?
          page.text(part, at: {cx, y})
          cx += font.string_width(part, font_size)
        end
      end

      # Largeur consommée : somme des morceaux (NBSP-espaces
      # naturels inclus) + (space_w + extra) par jointure ASCII.
      n_joins = parts.size - 1
      total_parts = parts.sum { |p| font.string_width(p, font_size) }
      total_parts + (space_w + extra_per_space) * n_joins
    end

    # Split un texte sur les espaces ASCII (U+0020) uniquement,
    # puis remplace les NBSP (U+00A0) restants par des espaces
    # ASCII DANS chaque morceau (pour le rendu — glyphe
    # visible). Le NBSP n'est donc jamais un séparateur de
    # justification : il garde sa largeur naturelle et reste
    # collé à ses voisins (convention `mot<NBSP>:`).
    private def split_ascii_keep_nbsp(text : String) : Array(String)
      text.split(' ').map(&.gsub(' ', ' '))
    end

    # Découpe un texte en lignes selon la largeur disponible.
    # Utilise les métriques de police exactes pour le calcul.
    # Les mots qui dépassent seuls la largeur disponible (par exemple un
    # nom propre long dans une colonne étroite) sont découpés caractère
    # par caractère pour éviter que la cellule déborde visuellement.
    private def wrap_text(text : String, width : Float64, font_size : Float64, font_name : String? = nil) : Array(String)
      font = get_font(font_name || @fn_body)
      space_w = font.string_width(" ", font_size)
      lines = [] of String

      text.split("\n").each do |paragraph|
        words = paragraph.split(" ")
        current_line = ""
        current_width = 0.0

        words.each do |word|
          word_w = measure_width(word, font, font_size)
          sep_w = current_line.empty? ? 0.0 : space_w

          if current_width + sep_w + word_w <= width
            current_line = current_line.empty? ? word : "#{current_line} #{word}"
            current_width += sep_w + word_w
          elsif word_w > width
            # Le mot ne tient pas seul : on le découpe en morceaux qui tiennent.
            lines << current_line unless current_line.empty?
            chunks = break_long_word(word, width, font, font_size)
            # Les n-1 premiers morceaux occupent une ligne complète.
            chunks[0..-2].each { |chunk| lines << chunk } if chunks.size > 1
            current_line = chunks.last
            current_width = measure_width(current_line, font, font_size)
          else
            lines << current_line unless current_line.empty?
            current_line = word
            current_width = word_w
          end
        end
        lines << current_line unless current_line.empty?
      end

      lines.empty? ? [""] : lines
    end

    # Découpe un mot en morceaux dont chacun tient dans `width`.
    # Utilisé par `wrap_text` quand un mot seul dépasse la largeur (par
    # exemple dans des cellules de tableau très étroites).
    #
    # Priorité de césure, du plus lisible au plus brutal :
    # 1. Trait d'union interne : `Pays-Bas` -> `Pays-` + `Bas`.
    # 2. Majuscule interne (camelCase) : `RoyaumeUni` -> `Royaume` + `Uni`.
    # 3. Caractère par caractère, en dernier recours.
    #
    # Les sous-parties peuvent elles-mêmes dépasser `width` : on les
    # réinjecte récursivement dans l'algorithme pour les découper plus
    # finement jusqu'à ce qu'elles tiennent.
    private def break_long_word(word : String, width : Float64, font : PDF::Fonts::Base, font_size : Float64) : Array(String)
      return [word] if font.string_width(word, font_size) <= width

      # 1. Tirets internes : découpe en gardant le tiret sur le morceau de gauche.
      if word.includes?('-') && word.index('-') != 0 && word.index('-') != word.size - 1
        parts = split_keep_separator(word, '-')
        return parts.flat_map { |p| break_long_word(p, width, font, font_size) } if parts.size > 1
      end

      # 2. Majuscules internes (casse mixte type `RoyaumeUni`, `GitHub`).
      parts = split_on_internal_uppercase(word)
      if parts.size > 1
        return parts.flat_map { |p| break_long_word(p, width, font, font_size) }
      end

      # 3. Découpe caractère par caractère.
      chunks = [] of String
      buf = ""
      word.each_char do |c|
        candidate = buf + c
        if !buf.empty? && font.string_width(candidate, font_size) > width
          chunks << buf
          buf = c.to_s
        else
          buf = candidate
        end
      end
      chunks << buf unless buf.empty?
      chunks
    end

    # Découpe `text` sur chaque occurrence de `sep`, en conservant `sep`
    # à la fin du morceau qui le précède. Exemple :
    # `split_keep_separator("Pays-Bas", '-')` -> `["Pays-", "Bas"]`.
    private def split_keep_separator(text : String, sep : Char) : Array(String)
      parts = [] of String
      buf = String::Builder.new
      text.each_char do |c|
        buf << c
        if c == sep
          parts << buf.to_s
          buf = String::Builder.new
        end
      end
      tail = buf.to_s
      parts << tail unless tail.empty?
      parts
    end

    # Découpe `text` aux transitions minuscule -> majuscule (casse mixte
    # interne, type `RoyaumeUni`). Renvoie un tableau singleton si le
    # mot n'a pas de frontière interne exploitable.
    private def split_on_internal_uppercase(text : String) : Array(String)
      return [text] if text.size < 2
      parts = [] of String
      buf = String::Builder.new
      prev : Char? = nil
      text.each_char do |c|
        if (p = prev) && p.lowercase? && c.uppercase?
          parts << buf.to_s
          buf = String::Builder.new
        end
        buf << c
        prev = c
      end
      tail = buf.to_s
      parts << tail unless tail.empty?
      parts
    end
  end
end
