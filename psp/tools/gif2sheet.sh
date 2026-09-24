#!/usr/bin/env bash
# Turns an animated GIF into a one-row sprite sheet (PNG) the shell can play
# without a GIF decoder: at most 32 frames, evenly subsampled.  Prints the
# frame count and the frames per second for the manifest.
#   tools/gif2sheet.sh in.gif out.png
set -e
in=$1; out=$2
tmp=$(mktemp -d)
convert "$in" -coalesce "$tmp/f_%03d.png"
n=$(ls "$tmp" | wc -l)
stride=$(( (n + 31) / 32 ))
files=$(ls "$tmp"/f_*.png | awk -v s="$stride" 'NR % s == 1 || s == 1')
convert $files -background none +append "$out"
delay=$(identify -format '%T\n' "$in" | sed -n 2p)   # centiseconds, 2nd frame (the 1st often lingers)
[ -z "$delay" ] || [ "$delay" -le 0 ] && delay=10
echo "$(echo $files | wc -w) $(python3 -c "print(round(100 / $delay / $stride, 2))")"
rm -rf "$tmp"
