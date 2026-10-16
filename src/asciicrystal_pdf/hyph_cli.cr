require "http/client"
require "uri"
require "digest/sha256"
require "json"
require "./hyphenation"
require "./hyphenation/manifest"

module AsciicrystalPDF
  # Sous-commande CLI `hyph` : gestion utilisateur des patterns
  # de césure Liang. Modèle d'inspiration : `tlmgr` (TeX Live
  # Manager) — pas de téléchargement automatique au runtime,
  # action toujours explicite, vérification SHA-256 obligatoire
  # contre le manifest embarqué.
  #
  # Spécification complète : `doc/CLI_HYPH_SPEC.adoc`.
  module HyphCli
    # Dossier XDG où sont stockés les patterns installés par
    # l'utilisateur. Suit la convention ALOLI `feedback_xdg_config_convention`.
    XDG_DIR = File.join(
      ENV["XDG_CONFIG_HOME"]? || (ENV["HOME"]? ? "#{ENV["HOME"]}/.config" : "/tmp"),
      "asciicrystal-pdf",
      "hyphenation",
    )

    # TTL du cache `hyph-available.json` : 7 jours (cf. spec).
    AVAILABLE_CACHE_TTL = 7.days

    # Dossier XDG de cache (différent de la conf : XDG_CACHE_HOME).
    # Contient `hyph-available.json`. Résolu dynamiquement à
    # chaque appel pour que les tests puissent piloter
    # `XDG_CACHE_HOME` via env (constante figée = non testable).
    def self.xdg_cache_dir : String
      File.join(
        ENV["XDG_CACHE_HOME"]? || (ENV["HOME"]? ? "#{ENV["HOME"]}/.cache" : "/tmp"),
        "asciicrystal-pdf",
      )
    end

    def self.available_cache_file : String
      File.join(xdg_cache_dir, "hyph-available.json")
    end

    # URL par défaut interrogée par `hyph available` (API GitHub :
    # JSON listing, parsing trivial). L'utilisateur peut override
    # via `CTAN_MIRROR` ou `HYPH_MIRROR`.
    DEFAULT_AVAILABLE_URL = "https://api.github.com/repos/hyphenation/tex-hyphen/contents/hyph-utf8/tex/generic/hyph-utf8/patterns/tex"

    # Refuse silencieusement d'installer un fichier > 1 Mo (anti-DoS).
    MAX_FILE_SIZE = 1_048_576

    # Codes de sortie (cf. spec CLI_HYPH_SPEC.adoc).
    EXIT_OK                 =  0
    EXIT_USAGE              =  2
    EXIT_NOT_FOUND          =  3
    EXIT_NETWORK            =  4
    EXIT_SHA_MISMATCH       =  5
    EXIT_TOO_LARGE          =  6
    EXIT_INVALID_CONTENT    =  7
    EXIT_EMBEDDED_PROTECTED =  8
    EXIT_XDG_READONLY       =  9
    EXIT_MANIFEST_MISSING   = 10

    def self.run(args : Array(String)) : Nil
      sub = args.first?
      rest = args.size > 1 ? args[1..] : [] of String

      case sub
      when nil, "help", "-h", "--help"
        print_help(rest.first?)
      when "list", "ls"
        cmd_list(rest)
      when "available", "av"
        cmd_available(rest)
      when "install", "in"
        cmd_install(rest)
      when "remove", "rm"
        cmd_remove(rest)
      when "update", "up"
        cmd_update(rest)
      when "show", "sh"
        cmd_show(rest)
      else
        STDERR.puts "Erreur : sous-commande `hyph #{sub}` inconnue."
        STDERR.puts "Sous-commandes valides : list, available, install, remove, update, show, help"
        STDERR.puts "Pour l'aide : asciicrystal-pdf hyph help"
        exit EXIT_USAGE
      end
    end

    private def self.print_help(focus : String? = nil) : Nil
      case focus
      when "list", "ls"
        puts <<-HELP
          NAME
              hyph list — liste les patterns de césure disponibles

          SYNOPSIS
              asciicrystal-pdf hyph list [-j|--json]

          OPTIONS
              -j, --json    Sortie JSON parseable
          HELP
      when "available", "av"
        puts <<-HELP
          NAME
              hyph available — liste les patterns publiés sur CTAN

          SYNOPSIS
              asciicrystal-pdf hyph available [-r|--refresh-cache] [-j|--json] [-o|--offline]

          OPTIONS
              -r, --refresh-cache  Ignore le cache local et re-interroge CTAN
              -j, --json           Sortie JSON parseable
              -o, --offline        N'effectue aucune requête réseau (manifest local seul)

          ENVIRONNEMENT
              CTAN_MIRROR / HYPH_MIRROR  URL alternative à interroger (defaut : API GitHub)

          CACHE
              Fichier : #{available_cache_file}
              TTL     : 7 jours
          HELP
      when "install", "in"
        puts <<-HELP
          NAME
              hyph install — installe un pattern depuis CTAN

          SYNOPSIS
              asciicrystal-pdf hyph install <lang> [-s|--sha256 <hash>] [-u|--from <url>] [-f|--force]

          OPTIONS
              -s, --sha256 <hash>  SHA-256 attendu (obligatoire si langue hors manifest)
              -u, --from <url>     URL alternative (défaut : CTAN officiel)
              -f, --force          Écrase un pattern déjà installé

          EXEMPLES
              asciicrystal-pdf hyph install ja
              asciicrystal-pdf hyph install xx --sha256 abc123... --from https://...
          HELP
      else
        puts <<-HELP
          NAME
              hyph — gestion des patterns de césure Liang

          SOUS-COMMANDES
              list       Liste les patterns disponibles (embarqués + installés)
              available  Interroge CTAN pour les patterns téléchargeables
              install    Télécharge et installe un pattern depuis CTAN
              remove     Supprime un pattern installé
              update     Re-télécharge un pattern installé
              show       Affiche les métadonnées d'un pattern
              help       Affiche cette aide (ou détails d'une sous-commande)

          EXEMPLES
              asciicrystal-pdf hyph list
              asciicrystal-pdf hyph install ja
              asciicrystal-pdf hyph remove ja
              asciicrystal-pdf hyph help install
          HELP
      end
    end

    private def self.installed_langs : Array(String)
      return [] of String unless Dir.exists?(XDG_DIR)
      Dir.children(XDG_DIR).compact_map do |f|
        if f.starts_with?("hyph-") && f.ends_with?(".tex")
          f.lchop("hyph-").rchop(".tex")
        end
      end.sort
    end

    private def self.cmd_list(args : Array(String)) : Nil
      json = args.includes?("-j") || args.includes?("--json")
      embedded = Hyphenation::Loader::EMBEDDED.keys.to_a.sort
      installed = installed_langs
      all = (embedded + installed).uniq.sort

      if json
        rows = all.map do |lang|
          src = installed.includes?(lang) ? "user" : "embedded"
          {lang: lang, source: src}
        end
        puts rows.to_json
      else
        printf "%-12s  %-9s  %s\n", "Langue", "Source", "Taille"
        puts "-" * 40
        all.each do |lang|
          if installed.includes?(lang)
            path = File.join(XDG_DIR, "hyph-#{lang}.tex")
            size = File.size(path)
            printf "%-12s  %-9s  %d o\n", lang, "user", size
          elsif embedded.includes?(lang)
            content = Hyphenation::Loader::EMBEDDED[lang]
            printf "%-12s  %-9s  %d o\n", lang, "embarqué", content.bytesize
          end
        end
        puts ""
        puts "#{embedded.size} langues embarquées, #{installed.size} installées."
      end
    end

    private def self.cmd_show(args : Array(String)) : Nil
      lang = args.first?
      unless lang
        STDERR.puts "Erreur : `hyph show` nécessite un argument <lang>."
        exit EXIT_USAGE
      end

      entry = Hyphenation::MANIFEST[lang]?
      installed = installed_langs.includes?(lang)
      embedded = Hyphenation::Loader::EMBEDDED.has_key?(lang)

      if !entry && !installed && !embedded
        STDERR.puts "Erreur : la langue `#{lang}` n'est ni embarquée, ni installée, ni dans le manifest."
        exit EXIT_NOT_FOUND
      end

      puts "Langue       : #{lang}"
      if entry
        puts "URL canonique : #{entry.url}"
        puts "SHA-256       : #{entry.sha256}"
        puts "Taille (man.) : #{entry.size} o"
        puts "Licence       : #{entry.license}"
        puts "Embarquée     : #{entry.embedded ? "oui" : "non"}"
      else
        puts "(pas d'entrée manifest)"
      end
      if installed
        path = File.join(XDG_DIR, "hyph-#{lang}.tex")
        puts "Installée     : #{path} (#{File.size(path)} o)"
      end
      if embedded
        puts "Embarquée     : oui (au build)"
      end
    end

    # URL effective à interroger : `HYPH_MIRROR` puis `CTAN_MIRROR`
    # puis l'API GitHub par défaut (cf. spec). Publique pour les tests.
    def self.available_source_url : String
      ENV["HYPH_MIRROR"]? || ENV["CTAN_MIRROR"]? || DEFAULT_AVAILABLE_URL
    end

    # Décide si le cache `hyph-available.json` est encore valide
    # (présent et plus récent que la TTL). N'inspecte pas le
    # contenu — un fichier corrompu sera re-fetch au pire après
    # une erreur de parsing. Publique pour les tests.
    def self.available_cache_valid? : Bool
      return false unless File.file?(available_cache_file)
      age = Time.utc - File.info(available_cache_file).modification_time
      age < AVAILABLE_CACHE_TTL
    end

    # Récupère la liste brute des langues `hyph-*` disponibles
    # sur la source (API GitHub par défaut). Effectue UNE requête
    # HTTP et écrit la réponse dans le cache. En cas d'erreur, lève
    # une exception : l'appelant gère le fallback / l'exit code.
    #
    # Le résultat est un `Array(String)` de codes langue triés
    # (extrait du nom de fichier `hyph-<lang>.tex`).
    private def self.fetch_available_langs(url : String) : Array(String)
      body = HTTP::Client.get(url) do |response|
        raise "HTTP #{response.status_code} #{response.status_message}" unless response.success?
        response.body_io.gets_to_end
      end
      langs = parse_available_response(body, url)
      Dir.mkdir_p(xdg_cache_dir)
      File.write(available_cache_file, {
        "source"     => url,
        "fetched_at" => Time.utc.to_rfc3339,
        "langs"      => langs,
      }.to_json)
      langs
    end

    # Parse la réponse de la source. Pour l'API GitHub, on attend
    # un tableau d'objets `{name: "hyph-fr.tex", ...}` ; en
    # fallback CTAN (HTML), on scanne les `href="hyph-*.tex"`.
    # Le choix de format est inféré de l'URL (`api.github.com`
    # versus tout le reste). Publique pour les tests.
    def self.parse_available_response(body : String, url : String) : Array(String)
      langs = [] of String

      if url.includes?("api.github.com")
        # Format JSON GitHub : tableau d'objets `name`.
        arr = JSON.parse(body).as_a
        arr.each do |entry|
          name = entry["name"]?.try &.as_s
          next unless name
          if (lang = extract_lang_from_filename(name))
            langs << lang
          end
        end
      else
        # Fallback : scan HTML naïf des `href="hyph-*.tex"`.
        body.scan(/href="(hyph-[a-z0-9-]+\.tex)"/i).each do |m|
          if (lang = extract_lang_from_filename(m[1]))
            langs << lang
          end
        end
      end

      langs.uniq.sort
    end

    # `hyph-fr.tex` → `fr`, `hyph-en-us.tex` → `en-us`,
    # autre chose → `nil`. Publique pour les tests.
    def self.extract_lang_from_filename(name : String) : String?
      return unless name.starts_with?("hyph-") && name.ends_with?(".tex")
      name.lchop("hyph-").rchop(".tex")
    end

    # Lit le cache disque. Retourne `nil` si absent ou corrompu.
    # Publique pour les tests.
    def self.read_cached_langs : Array(String)?
      return unless File.file?(available_cache_file)
      data = JSON.parse(File.read(available_cache_file))
      data["langs"].as_a.map(&.as_s)
    rescue
      nil
    end

    private def self.cmd_available(args : Array(String)) : Nil
      json = false
      offline = false
      refresh = false

      args.each do |arg|
        case arg
        when "-j", "--json"
          json = true
        when "-o", "--offline"
          offline = true
        when "-r", "--refresh-cache"
          refresh = true
        else
          STDERR.puts "Erreur : flag `#{arg}` inconnu pour `hyph available`."
          STDERR.puts "Flags valides : -j/--json, -o/--offline, -r/--refresh-cache."
          exit EXIT_USAGE
        end
      end

      # `--refresh-cache` : on efface le cache disque AVANT le
      # fetch pour garantir un re-fetch même si la requête échoue
      # (l'utilisateur a explicitement demandé à invalider).
      if refresh && File.file?(available_cache_file)
        File.delete(available_cache_file)
      end

      remote_langs = nil.as(Array(String)?)
      warning = nil.as(String?)

      if offline
        # Mode hors-ligne : on n'interroge pas le réseau et on
        # n'utilise pas non plus le cache (la source effective
        # est le manifest embarqué).
        remote_langs = nil
      elsif !refresh && available_cache_valid? && (cached = read_cached_langs)
        # Cache encore frais : lecture sans HTTP.
        remote_langs = cached
      else
        # Pas de cache valable : fetch HTTP. En cas d'erreur, on
        # tombe sur le manifest avec un warning (exit 0 + stderr).
        begin
          remote_langs = fetch_available_langs(available_source_url)
        rescue ex
          warning = "Avertissement : impossible d'interroger #{available_source_url} (#{ex.message}). Repli sur le manifest embarqué."
        end
      end

      installed = installed_langs.to_set
      embedded_langs = Hyphenation::Loader::EMBEDDED.keys.to_set
      manifest_langs = Hyphenation::MANIFEST.keys.to_set

      # Univers des langues à afficher : union des trois sources
      # (CTAN distant + manifest local + langues installées). Si
      # `--offline`, on retire la couche CTAN.
      universe = manifest_langs + installed + embedded_langs
      universe += remote_langs.to_set if remote_langs
      sorted = universe.to_a.sort

      if json
        rows = sorted.map do |lang|
          {
            "lang"     => JSON::Any.new(lang),
            "ctan"     => JSON::Any.new(remote_langs ? remote_langs.includes?(lang) : false),
            "manifest" => JSON::Any.new(manifest_langs.includes?(lang)),
            "local"    => JSON::Any.new(local_status_label(lang, embedded_langs, installed)),
          }
        end
        payload = {
          "source"     => JSON::Any.new(remote_langs ? available_source_url : "offline"),
          "fetched_at" => JSON::Any.new(File.file?(available_cache_file) ? File.info(available_cache_file).modification_time.to_utc.to_rfc3339 : ""),
          "total"      => JSON::Any.new(sorted.size.to_i64),
          "patterns"   => JSON::Any.new(rows.map { |r| JSON::Any.new(r) }),
        }
        puts JSON::Any.new(payload).to_json
        STDERR.puts warning if warning
      else
        STDERR.puts warning if warning
        puts "Patterns hyphenation disponibles (#{sorted.size} langues) :"
        puts ""
        printf "%-12s  %-12s  %-9s  %s\n", "Langue", "Source CTAN", "Manifest", "Local"
        puts "-" * 60
        sorted.each do |lang|
          ctan_col = if remote_langs.nil?
                       "—"
                     elsif remote_langs.includes?(lang)
                       "oui"
                     else
                       "non"
                     end
          manifest_col = manifest_langs.includes?(lang) ? "✓" : "✗"
          local_col = local_status_label(lang, embedded_langs, installed)
          printf "%-12s  %-12s  %-9s  %s\n", lang, ctan_col, manifest_col, local_col
        end
      end
    end

    # Étiquette « local » pour le tableau / JSON : embarqué (au
    # build), installé (XDG), ou absent. Ordre de priorité :
    # installé l'emporte sur embarqué (la couche utilisateur
    # masque la couche binaire).
    private def self.local_status_label(lang : String, embedded : Set(String), installed : Set(String)) : String
      if installed.includes?(lang)
        "installé"
      elsif embedded.includes?(lang)
        "embarqué"
      else
        "absent"
      end
    end

    # Mirror GitHub officiel des patterns hyph-utf8. Stable, sans
    # redirection contrairement à CTAN. Le manifest référence
    # l'URL CTAN canonique pour des raisons documentaires (c'est
    # bien la source officielle), mais en pratique l'install
    # transforme cette URL pour pointer vers GitHub. L'utilisateur
    # peut surcharger via les variables d'environnement
    # `HYPH_MIRROR` ou `CTAN_MIRROR`, ou via `--from` explicit.
    GITHUB_HYPH_MIRROR = "https://raw.githubusercontent.com/hyphenation/tex-hyphen/master/hyph-utf8/tex/generic/hyph-utf8/patterns/tex/"

    # Construit l'URL effective de téléchargement à partir d'une
    # URL canonique (typiquement extraite du manifest). Priorité :
    #
    # 1. `HYPH_MIRROR` env var → préfixe override
    # 2. `CTAN_MIRROR` env var → préfixe override
    # 3. `GITHUB_HYPH_MIRROR` par défaut (CTAN principal renvoie
    #    désormais des 404 sur ces chemins, à confirmer avec
    #    l'équipe hyph-utf8)
    #
    # Le nom de fichier (`hyph-<lang>.tex`) est extrait de l'URL
    # canonique et concaténé au préfixe choisi.
    private def self.resolve_install_url(canonical : String) : String
      filename = canonical.rpartition('/')[2]
      mirror = ENV["HYPH_MIRROR"]? || ENV["CTAN_MIRROR"]? || GITHUB_HYPH_MIRROR
      mirror = mirror + "/" unless mirror.ends_with?('/')
      mirror + filename
    end

    # Télécharge le contenu d'une URL en suivant les redirections
    # HTTP 301 / 302 / 303 / 307 / 308 (jusqu'à `max_redirects`
    # sauts). Stdlib Crystal `HTTP::Client.get` ne suit PAS les
    # redirects automatiquement — or les miroirs CTAN
    # (`mirrors.ctan.org`) répondent typiquement en 307 vers un
    # miroir géographique. Résolution relative des URLs via
    # `URI#resolve` pour gérer les Location header sans schéma.
    private def self.http_get_following_redirects(url : String, max_redirects : Int32 = 5) : String
      current_url = url
      max_redirects.times do |attempt|
        result = HTTP::Client.get(current_url) do |response|
          case response.status_code
          when 200..299
            {body: response.body_io.gets_to_end, next_url: nil}
          when 301, 302, 303, 307, 308
            loc = response.headers["Location"]?
            raise "Redirect (#{response.status_code}) without Location header" unless loc
            absolute = loc.starts_with?("http") ? loc : URI.parse(current_url).resolve(loc).to_s
            {body: nil, next_url: absolute}
          else
            raise "HTTP #{response.status_code} #{response.status_message}"
          end
        end
        if (body = result[:body])
          return body
        end
        if (next_url = result[:next_url])
          current_url = next_url
        end
      end
      raise "Too many redirects (max #{max_redirects}) starting from #{url}"
    end

    private def self.cmd_install(args : Array(String)) : Nil
      lang = nil.as(String?)
      sha256_arg = nil.as(String?)
      from_url = nil.as(String?)
      force = false

      i = 0
      while i < args.size
        case args[i]
        when "-s", "--sha256"
          sha256_arg = args[i + 1]?
          i += 2
        when "-u", "--from"
          from_url = args[i + 1]?
          i += 2
        when "-f", "--force"
          force = true
          i += 1
        else
          lang = args[i] if lang.nil?
          i += 1
        end
      end

      unless lang
        STDERR.puts "Erreur : `hyph install` nécessite un argument <lang>."
        exit EXIT_USAGE
      end

      # Langues exclues du manifest pour cause de licence non
      # déclarée. Sans --force : refus avec message diagnostique
      # en anglais (lingua franca du licensing libre). Avec
      # --force : warning + install procède en utilisant les
      # métadonnées stockées dans EXCLUDED_LANGS (URL + SHA-256
      # vérifié après téléchargement). Ainsi l'utilisateur qui
      # accepte le risque juridique garde le bénéfice de la
      # vérification d'intégrité.
      excluded_entry = nil.as(Hyphenation::ExcludedEntry?)
      if (excluded = Hyphenation::EXCLUDED_LANGS[lang]?) && from_url.nil?
        unless force
          STDERR.puts "Refusing to install `#{lang}`: #{excluded.reason}"
          STDERR.puts ""
          STDERR.puts "If you have independently verified the licensing situation"
          STDERR.puts "and still want to install this language, pass --force (-f)"
          STDERR.puts "to bypass this check. SHA-256 verification will still happen"
          STDERR.puts "against the hash stored in our records:"
          STDERR.puts "  asciicrystal-pdf hyph install #{lang} --force"
          exit EXIT_MANIFEST_MISSING
        end
        STDERR.puts "WARNING: installing `#{lang}` despite undeclared license."
        STDERR.puts "Reason recorded:"
        STDERR.puts "  #{excluded.reason}"
        STDERR.puts ""
        excluded_entry = excluded
      end

      entry = Hyphenation::MANIFEST[lang]?
      expected_sha = sha256_arg || entry.try(&.sha256) || excluded_entry.try(&.sha256)

      unless expected_sha
        STDERR.puts "Erreur : la langue `#{lang}` n'est pas dans le manifest."
        STDERR.puts "Pour installer une langue non manifestée, fournissez `--sha256 <hash>` explicitement."
        exit EXIT_MANIFEST_MISSING
      end

      url = if from_url
              # `--from` : URL exacte fournie par l'utilisateur,
              # pas de résolution mirror.
              from_url
            elsif (canonical = entry.try(&.url) || excluded_entry.try(&.url))
              resolve_install_url(canonical)
            end
      unless url
        STDERR.puts "Erreur : pas d'URL pour `#{lang}` (manifest absent et `--from` non fourni)."
        exit EXIT_USAGE
      end

      target = File.join(XDG_DIR, "hyph-#{lang}.tex")
      if File.exists?(target) && !force
        STDERR.puts "Le pattern `#{lang}` est déjà installé : #{target}"
        STDERR.puts "Utilisez `--force` pour écraser."
        exit EXIT_OK
      end

      puts "Téléchargement de hyph-#{lang}.tex depuis #{url}..."
      content = begin
        http_get_following_redirects(url)
      rescue ex
        STDERR.puts "Erreur réseau : #{ex.message}"
        exit EXIT_NETWORK
      end

      if content.bytesize > MAX_FILE_SIZE
        STDERR.puts "Erreur : fichier trop volumineux (#{content.bytesize} o > #{MAX_FILE_SIZE} o). Possible corruption."
        exit EXIT_TOO_LARGE
      end

      actual_sha = Digest::SHA256.hexdigest(content)
      if actual_sha != expected_sha
        STDERR.puts "Erreur : SHA-256 mismatch."
        STDERR.puts "  attendu : #{expected_sha}"
        STDERR.puts "  obtenu  : #{actual_sha}"
        exit EXIT_SHA_MISMATCH
      end

      unless content.includes?("\\patterns{") || content.includes?("\\hyphenation{")
        STDERR.puts "Erreur : fichier invalide (pas de bloc \\patterns ou \\hyphenation)."
        exit EXIT_INVALID_CONTENT
      end

      Dir.mkdir_p(XDG_DIR)
      File.write(target, content)
      puts "✓ Installé : #{target} (#{content.bytesize} o)"
    end

    private def self.cmd_remove(args : Array(String)) : Nil
      lang = args.first?
      unless lang
        STDERR.puts "Erreur : `hyph remove` nécessite un argument <lang>."
        exit EXIT_USAGE
      end

      if Hyphenation::Loader::EMBEDDED.has_key?(lang) && !installed_langs.includes?(lang)
        STDERR.puts "Erreur : la langue `#{lang}` est embarquée au build et ne peut pas être supprimée."
        exit EXIT_EMBEDDED_PROTECTED
      end

      path = File.join(XDG_DIR, "hyph-#{lang}.tex")
      unless File.exists?(path)
        STDERR.puts "Erreur : la langue `#{lang}` n'est pas installée."
        exit EXIT_NOT_FOUND
      end

      File.delete(path)
      puts "✓ Supprimé : #{path}"
    end

    private def self.cmd_update(args : Array(String)) : Nil
      installed = installed_langs
      target_langs = args.empty? ? installed : args
      target_langs.each do |lang|
        unless installed.includes?(lang)
          STDERR.puts "Skip `#{lang}` : non installé."
          next
        end
        cmd_install([lang, "--force"])
      end
    end
  end
end
