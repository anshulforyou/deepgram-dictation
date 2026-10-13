# assets

`grandma-yawn.gif` is the README header, 720x440, shown at width 480. It is grandma's own mascot
from [grandma](https://github.com/anshulforyou/grandma/tree/master/assets), frames untouched, with
what this tool does drawn around her in the colours of her yarn (#feb1bb, #fa98a3, #d2626f): your
voice coming in as sound waves, a strand of yarn into her knitting, lines of text knitting up, and
a few z's.

Built like grandma's GIFs: transparent so it sits on GitHub light and dark, drawn at 2x and scaled
down, a per-file palette with `reserve_transparent=1` and `alpha_threshold=128`, 8 fps.
`make_gif.py` rebuilds it from the mascot: `python3 assets/make_gif.py path/to/grandma-mascot.gif`.
