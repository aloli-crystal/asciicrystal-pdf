require "./asciidoctor_pdf"
require "./asciidoctor_pdf/hyph_cli"
require "option_parser"

# Sous-commande `hyph` : gestion des patterns de césure Liang.
# Court-circuite le parsing OptionParser principal (lui-même
# dédié à la génération PDF).
if ARGV.first? == "hyph"
  AsciidoctorPDF::HyphCli.run(ARGV.size > 1 ? ARGV[1..] : [] of String)
  exit 0
end

input_files = [] of String
output_file = ""
theme_file = ""
sample_mode = false
no_user_config = false
no_open = false
attributes = {} of String => String

# Le parsing peut lever `MissingOption` (option à argument sans son
# argument, p. ex. `-o` seul) ou `InvalidOption` (option inconnue). Sans
# ce rescue, la CLI plantait avec une stack trace brute ; on affiche à
# la place un message clair + un renvoi vers l'aide, et on sort en 1.
begin
  OptionParser.parse do |parser|
    parser.banner = "Usage : crystal-asciidoctor-pdf [options] fichier.adoc [fichier2.adoc …]"
    parser.on("-o FILE", "--out-file FILE", "Fichier de sortie PDF (par défaut : fichier.adoc.pdf)") { |f| output_file = f }
    parser.on("-T NAME", "--theme NAME", "Thème : nom embarqué (#{AsciidoctorPDF::ThemeLoader.builtin_names.join(", ")}) ou chemin YAML") { |f| theme_file = f }
    parser.on("-a ATTR", "--attribute ATTR", "Attribut nom=valeur") do |a|
      parts = a.split("=", 2)
      attributes[parts[0]] = parts.size > 1 ? parts[1] : ""
    end
    parser.on("-N", "--no-user-config", "Ignorer la configuration utilisateur (#{AsciidoctorPDF::UserConfig.expected_dir}/config.yml)") { no_user_config = true }
    parser.on("-n", "--no-open", "Ne PAS ouvrir le PDF (l'ouverture est faite par défaut ; macOS : Aperçu)") { no_open = true }
    parser.on("--sample", "Générer le document de référence (reference.adoc + PDF)") { sample_mode = true }
    parser.on("-h", "--help", "Afficher l'aide") { puts parser; exit 0 }
    parser.on("-v", "--version", "Afficher la version") { puts "crystal-asciidoctor-pdf #{AsciidoctorPDF::VERSION}"; exit 0 }
    parser.unknown_args { |args| input_files = args }
  end
rescue ex : OptionParser::MissingOption | OptionParser::InvalidOption
  STDERR.puts "Erreur : #{ex.message}"
  STDERR.puts "Usage : crystal-asciidoctor-pdf [options] fichier.adoc [fichier2.adoc …]"
  STDERR.puts "Aide  : crystal-asciidoctor-pdf --help"
  exit 1
end

# Chargement de la configuration utilisateur (XDG).
# Court-circuité par `--no-user-config`.
user_config = no_user_config ? AsciidoctorPDF::UserConfig.empty : AsciidoctorPDF::UserConfig.load

# Ouverture du PDF : SYSTÉMATIQUE par défaut. Désactivable pour un run
# via `-n`/`--no-open` (prioritaire), ou de façon persistante via
# `open: false` dans la config utilisateur. `user_config.open` vaut
# `nil` (clé absente ⇒ défaut = ouvrir), `true` ou `false`.
open_after = no_open ? false : (user_config.open != false)

if sample_mode
  # Le fichier de référence est dans crystal-asciidoctor (le shard cœur)
  sample_src = File.join(__DIR__, "..", "lib", "crystal-asciidoctor", "data", "samples", "reference.adoc")
  # Fallback : chercher dans le shard local
  unless File.exists?(sample_src)
    sample_src = File.join(__DIR__, "..", "data", "samples", "reference.adoc")
  end
  sample_dest = File.join(Dir.current, "reference.adoc")
  sample_pdf = File.join(Dir.current, "reference.adoc.pdf")
  File.write(sample_dest, File.read(sample_src))
  theme = AsciidoctorPDF::Theme.new
  options = {"docfile" => sample_dest, "outfile" => sample_pdf} of String => String
  doc = Asciidoctor.load_file(sample_dest, options)
  converter = AsciidoctorPDF::Converter.new("pdf", theme)
  converter.convert(doc)
  puts "Document de référence généré : reference.adoc et reference.adoc.pdf"
  exit 0
end

if input_files.empty?
  STDERR.puts "Erreur : aucun fichier d'entrée spécifié."
  STDERR.puts "Usage : crystal-asciidoctor-pdf [options] fichier.adoc [fichier2.adoc …]"
  exit 1
end

# `-o`/`--out-file` impose UN nom de sortie : incompatible avec
# plusieurs fichiers d'entrée (le second écraserait le PDF du premier).
# Sans `-o`, chaque fichier produit son propre `<nom>.adoc.pdf` — c'est
# ce qui permet `crystal-asciidoctor-pdf *.adoc`.
if !output_file.empty? && input_files.size > 1
  STDERR.puts "Erreur : -o/--out-file ne peut pas servir avec plusieurs fichiers d'entrée."
  STDERR.puts "Sans -o, chaque fichier produit son propre <nom>.adoc.pdf."
  exit 1
end

had_error = false

input_files.each do |input_file|
  unless File.exists?(input_file)
    STDERR.puts "Erreur : le fichier '#{input_file}' n'existe pas."
    had_error = true
    next
  end

  # Convention de nommage : mon_document.adoc => mon_document.adoc.pdf
  # (permet de distinguer facilement les fichiers source et PDF,
  #  et d'éviter toute confusion avec la version Ruby asciidoctor-pdf).
  # En multi-fichiers, `output_file` est forcément vide (cf. garde
  # ci-dessus) : chaque entrée calcule donc son propre nom.
  out_file = output_file.empty? ? File.join(File.dirname(input_file), File.basename(input_file) + ".pdf") : output_file

  options = {"docfile" => input_file, "outfile" => out_file} of String => String

  # Fusion des attributs CLI puis user config dans `options`.
  # Ordre important : les attributs CLI ont la priorité sur le user
  # config ; le document AsciiDoc lui-même peut encore écraser tout ça
  # via `:attribut: valeur` (gestion par Asciidoctor.load).
  attributes.each { |k, v| options[k] = v }
  user_config.merge_into(options)

  # Active `sourcemap` par défaut : chaque bloc parsé porte alors son
  # numéro de ligne source (`node.lineno`), ce qui permet aux
  # avertissements (p. ex. « ligne de code repliée ») de pointer la
  # ligne exacte du fichier `.adoc`. Surchargeable par l'utilisateur
  # via `-a sourcemap=false`.
  options["sourcemap"] = "true" unless options.has_key?("sourcemap")

  # Safe mode `unsafe` par défaut, comme la CLI `asciidoctor` (et NON
  # le défaut API `secure`). Indispensable ici : en mode `secure`/
  # `server`, asciidoctor VIDE `docdir` et relativise `docfile`, si
  # bien que les chemins relatifs (logo de page de garde, images) ne
  # peuvent plus être résolus que depuis le répertoire courant. En
  # `unsafe`, `docdir` est conservé et l'utilisateur — qui génère un
  # PDF depuis SES propres fichiers locaux — retrouve le comportement
  # attendu. Surchargeable via `-a safe=…` ou l'option `safe`.
  options["safe"] = "unsafe" unless options.has_key?("safe")

  begin
    doc = Asciidoctor.load_file(input_file, options)

    # Résolution du thème, par ordre de priorité décroissante :
    #   1. argument CLI `--theme` (nom embarqué OU chemin YAML)
    #   2. attribut document `:pdf-theme:` dans le source AsciiDoc
    #   3. user config `theme:` (XDG)
    #   4. thème par défaut intégré
    theme =
      if !theme_file.empty?
        AsciidoctorPDF::ThemeLoader.resolve(theme_file)
      elsif (pdf_theme = doc.attr("pdf-theme")) && !pdf_theme.to_s.empty?
        AsciidoctorPDF::ThemeLoader.resolve(pdf_theme.to_s)
      elsif (user_theme = user_config.resolve_theme)
        user_theme
      else
        AsciidoctorPDF::Theme.new
      end

    converter = AsciidoctorPDF::Converter.new("pdf", theme)
    converter.convert(doc)

    puts "PDF généré : #{out_file}"

    # `--open` : ouvrir le PDF dans le lecteur par défaut du système.
    # macOS → `open` (Aperçu si c'est le défaut) ; Linux → `xdg-open`.
    # Détaché et non bloquant : la conversion des fichiers suivants
    # (mode `*.adoc`) n'attend pas la fermeture du lecteur. Un échec
    # d'ouverture (lecteur absent) n'interrompt pas le lot.
    if open_after
      opener = {% if flag?(:darwin) %}
                 "open"
               {% elsif flag?(:linux) %}
                 "xdg-open"
               {% else %}
                 nil
               {% end %}
      if opener
        begin
          Process.new(opener, [out_file], output: Process::Redirect::Close, error: Process::Redirect::Close)
        rescue error
          STDERR.puts "Warning : impossible d'ouvrir '#{out_file}' (#{opener}) : #{error.message}"
        end
      else
        STDERR.puts "Warning : --open non supporté sur cette plateforme (ni macOS ni Linux)."
      end
    end
  rescue ex
    # En lot, l'échec d'un fichier ne doit pas interrompre les autres :
    # on signale et on poursuit, avec un code de sortie non nul au final.
    STDERR.puts "Erreur lors de la conversion de '#{input_file}' : #{ex.message}"
    had_error = true
  end
end

exit 1 if had_error
