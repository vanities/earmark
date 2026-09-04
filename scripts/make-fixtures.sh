#!/usr/bin/env bash
# Generates a small, realistic audiobook library with real narration (macOS `say`)
# so the simulator has something to play: tagged MP3 chapters, an M4B with chapters
# and a cover, Disc 1/Disc 2 folders, an Author/Series/Book tree, loose single-file
# books, and one deliberate duplicate. Nothing here ships in the app.
#
#   scripts/make-fixtures.sh [OUT_DIR]     (default: ./fixtures)
set -euo pipefail

OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/fixtures}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
VOICE="${VOICE:-Samantha}"
if ! say -v '?' | awk '{print $1}' | grep -qx "$VOICE"; then VOICE=""; fi

log() { echo "[$(date +%T)] $*" >&2; }

speak() { # out.aiff "text"
  if [ -n "$VOICE" ]; then say -v "$VOICE" -r 190 -o "$1" "$2"; else say -r 190 -o "$1" "$2"; fi
}

cover() { # out.jpg seed
  if ! ffmpeg -y -loglevel error -f lavfi -i "gradients=s=600x600:n=3:seed=$2:speed=0.0001" -frames:v 1 "$1" 2>/dev/null; then
    ffmpeg -y -loglevel error -f lavfi -i "color=c=0x$(printf '%02x%02x%02x' $((40 + $2 * 37 % 200)) $((90 + $2 * 53 % 150)) $((120 + $2 * 71 % 120))):s=600x600" -frames:v 1 "$1"
  fi
}

mp3() { # out.mp3 in.aiff title artist album track disc
  local out="$1" in="$2" title="$3" artist="$4" album="$5" track="$6" disc="${7:-}"
  local args=(-y -loglevel error -i "$in" -codec:a libmp3lame -q:a 7 -id3v2_version 3)
  [ -n "$title" ] && args+=(-metadata "title=$title")
  [ -n "$artist" ] && args+=(-metadata "artist=$artist")
  [ -n "$album" ] && args+=(-metadata "album=$album")
  [ -n "$track" ] && args+=(-metadata "track=$track")
  [ -n "$disc" ] && args+=(-metadata "disc=$disc")
  mkdir -p "$(dirname "$out")"
  ffmpeg "${args[@]}" "$out"
  log "wrote $out ($(wc -c <"$out") bytes)"
}

duration_ms() { # file → integer milliseconds
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" | awk '{printf "%d", $1 * 1000}'
}

rm -rf "$OUT"
mkdir -p "$OUT"

# 1. Tagged MP3 chapters + cover.jpg
PP="$OUT/Audiobooks/Jane Austen/Pride and Prejudice"
mkdir -p "$PP"
cover "$PP/cover.jpg" 3
i=0
while IFS= read -r line; do
  i=$((i + 1))
  speak "$TMP/pp$i.aiff" "Chapter $i. $line"
  mp3 "$PP/0$i - Chapter $i.mp3" "$TMP/pp$i.aiff" "Chapter $i" "Jane Austen" "Pride and Prejudice" "$i/4"
done <<'TEXT'
It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.
Mr. Bennet was among the earliest of those who waited on Mr. Bingley. He had always intended to visit him, though to the last always assuring his wife that he should not go.
Not all that Mrs. Bennet, however, with the assistance of her five daughters, could ask on the subject, was sufficient to draw from her husband any satisfactory description of Mr. Bingley.
When Jane and Elizabeth were alone, the former, who had been cautious in her praise of Mr. Bingley before, expressed to her sister how very much she admired him.
TEXT

# 2. M4B with embedded chapters and cover art
FR="$OUT/Audiobooks/Mary Shelley"
mkdir -p "$FR"
cover "$TMP/frank.jpg" 7
titles=("Letter 1" "Letter 2" "Chapter 1")
texts=(
  "Letter one. You will rejoice to hear that no disaster has accompanied the commencement of an enterprise which you have regarded with such evil forebodings."
  "Letter two. How slowly the time passes here, encompassed as I am by frost and snow! Yet a second step is taken towards my enterprise."
  "Chapter one. I am by birth a Genevese, and my family is one of the most distinguished of that republic."
)
: > "$TMP/list.txt"
{
  echo ";FFMETADATA1"
  echo "title=Frankenstein"
  echo "artist=Mary Shelley"
  echo "album=Frankenstein"
  echo "composer=${VOICE:-Narrator}"
  echo "date=1818"
} > "$TMP/meta.txt"
start=0
for n in 0 1 2; do
  speak "$TMP/fr$n.aiff" "${texts[$n]}"
  echo "file '$TMP/fr$n.aiff'" >> "$TMP/list.txt"
  ms=$(duration_ms "$TMP/fr$n.aiff")
  end=$((start + ms))
  { echo "[CHAPTER]"; echo "TIMEBASE=1/1000"; echo "START=$start"; echo "END=$end"; echo "title=${titles[$n]}"; } >> "$TMP/meta.txt"
  start=$end
done
if ! ffmpeg -y -loglevel error -f concat -safe 0 -i "$TMP/list.txt" -i "$TMP/meta.txt" -i "$TMP/frank.jpg" \
    -map 0:a -map 2:v -map_metadata 1 -map_chapters 1 -c:a aac -b:a 48k -c:v mjpeg -disposition:v attached_pic \
    -movflags +faststart -f ipod "$FR/Frankenstein.m4b"; then
  log "cover embed failed; writing m4b without artwork"
  ffmpeg -y -loglevel error -f concat -safe 0 -i "$TMP/list.txt" -i "$TMP/meta.txt" \
    -map 0:a -map_metadata 1 -map_chapters 1 -c:a aac -b:a 48k -movflags +faststart -f ipod "$FR/Frankenstein.m4b"
fi
log "wrote $FR/Frankenstein.m4b ($(wc -c <"$FR/Frankenstein.m4b") bytes)"

# 3. Disc folders, no tags at all (exercises folder inference + filename chapter titles)
MD="$OUT/Audiobooks/Herman Melville/Moby-Dick"
speak "$TMP/md1.aiff" "Loomings. Call me Ishmael. Some years ago, never mind how long precisely, having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world."
speak "$TMP/md2.aiff" "The Carpet Bag. I stuffed a shirt or two into my old carpet bag, tucked it under my arm, and started for Cape Horn and the Pacific."
speak "$TMP/md3.aiff" "The Spouter Inn. Entering that gable-ended Spouter Inn, you found yourself in a wide, low, straggling entry with old-fashioned wainscots."
mp3 "$MD/Disc 1/01 Loomings.mp3" "$TMP/md1.aiff" "" "" "" ""
mp3 "$MD/Disc 1/02 The Carpet-Bag.mp3" "$TMP/md2.aiff" "" "" "" ""
mp3 "$MD/Disc 2/01 The Spouter-Inn.mp3" "$TMP/md3.aiff" "" "" "" ""

# 4. Author / Series / "N - Book" convention, artist tag only
AL="$OUT/Audiobooks/Lewis Carroll/Alice"
speak "$TMP/al1.aiff" "Chapter one. Down the Rabbit Hole. Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do."
speak "$TMP/al2.aiff" "Chapter two. The Pool of Tears. Curiouser and curiouser! cried Alice."
speak "$TMP/lg1.aiff" "Chapter one. Looking-Glass House. One thing was certain, that the white kitten had had nothing to do with it."
speak "$TMP/lg2.aiff" "Chapter two. The Garden of Live Flowers. I should see the garden far better, said Alice to herself, if I could get to the top of that hill."
mp3 "$AL/1 - Alice's Adventures in Wonderland/01 Down the Rabbit-Hole.mp3" "$TMP/al1.aiff" "" "Lewis Carroll" "" "1"
mp3 "$AL/1 - Alice's Adventures in Wonderland/02 The Pool of Tears.mp3" "$TMP/al2.aiff" "" "Lewis Carroll" "" "2"
mp3 "$AL/2 - Through the Looking-Glass/01 Looking-Glass House.mp3" "$TMP/lg1.aiff" "" "Lewis Carroll" "" "1"
mp3 "$AL/2 - Through the Looking-Glass/02 The Garden of Live Flowers.mp3" "$TMP/lg2.aiff" "" "Lewis Carroll" "" "2"
cover "$AL/1 - Alice's Adventures in Wonderland/folder.jpg" 11

# 5. Loose single-file books distinguished only by tags
LO="$OUT/Loose"
speak "$TMP/raven.aiff" "The Raven. Once upon a midnight dreary, while I pondered, weak and weary, over many a quaint and curious volume of forgotten lore."
speak "$TMP/ozy.aiff" "Ozymandias. I met a traveller from an antique land, who said: Two vast and trunkless legs of stone stand in the desert."
mp3 "$LO/raven.mp3" "$TMP/raven.aiff" "The Raven" "Edgar Allan Poe" "The Raven" "1"
mp3 "$LO/ozymandias.mp3" "$TMP/ozy.aiff" "Ozymandias" "Percy Bysshe Shelley" "Ozymandias" "1"

# 6. A byte-for-byte duplicate of a whole book, somewhere else
DUP="$OUT/Downloads/Pride and Prejudice (copy)"
mkdir -p "$DUP"
cp "$PP"/*.mp3 "$DUP/"

log "fixtures ready in $OUT"
find "$OUT" -type f | sort >&2
