require "./spec_helper"
require "base64"
require "file_utils"

# Le logo de garde `:title-logo-image:` doit tenir DANS la page.
#
# Piège d'origine : `page.svg` ancre l'image par son bord SUPÉRIEUR
# tandis que `page.image` l'ancre par son bord INFÉRIEUR (convention
# PDF de la matrice `cm`). Le chemin bitmap passait `y_top` tel quel :
# le logo était dessiné AU-DESSUS du haut de la zone de contenu et se
# faisait trancher par le bord de la feuille.
# PNG 288x82 (le ratio d'un logo d'entête), généré une fois et
# embarqué : la spec ne dépend d'aucun fichier externe.
LOGO_PNG_B64 = <<-B64
  iVBORw0KGgoAAAANSUhEUgAAASAAAABSCAIAAAB7fJ6pAAACrUlEQVR42u3TY9cQBgCG4Tcv
  17Jt2zbWsm3btm2sWm3Ztm3btu1+Ref04foJ13OeOyAgSPCQYcL/GSV6rLgJEidLmSZ9pqw5
  cucrWKR4qTLlKlapXqtug8bNWrZp36lrj979Bg4ZPmrshMnT/pk9d97CJctXrd2wedvOPfsP
  HT1x+tzFK9dv3X3w+NnLN+8/ff0RONgfocNFjBwtZpz4iZKmSJ0uY5bsufIWKFys5F9lK1Su
  VrNO/UZNW7Ru17FL9159BwweNnLM+ElTZ8ya8/+CxctWrlm/aeuO3fsOHjl+6uyFy9du3rn/
  6OmL1+8+fvkeKGiIUGEjRIoaI3a8hEmSp0qbIXO2nHnyFypaovTf5StVrVG7XsMmzVu17dC5
  W88+/QcNHTF63MQp02f++9/8RUtXrF63ccv2XXsPHD528sz5S1dv3L738MnzV28/fP7Gz/8r
  /QEG5ucXmIPxC8zA/PwCczB+gTkYv8AMzM8vMAfjF5iD8QvMwPz8AnMwfoE5GL/ADMzPLzAH
  4xeYg/ELzMD8/AJzMH6BGZhfYAbm5xeYg/ELzMD8/AJzMH6BORi/wAzMzy8wB+MXmIPxC8zA
  /PwCczB+gTkYv8AMzM8vMAfjF5iD8QvMwPz8AnMwfoEZmF9gBubnF5iD8QvMwPz8AnMwfoE5
  GL/ADMzPLzAH4xeYg/ELzMD8/AJzMH6BORi/wAzMzy8wB+MXmIPxC8zA/PwCczB+gRmYX2AG
  5ucXmIPxC8zA/PwCczB+gTkYv8AMzM8vMAfjF5iD8QvMwPz8AnMwfoE5GL/ADMzPLzAH4xeY
  g/ELzMD8/AJzMH6BORi/wAzMzy8wB+MXmIH5+QXmYPwCczB+gRmYn19gDsYvMAfjF5iB+fkF
  5mD8AnMwfoEZmJ9fYA7G//v5fwIHfnbZH7zNcwAAAABJRU5ErkJggg==
  B64

describe "title-logo-image" do
  it "draws a bitmap logo below the top of the content area" do
    dir = File.tempname("cap-pdf-logo")
    Dir.mkdir_p(dir)
    logo = File.join(dir, "logo.png")
    File.write(logo, Base64.decode(LOGO_PNG_B64.gsub(/\s/, "")))

    pdf = IntegrationHelper.convert(<<-ADOC)
      = Document avec logo
      :title-logo-image: image::#{logo}[align=center, pdfwidth=180]

      Contenu.
      ADOC

    placements = IntegrationHelper.image_placements(pdf)
    placements.size.should eq(1)
    _, height, _, y = placements.first

    # Le haut du logo ne dépasse pas le haut de la feuille A4 (842 pt),
    # ni même la zone de contenu : c'est tout l'objet du correctif.
    (y + height).should be <= 842.0
    y.should be > 0.0

    File.delete(pdf)
    FileUtils.rm_rf(dir)
  end
end
