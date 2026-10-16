require "yaml"

module AsciicrystalPDF
  # Erreur levée par `FormBuilder` quand le YAML d'un bloc
  # `[x-form]` est invalide (champ malformé, type inconnu, id
  # dupliqué, etc.).
  class FormError < Exception
  end

  # Construit la représentation interne d'un formulaire `[x-form]`
  # à partir du YAML brut + des attributs du bloc AsciiDoc.
  #
  # Cf. `doc/x-form-spec.adoc` pour la grammaire complète.
  #
  # ## Exemple
  #
  # ```adoc
  # [x-form, id=audit, action=mailto:audit@aloli.fr]
  # ----
  # fields:
  #   - id: nom
  #     type: text
  #     label: Nom
  #     required: true
  # submit:
  #   label: Envoyer
  # ----
  # ```
  #
  # ```
  # form = FormBuilder.parse(yaml, {"id"     => "audit",
  #                                 "action" => "mailto:audit@aloli.fr"})
  # form.id              # => "audit"
  # form.fields[0].label # => "Nom"
  # ```
  module FormBuilder
    # Types de champs supportés. `signature` émet un widget /Sig
    # AcroForm vide (depuis pdf 0.5.9) ; le contenu signé PAdES sera
    # rempli plus tard par `aloli-crystal/pdf-signature` (non livré).
    SUPPORTED_TYPES = %w[
      text email url tel password
      textarea
      number date
      checkbox
      radio select select-multi
      signature
    ]

    # Types qui demandent un attribut `options` (radio, select,
    # select-multi). Une erreur est levée si `options` est manquant
    # ou vide.
    OPTION_TYPES = %w[radio select select-multi]

    # Méthodes HTTP autorisées pour `submit.method`.
    ALLOWED_METHODS = %w[post get mailto]

    # Parse le YAML d'un bloc `[x-form]` et retourne le `Form`
    # résultant. Lève `FormError` sur toute incohérence.
    def self.parse(yaml_content : String, block_attrs : Hash(String, String)) : Form
      root = parse_yaml(yaml_content)

      id = block_attrs["id"]?.try(&.strip)
      raise FormError.new("[x-form] attribut `id=` requis sur le bloc") if id.nil? || id.empty?

      action = block_attrs["action"]?.try(&.strip)
      action = nil if action.try(&.empty?)
      method = block_attrs["method"]?.try(&.strip).try(&.downcase)
      method = nil if method.try(&.empty?)
      if method && !ALLOWED_METHODS.includes?(method)
        raise FormError.new("[x-form] attribut `method=#{method}` invalide. Autorisés : #{ALLOWED_METHODS.join(", ")}")
      end

      read_only_form = block_attrs["read-only"]? == "true"

      title = string_attr(root, "title")
      description = string_attr(root, "description")
      columns = int_attr(root, "columns", default: 1)
      raise FormError.new("[x-form] `columns` doit être ≥ 1 (reçu : #{columns})") if columns < 1

      has_sections = root.as_h?.try(&.has_key?(YAML::Any.new("sections"))) || false
      has_fields = root.as_h?.try(&.has_key?(YAML::Any.new("fields"))) || false
      if has_sections && has_fields
        raise FormError.new("[x-form] `sections:` et `fields:` sont mutuellement exclusifs au niveau racine")
      end
      unless has_sections || has_fields
        raise FormError.new("[x-form] le formulaire doit contenir `sections:` OU `fields:`")
      end

      seen_ids = Set(String).new
      sections, flat_fields =
        if has_sections
          {build_sections(root, seen_ids, default_columns: columns), [] of FormField}
        else
          {[] of Section, build_fields(root["fields"], seen_ids)}
        end

      submit = build_submit(root["submit"]?)
      reset_btn = build_reset(root["reset"]?)
      buttons = build_buttons(root["buttons"]?)

      Form.new(
        id: id,
        action: action,
        method: method || (action ? "post" : nil),
        read_only: read_only_form,
        title: title,
        description: description,
        columns: columns,
        sections: sections,
        fields: flat_fields,
        submit: submit,
        reset: reset_btn,
        buttons: buttons,
      )
    end

    # Parse robuste : YAML cassé → FormError descriptif.
    private def self.parse_yaml(content : String) : YAML::Any
      YAML.parse(content)
    rescue ex : YAML::ParseException
      raise FormError.new("[x-form] YAML invalide : #{ex.message}")
    end

    private def self.string_attr(root : YAML::Any, key : String) : String?
      h = root.as_h?
      return unless h
      v = h[YAML::Any.new(key)]?
      v.try(&.as_s?)
    end

    private def self.int_attr(root : YAML::Any, key : String, *, default : Int32) : Int32
      h = root.as_h?
      return default unless h
      v = h[YAML::Any.new(key)]?
      return default unless v
      v.as_i? || default
    end

    private def self.build_sections(root : YAML::Any, seen_ids : Set(String), *, default_columns : Int32) : Array(Section)
      raw = root["sections"]
      arr = raw.as_a?
      raise FormError.new("[x-form] `sections:` doit être une liste") unless arr

      arr.map_with_index do |sec_yaml, idx|
        sec_h = sec_yaml.as_h?
        raise FormError.new("[x-form] section ##{idx + 1} : doit être un objet (hash)") unless sec_h

        title = sec_h[YAML::Any.new("title")]?.try(&.as_s?)
        description = sec_h[YAML::Any.new("description")]?.try(&.as_s?)
        cols = sec_h[YAML::Any.new("columns")]?.try(&.as_i?) || default_columns
        raise FormError.new("[x-form] section '#{title}' : `columns` doit être ≥ 1 (reçu : #{cols})") if cols < 1

        fields_yaml = sec_h[YAML::Any.new("fields")]?
        raise FormError.new("[x-form] section '#{title}' : `fields:` requis") unless fields_yaml
        fields = build_fields(fields_yaml, seen_ids)

        Section.new(title: title, description: description, columns: cols, fields: fields)
      end
    end

    private def self.build_fields(yaml : YAML::Any, seen_ids : Set(String)) : Array(FormField)
      arr = yaml.as_a?
      raise FormError.new("[x-form] `fields:` doit être une liste") unless arr

      arr.map_with_index do |f_yaml, idx|
        build_field(f_yaml, idx, seen_ids)
      end
    end

    private def self.build_field(yaml : YAML::Any, idx : Int32, seen_ids : Set(String)) : FormField
      h = yaml.as_h?
      raise FormError.new("[x-form] champ ##{idx + 1} : doit être un objet (hash)") unless h

      id = h[YAML::Any.new("id")]?.try(&.as_s?)
      raise FormError.new("[x-form] champ ##{idx + 1} : `id` requis") if id.nil? || id.empty?

      type = h[YAML::Any.new("type")]?.try(&.as_s?)
      raise FormError.new("[x-form] champ '#{id}' : `type` requis") if type.nil? || type.empty?

      unless SUPPORTED_TYPES.includes?(type)
        raise FormError.new("[x-form] champ '#{id}' : type `#{type}` inconnu. Disponibles : #{SUPPORTED_TYPES.join(", ")}")
      end

      if seen_ids.includes?(id)
        raise FormError.new("[x-form] id `#{id}` dupliqué")
      end
      seen_ids << id

      label = h[YAML::Any.new("label")]?.try(&.as_s?)
      required = bool_or_false(h[YAML::Any.new("required")]?)
      read_only = bool_or_false(h[YAML::Any.new("read-only")]?)
      placeholder = h[YAML::Any.new("placeholder")]?.try(&.as_s?)
      help = h[YAML::Any.new("help")]?.try(&.as_s?)
      cols = h[YAML::Any.new("cols")]?.try(&.as_i?) || 1
      raise FormError.new("[x-form] champ '#{id}' : `cols` doit être ≥ 1 (reçu : #{cols})") if cols < 1
      rows = h[YAML::Any.new("rows")]?.try(&.as_i?)
      raise FormError.new("[x-form] champ '#{id}' : `rows` doit être ≥ 1 (reçu : #{rows})") if rows && rows < 1
      value = h[YAML::Any.new("value")]?
      min = h[YAML::Any.new("min")]?
      max = h[YAML::Any.new("max")]?
      step = h[YAML::Any.new("step")]?
      layout = h[YAML::Any.new("layout")]?.try(&.as_s?) # vertical | horizontal (radio)
      validation = h[YAML::Any.new("validation")]?
      warn_conditional_validation(id, validation)

      options = build_options(h[YAML::Any.new("options")]?, id, type)

      FormField.new(
        id: id,
        type: type,
        label: label,
        required: required,
        read_only: read_only,
        placeholder: placeholder,
        help: help,
        cols: cols,
        rows: rows,
        value: value,
        min: min,
        max: max,
        step: step,
        layout: layout,
        validation: validation,
        options: options,
      )
    end

    # Normalise `options:` en `Array(String) | Hash(String, String)`.
    # Lève une erreur si requis (radio/select/select-multi) et absent
    # ou vide, ou si le type YAML est invalide.
    private def self.build_options(yaml : YAML::Any?, field_id : String, type : String) : Array(String) | Hash(String, String)?
      if yaml.nil?
        return unless OPTION_TYPES.includes?(type)
        raise FormError.new("[x-form] champ '#{field_id}' : `options` requis pour type `#{type}`")
      end

      # Liste simple : [A, B, C]
      if arr = yaml.as_a?
        normalized = arr.map do |item|
          item.as_s? || item.raw.to_s
        end
        if normalized.empty?
          if OPTION_TYPES.includes?(type)
            raise FormError.new("[x-form] champ '#{field_id}' : `options` ne peut pas être vide")
          end
          return
        end
        return normalized
      end

      # Hash : {code: label}
      if hsh = yaml.as_h?
        result = {} of String => String
        hsh.each do |k, v|
          k_str = k.as_s? || k.raw.to_s
          v_str = v.as_s? || v.raw.to_s
          result[k_str] = v_str
        end
        if result.empty?
          if OPTION_TYPES.includes?(type)
            raise FormError.new("[x-form] champ '#{field_id}' : `options` ne peut pas être vide")
          end
          return
        end
        return result
      end

      raise FormError.new("[x-form] champ '#{field_id}' : `options` doit être une liste ou un hash, reçu #{yaml.raw.class}")
    end

    private def self.build_submit(yaml : YAML::Any?) : Submit?
      return unless yaml
      h = yaml.as_h?
      raise FormError.new("[x-form] `submit:` doit être un objet (hash)") unless h
      label = h[YAML::Any.new("label")]?.try(&.as_s?) || "Envoyer"
      action = h[YAML::Any.new("action")]?.try(&.as_s?)
      method = h[YAML::Any.new("method")]?.try(&.as_s?).try(&.downcase)
      if method && !ALLOWED_METHODS.includes?(method)
        raise FormError.new("[x-form] `submit.method=#{method}` invalide. Autorisés : #{ALLOWED_METHODS.join(", ")}")
      end
      Submit.new(label: label, action: action, method: method)
    end

    private def self.build_reset(yaml : YAML::Any?) : ResetButton?
      return unless yaml
      h = yaml.as_h?
      raise FormError.new("[x-form] `reset:` doit être un objet (hash)") unless h
      label = h[YAML::Any.new("label")]?.try(&.as_s?) || "Effacer"
      ResetButton.new(label: label)
    end

    private def self.build_buttons(yaml : YAML::Any?) : Array(ActionButton)
      return [] of ActionButton unless yaml
      arr = yaml.as_a?
      raise FormError.new("[x-form] `buttons:` doit être une liste") unless arr
      arr.map_with_index do |b_yaml, idx|
        h = b_yaml.as_h?
        raise FormError.new("[x-form] bouton ##{idx + 1} : doit être un objet (hash)") unless h
        label = h[YAML::Any.new("label")]?.try(&.as_s?)
        raise FormError.new("[x-form] bouton ##{idx + 1} : `label` requis") if label.nil? || label.empty?
        action = h[YAML::Any.new("action")]?.try(&.as_s?)
        raise FormError.new("[x-form] bouton '#{label}' : `action` requis") if action.nil? || action.empty?
        ActionButton.new(label: label, action: action)
      end
    end

    private def self.bool_or_false(yaml : YAML::Any?) : Bool
      return false unless yaml
      v = yaml.raw
      case v
      when Bool   then v
      when String then v == "true" || v == "yes" || v == "1"
      when Int    then v != 0
      else             false
      end
    end

    # Émet un avertissement sur STDERR si l'utilisateur a écrit
    # `required_if` ou `visible_if` (validation conditionnelle —
    # reportée en v2, cf. spec).
    private def self.warn_conditional_validation(field_id : String, validation : YAML::Any?) : Nil
      return unless validation
      h = validation.as_h?
      return unless h
      %w[required_if visible_if].each do |key|
        if h.has_key?(YAML::Any.new(key))
          STDERR.puts "Warning [x-form] champ '#{field_id}' : `validation.#{key}` ignoré (disponible en v2). Cf. doc/x-form-spec.adoc."
        end
      end
    end
  end

  # Un champ d'un formulaire `[x-form]`, normalisé par `FormBuilder`.
  # Tous les attributs sont immuables ; les valeurs spécifiques au
  # type (rows, options, min/max…) sont nil quand non applicables.
  class FormField
    getter id : String
    getter type : String
    getter label : String?
    getter required : Bool
    getter read_only : Bool
    getter placeholder : String?
    getter help : String?
    getter cols : Int32            # span en colonnes
    getter rows : Int32?           # textarea
    getter value : YAML::Any?      # valeur par défaut (YAML raw)
    getter min : YAML::Any?        # number/date
    getter max : YAML::Any?        # number/date
    getter step : YAML::Any?       # number
    getter layout : String?        # radio : vertical|horizontal
    getter validation : YAML::Any? # regex ou hash min/max
    getter options : Array(String) | Hash(String, String)?

    def initialize(
      @id : String,
      @type : String,
      @label : String? = nil,
      @required : Bool = false,
      @read_only : Bool = false,
      @placeholder : String? = nil,
      @help : String? = nil,
      @cols : Int32 = 1,
      @rows : Int32? = nil,
      @value : YAML::Any? = nil,
      @min : YAML::Any? = nil,
      @max : YAML::Any? = nil,
      @step : YAML::Any? = nil,
      @layout : String? = nil,
      @validation : YAML::Any? = nil,
      @options : Array(String) | Hash(String, String)? = nil,
    )
    end

    # Vrai pour radio / select / select-multi.
    def has_options? : Bool
      FormBuilder::OPTION_TYPES.includes?(@type)
    end

    # Codes (valeurs stockées) en ordre déclaration, ou [] si pas
    # d'options.
    def option_codes : Array(String)
      case opts = @options
      when Array(String)        then opts
      when Hash(String, String) then opts.keys
      else                           [] of String
      end
    end

    # Mapping code → label, ou nil si options absentes ou en liste
    # simple.
    def option_labels : Hash(String, String)?
      @options.as?(Hash(String, String))
    end

    # Valeur par défaut comme chaîne, ou nil si absente.
    def value_string : String?
      v = @value
      return unless v
      v.as_s? || v.raw.to_s
    end

    # Valeur par défaut comme liste de chaînes (pour select-multi).
    def value_array : Array(String)?
      v = @value
      return unless v
      if arr = v.as_a?
        return arr.map { |item| item.as_s? || item.raw.to_s }
      end
      if s = v.as_s?
        return [s]
      end
      nil
    end
  end

  # Une section titrée d'un formulaire (alternative aux `fields:` à
  # plat).
  class Section
    getter title : String?
    getter description : String?
    getter columns : Int32
    getter fields : Array(FormField)

    def initialize(
      @title : String? = nil,
      @description : String? = nil,
      @columns : Int32 = 1,
      @fields : Array(FormField) = [] of FormField,
    )
    end
  end

  class Submit
    getter label : String
    getter action : String?
    getter method : String?

    def initialize(@label : String, @action : String? = nil, @method : String? = nil)
    end
  end

  class ResetButton
    getter label : String

    def initialize(@label : String)
    end
  end

  class ActionButton
    getter label : String
    getter action : String

    def initialize(@label : String, @action : String)
    end
  end

  # Représentation complète d'un formulaire `[x-form]` parsé.
  class Form
    getter id : String
    getter action : String?
    getter method : String?
    getter read_only : Bool
    getter title : String?
    getter description : String?
    getter columns : Int32
    getter sections : Array(Section)
    getter fields : Array(FormField)
    getter submit : Submit?
    getter reset : ResetButton?
    getter buttons : Array(ActionButton)

    def initialize(
      @id : String,
      @action : String? = nil,
      @method : String? = nil,
      @read_only : Bool = false,
      @title : String? = nil,
      @description : String? = nil,
      @columns : Int32 = 1,
      @sections : Array(Section) = [] of Section,
      @fields : Array(FormField) = [] of FormField,
      @submit : Submit? = nil,
      @reset : ResetButton? = nil,
      @buttons : Array(ActionButton) = [] of ActionButton,
    )
    end

    # Vrai si le formulaire est organisé en sections.
    def sectioned? : Bool
      !@sections.empty?
    end

    # Itère tous les champs du formulaire, qu'ils soient à plat
    # ou organisés en sections.
    def all_fields : Array(FormField)
      if sectioned?
        @sections.flat_map(&.fields)
      else
        @fields
      end
    end
  end
end
