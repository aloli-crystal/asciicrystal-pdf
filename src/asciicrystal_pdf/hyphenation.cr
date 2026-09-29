require "./hyphenation/manifest"

module AsciicrystalPDF
  # Implémentation de l'algorithme **Liang** d'hyphenation par
  # patterns : Franklin Mark Liang, *Word Hy-phen-a-tion by
  # Com-pu-ter*, thèse Stanford, 1983.
  #
  # Le principe : pour chaque langue, un fichier `hyph-<lang>.tex`
  # contient une liste de patterns courts (~ 4000 pour l'anglais,
  # ~ 1500 pour le français) qui mêlent lettres et chiffres :
  #
  #     1ba   → si « ba » apparaît, score 1 *avant* le 'b'
  #     ab3a  → si « aba » apparaît, score 3 *entre* le 'b' et le 2e 'a'
  #     .ad4d → si « add » apparaît en début de mot, score 4 entre 'd' et 'd'
  #
  # Les patterns sont stockés dans un trie. Pour hyphéner un mot
  # `w`, on encadre `w` de `.`, on parcourt toutes les
  # sous-chaînes, on collecte le score maximal à chaque position,
  # et on retient les positions où le score est **impair**.
  # Liang impose en plus une contrainte de marges :
  # `LEFT_MIN = 2` (pas de coupure dans les 2 premières lettres)
  # et `RIGHT_MIN = 3` (pas de coupure dans les 3 dernières) —
  # valeurs par défaut TeX.
  #
  # Le bloc `\hyphenation{…}` du fichier liste des **exceptions**
  # (mots dont la césure ne suit pas les patterns) : ils
  # court-circuitent le trie. Format : `syl-la-bus` → mot
  # « syllabus » avec positions de césure [3, 5].
  module Hyphenation
    # Marges TeX par défaut : pas de césure dans les 2 premières
    # lettres du mot, ni dans les 3 dernières. Ces valeurs sont
    # paramétrables par langue via `\lefthyphenmin` /
    # `\righthyphenmin` dans le source TeX, mais en pratique
    # 2/3 est le compromis universel et nous restons dessus.
    LEFT_MIN  = 2
    RIGHT_MIN = 3

    # Trie de patterns Liang. Chaque nœud porte des `values` :
    # un tableau d'entiers de longueur `chars.size + 1` où
    # `values[i]` est le score appliqué *entre* la (i-1)-ième et
    # la i-ième lettre du pattern (i = 0 → avant la 1re lettre,
    # i = size → après la dernière).
    class Trie
      class Node
        property children = {} of Char => Node
        property values : Array(Int32)? = nil
      end

      getter root = Node.new

      # Insère un pattern brut (ex. `1ba`, `.ad4d`, `âm5e`).
      def insert(pattern : String) : Nil
        chars = [] of Char
        values = [] of Int32
        prev_was_digit = false
        pattern.each_char do |c|
          if c.in?('0'..'9')
            values << (c.ord - '0'.ord)
            prev_was_digit = true
          else
            values << 0 unless prev_was_digit
            chars << c
            prev_was_digit = false
          end
        end
        values << 0 unless prev_was_digit

        node = @root
        chars.each do |c|
          node.children[c] ||= Node.new
          node = node.children[c]
        end
        node.values = values
      end

      # Calcule les scores Liang pour chaque position dans
      # `.word.` (mot encadré). Retourne un tableau de taille
      # `framed.size + 1` où `scores[i]` est le score à la
      # frontière entre `framed[i-1]` et `framed[i]`.
      def scores_for(word : String) : Array(Int32)
        framed = ".#{word.downcase}."
        chars = framed.chars
        n = chars.size
        scores = Array.new(n + 1, 0)

        # Pour chaque position de départ dans le mot encadré,
        # remonter le trie tant que les enfants matchent les
        # caractères. À chaque nœud porteur de `values`, on
        # applique le max.
        n.times do |start|
          node = @root
          i = start
          while i < n
            child = node.children[chars[i]]?
            break unless child
            if (vs = child.values)
              vs.each_with_index do |v, j|
                pos = start + j
                next if pos > n
                scores[pos] = v if v > scores[pos]
              end
            end
            node = child
            i += 1
          end
        end

        scores
      end
    end

    # Algorithme principal d'hyphenation.
    #
    # `hyphenate("hyphenation")` → `[2, 4, 7]` (positions APRÈS
    # lesquelles une césure est légale, 0-indexed). Soit :
    # « hy-phe-na-tion » (couper après le 2e, 4e, 7e caractère).
    class Hyphenator
      getter trie : Trie
      getter exceptions : Hash(String, Array(Int32))

      def initialize(@trie : Trie, @exceptions : Hash(String, Array(Int32)))
      end

      def hyphenate(word : String) : Array(Int32)
        clean = word.downcase
        if (ex = @exceptions[clean]?)
          return ex
        end

        scores = @trie.scores_for(word)
        positions = [] of Int32
        word_size = word.size
        scores.each_with_index do |s, i|
          next unless s.odd?
          # `i` indexe la chaîne encadrée `.word.` : i=0 est avant
          # le `.`, i=1 entre le `.` et la 1re lettre du mot, etc.
          # `real_pos` = nombre de lettres du mot AVANT cette
          # frontière. Une césure « real_pos = 2 » signifie
          # « après les 2 premières lettres ».
          real_pos = i - 1
          next if real_pos < LEFT_MIN
          next if real_pos > word_size - RIGHT_MIN
          positions << real_pos
        end
        positions
      end
    end

    # Charge un `Hyphenator` pour la langue demandée selon la
    # cascade :
    #
    # 1. `./hyphenation/hyph-<lang>.tex` (projet AsciiDoc courant)
    # 2. `${XDG_CONFIG_HOME:-~/.config}/asciicrystal-pdf/hyphenation/hyph-<lang>.tex`
    # 3. Embarqué au build (les 7 langues FR/EN-US/DE-1996/ES/IT/
    #    PT/NL incluses via `read_file`)
    #
    # Cache class-level : un `Hyphenator` n'est parsé qu'une seule
    # fois par session, indexé par sa langue canonique.
    module Loader
      # Patterns embarqués au build via la macro `read_file`.
      # Le chemin est relatif au fichier source `hyphenation.cr`
      # placé dans `src/asciicrystal_pdf/`. Les fichiers sont dans
      # `data/hyphenation/` à la racine du repo.
      EMBEDDED = {
        "fr"      => {{ read_file("#{__DIR__}/../../data/hyphenation/hyph-fr.tex") }},
        "en-us"   => {{ read_file("#{__DIR__}/../../data/hyphenation/hyph-en-us.tex") }},
        "de-1996" => {{ read_file("#{__DIR__}/../../data/hyphenation/hyph-de-1996.tex") }},
        "es"      => {{ read_file("#{__DIR__}/../../data/hyphenation/hyph-es.tex") }},
        "it"      => {{ read_file("#{__DIR__}/../../data/hyphenation/hyph-it.tex") }},
        "pt"      => {{ read_file("#{__DIR__}/../../data/hyphenation/hyph-pt.tex") }},
        "nl"      => {{ read_file("#{__DIR__}/../../data/hyphenation/hyph-nl.tex") }},
      }

      # Aliases courts → langue canonique (utilisée comme clé).
      # `en` pointe sur `en-us` (variante par défaut), `de` sur
      # `de-1996` (réforme orthographique de 1996, version
      # « moderne »).
      ALIASES = {
        "en" => "en-us",
        "de" => "de-1996",
      }

      @@cache = {} of String => Hyphenator?

      def self.for(lang : String) : Hyphenator?
        # `lang` vient du document (`:lang:`) et entre dans un nom de
        # fichier : un code de langue n'a ni `/` ni `..`.
        return nil unless lang.matches?(/\A[A-Za-z0-9-]+\z/)
        canonical = ALIASES[lang]? || lang
        return @@cache[canonical] if @@cache.has_key?(canonical)

        content = locate(canonical)
        result = content ? parse(content) : nil
        @@cache[canonical] = result
        result
      end

      # Cascade de résolution. Retourne le contenu du fichier
      # `.tex` brut, ou `nil` si la langue n'est trouvée nulle part.
      private def self.locate(lang : String) : String?
        proj = File.join(Dir.current, "hyphenation", "hyph-#{lang}.tex")
        return File.read(proj) if File.file?(proj)

        if (xdg_base = ENV["XDG_CONFIG_HOME"]? || (ENV["HOME"]? ? "#{ENV["HOME"]}/.config" : nil))
          xdg_file = File.join(xdg_base, "asciicrystal-pdf", "hyphenation", "hyph-#{lang}.tex")
          return File.read(xdg_file) if File.file?(xdg_file)
        end

        EMBEDDED[lang]?
      end

      # Parse un fichier `hyph-<lang>.tex` au format Liang en
      # `Hyphenator`. Public pour permettre les tests sans cache
      # et la sous-commande `hyph install` qui valide un fichier
      # téléchargé avant de l'écrire sur disque.
      def self.parse(content : String) : Hyphenator
        trie = Trie.new
        exceptions = {} of String => Array(Int32)

        state = :outside

        content.each_line do |raw_line|
          # Strip commentaires LaTeX (`%...` jusqu'à fin de ligne).
          # Les fichiers hyph-*.tex n'utilisent pas `\%` échappé.
          line = if (idx = raw_line.index('%'))
                   raw_line[0...idx]
                 else
                   raw_line
                 end
          line = line.strip
          next if line.empty?

          if line.includes?("\\patterns{")
            state = :patterns
            line = line.sub("\\patterns{", " ")
          end
          if line.includes?("\\hyphenation{")
            state = :hyphenation
            line = line.sub("\\hyphenation{", " ")
          end

          closes = line.includes?('}')
          line = line.gsub('}', " ") if closes

          line.split.each do |token|
            next if token.empty?
            case state
            when :patterns
              trie.insert(token)
            when :hyphenation
              # `syl-la-bus` → mot « syllabus » avec césures à 3, 5.
              clean = String.build do |io|
                token.each_char { |c| io << c if c != '-' }
              end
              positions = [] of Int32
              pos = 0
              token.each_char do |c|
                if c == '-'
                  positions << pos
                else
                  pos += 1
                end
              end
              exceptions[clean.downcase] = positions
            end
          end

          state = :outside if closes
        end

        Hyphenator.new(trie, exceptions)
      end
    end
  end
end
