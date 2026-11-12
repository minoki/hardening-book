mdbook build

find book -type f \
  \( -name '*.html' -o -name '*.xml' -o -name '*.css' -o -name '*.js' \
     -o -name '*.json' -o -name '*.svg' -o -name '*.txt' \) \
  -exec zopfli {} +
