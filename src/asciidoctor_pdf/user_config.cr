require "yaml"

module AsciidoctorPDF
  # Configuration utilisateur persistante, lue depuis un répertoire
  # XDG-compatible (`$XDG_CONFIG_HOME/crystal-asciidoctor-pdf/`,
  # défaut `~/.config/crystal-asciidoctor-pdf/`).
  #
  # Permet de fixer une fois pour toutes des préférences
  # (thème par défaut, attributs AsciiDoc systématiques, identité
  # auteur) sans avoir à les répéter dans chaque document.
  #
  # Cascade de priorité (de la plus forte à la plus faible) :
  #
  #   1. Flags CLI (`-T`, `-a`, ...)
  #   2. Attributs du document `.adoc` (`:pdf-theme:`, ...)
  #   3. **User config** (ce fichier)
  #   4. Defaults compilés dans le shard
  #
  # Convention XDG : voir
  # https://specifications.freedesktop.org/basedir-spec/
  #
  # Format attendu (`config.yml`) :
  #
  # ```yaml
  # # Thème par défaut. Peut être :
  # #   - un nom embarqué (ex : "fr")
  # #   - un nom de fichier dans ./themes/ (ex : "aloli")
  # #   - un chemin absolu vers un .yml
  # theme: fr
  #
  # # Attributs AsciiDoc injectés par défaut
  # attributes:
  #   x-title-page-toc: true
  #   toc: macro
  #   toclevels: 3
  #   sectnums: true
  #   pdf-page-size: A4
  #   source-highlighter: rouge
  #
  # # Méta auteur (renseignées dans les attributs si non
  # # déjà définies par le document)
  # author: Philippe Nénert
  # email: philippe@aloli.fr
  # organization: ALOLI sas
  # ```
  class UserConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    # Nom du répertoire de configuration sous XDG_CONFIG_HOME.
    SHARD_NAME = "crystal-asciidoctor-pdf"

    # Nom du fichier principal de configuration.
    CONFIG_FILENAME = "config.yml"

    # Sous-répertoire pour les thèmes utilisateurs.
    THEMES_DIR = "themes"

    @[YAML::Field(key: "theme")]
    getter theme : String? = nil

    @[YAML::Field(key: "attributes")]
    getter attributes : Hash(String, String) = {} of String => String

    @[YAML::Field(key: "author")]
    getter author : String? = nil

    @[YAML::Field(key: "email")]
    getter email : String? = nil

    @[YAML::Field(key: "organization")]
    getter organization : String? = nil

    # Ouverture automatique du PDF généré dans le lecteur par défaut.
    # L'ouverture est SYSTÉMATIQUE par défaut : `nil` (clé absente) ⇒
    # on ouvre. Mettre `open: false` pour la désactiver de façon
    # persistante (utile en CI / poste sans interface). Le flag CLI
    # `-n`/`--no-open` désactive ponctuellement (prioritaire sur la
    # config).
    @[YAML::Field(key: "open")]
    getter open : Bool? = nil

    # Répertoire où vit la configuration courante (issu de
    # `UserConfig.find_dir`, ou `nil` si aucun n'a été trouvé).
    # Sert à résoudre les thèmes utilisateurs (sous `themes/`).
    @[YAML::Field(ignore: true)]
    property base_dir : String? = nil

    # Constructeur d'instance vide (aucun fichier trouvé).
    def self.empty : UserConfig
      from_yaml("{}")
    end

    # Calcule le répertoire XDG attendu pour ce shard, sans vérifier
    # son existence. C'est l'emplacement *canonique* à documenter à
    # l'utilisateur.
    def self.expected_dir : String
      base = ENV["XDG_CONFIG_HOME"]?.try(&.strip)
      base = nil if base.try(&.empty?)
      base ||= File.join(home_dir, ".config")
      File.join(base, SHARD_NAME)
    end

    # Cherche le répertoire de config existant, ou nil si absent.
    def self.find_dir : String?
      dir = expected_dir
      Dir.exists?(dir) ? dir : nil
    end

    # Charge la config depuis le répertoire XDG ; retourne une
    # config vide si le fichier n'existe pas. Erreurs de parsing
    # remontées en STDERR — la config vide est utilisée en
    # secours pour ne pas bloquer la génération.
    def self.load : UserConfig
      dir = find_dir
      return empty unless dir

      config_path = File.join(dir, CONFIG_FILENAME)
      unless File.exists?(config_path)
        cfg = empty
        cfg.base_dir = dir
        return cfg
      end

      cfg = from_yaml(File.read(config_path))
      cfg.base_dir = dir
      cfg
    rescue ex
      STDERR.puts "Warning : impossible de charger #{File.join(find_dir.to_s, CONFIG_FILENAME)} : #{ex.message}"
      empty
    end

    # Vrai si la config a un thème par défaut OU des attributs OU
    # une identité auteur. Sert à savoir si quelque chose va être
    # injecté.
    def empty? : Bool
      @theme.nil? && @attributes.empty? && @author.nil? && @email.nil? && @organization.nil?
    end

    # Résout le thème déclaré dans `theme:` :
    #
    #   1. chemin absolu (si commence par `/` ou `~`)
    #   2. nom de fichier dans `<base_dir>/themes/<name>.yml`
    #   3. nom embarqué (`fr`, `english`, ...)
    #   4. fallback : `ThemeLoader.resolve` (qui retournera le
    #      thème par défaut si rien ne matche)
    #
    # Retourne `nil` si aucun `theme:` n'est déclaré.
    def resolve_theme : Theme?
      name = @theme
      return nil unless name && !name.empty?

      # 1. Chemin absolu
      if name.starts_with?('/') || name.starts_with?('~')
        path = name.starts_with?('~') ? name.sub("~", UserConfig.home_dir) : name
        return ThemeLoader.load(path)
      end

      # 2. Thème utilisateur dans <base_dir>/themes/<name>.yml
      if (dir = @base_dir)
        candidate = File.join(dir, THEMES_DIR, "#{name}.yml")
        return ThemeLoader.load(candidate) if File.exists?(candidate)
      end

      # 3 + 4. Builtin ou fallback
      ThemeLoader.resolve(name)
    end

    # Construit la liste d'attributs à injecter dans les options
    # `Asciidoctor.load`. Les attributs explicites du document
    # (passés via `cli_options`) ne sont pas écrasés.
    #
    # Les valeurs `Bool` YAML sont converties en chaînes
    # `"true"` / `"false"` car les options AsciiDoc sont des
    # `Hash(String, String)`.
    def merge_into(target : Hash(String, String)) : Nil
      @attributes.each do |k, v|
        target[k] = soft(v.to_s) unless target.has_key?(k)
      end

      # Méta auteur — uniquement si non déjà fournies par le doc
      if (a = @author) && !a.empty? && !target.has_key?("author")
        target["author"] = soft(a)
      end
      if (e = @email) && !e.empty? && !target.has_key?("email")
        target["email"] = soft(e)
      end
      if (o = @organization) && !o.empty? && !target.has_key?("organization")
        target["organization"] = soft(o)
      end
    end

    # Marque une valeur d'attribut comme SOFT-SET (suffixe `@`,
    # convention asciidoctor) : la config globale fournit ainsi des
    # DÉFAUTS que l'en-tête du document peut surcharger. Sans le `@`,
    # l'attribut serait verrouillé (`attribute_overrides` côté
    # parser) et un document ne pourrait pas le redéfinir — c'est ce
    # qui faisait qu'un `:toc!:` dans un `.adoc` restait sans effet
    # quand la config posait `toc: macro`. Idempotent.
    private def soft(value : String) : String
      value.ends_with?('@') ? value : "#{value}@"
    end

    # Répertoire HOME, avec un fallback raisonnable si la variable
    # n'est pas définie (cas exotique : conteneur sans HOME).
    def self.home_dir : String
      ENV["HOME"]? || "/"
    end
  end
end
