# Subsets the design fonts into res/font (static instances, Latin + Cyrillic, only the weights the app uses).
# Usage: python3 fonts/subset_fonts.py <dir with InterVariable.woff2 and SpaceGrotesk-Variable.woff2> src/main/res/font
# Needs: pip install fonttools brotli. Fonts: SIL Open Font License, see src/main/assets/licenses.
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools import subset
src=sys.argv[1].rstrip('/')+'/'
out=sys.argv[2]
uni="U+0020-007E,U+00A0-017F,U+0400-045F,U+0490-0491,U+2010-2027,U+2030-203A,U+20AC,U+20BD,U+2116,U+2122,U+2190-2193,U+2212,U+00B7"
def make(srcname, loc, dst):
    f=TTFont(src+srcname)
    inst=instantiateVariableFont(f, loc, updateFontNames=False)
    opts=subset.Options(); opts.layout_features=['kern','liga','calt','ccmp','locl','mark','mkmk','cv11','ss01','tnum','case']
    opts.name_IDs=['*']; opts.notdef_outline=True; opts.hinting=False; opts.desubroutinize=True
    s=subset.Subsetter(opts); s.populate(unicodes=subset.parse_unicodes(uni)); s.subset(inst)
    inst.flavor=None; inst.save(out+'/'+dst)
for w,n in [(400,'inter_regular'),(500,'inter_medium'),(600,'inter_semibold')]:
    make('InterVariable.woff2', {'opsz':14,'wght':w}, n+'.ttf')
make('SpaceGrotesk-Variable.woff2', {'wght':600}, 'space_grotesk_semibold.ttf')
