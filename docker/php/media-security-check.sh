#!/usr/bin/env bash
# Exercise the installed programs, not just their reported version. This
# check runs during every PHP/cron build and can be repeated after upgrade.
set -euo pipefail
export LC_ALL=C
export MAGICK_THREAD_LIMIT=1
export OMP_NUM_THREADS=1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
    printf 'Media security check failed: %s\n' "$*" >&2
    exit 1
}

for tool in /usr/bin/ffmpeg /usr/bin/ffprobe; do
    "$tool" -hide_banner -decoders > "$work/decoders"
    if awk '$2 == "magicyuv" || $2 == "tdsc" { found=1 } END { exit !found }' "$work/decoders"; then
        fail "$tool still exposes a disabled decoder"
    fi
done

# Each encoder must still produce a file that this image can decode. KVS
# uses H.264, HEVC and AV1, and AAC for the normal video conversion paths.
for encoder in libx264 libx265 libaom-av1; do
    options=()
    case "$encoder" in
        libx265) options=(-x265-params 'pools=1:frame-threads=1') ;;
        libaom-av1) options=(-cpu-used 8) ;;
    esac
    /usr/bin/ffmpeg -hide_banner -loglevel error -filter_threads 1 \
        -f lavfi -i testsrc2=size=64x64:rate=1 \
        -f lavfi -i sine=frequency=440:sample_rate=48000 \
        -t 1 -c:v "$encoder" -threads 1 "${options[@]}" -c:a aac \
        "$work/$encoder.mp4" > "$work/encode.log" 2>&1 || {
        cat "$work/encode.log" >&2
        fail "$encoder encoding"
    }
    /usr/bin/ffmpeg -hide_banner -loglevel error -threads 1 \
        -i "$work/$encoder.mp4" -f null -
done
/usr/bin/ffmpeg -hide_banner -loglevel error -threads 1 \
    -i "$work/libx264.mp4" -frames:v 1 "$work/screenshot.jpg"

# A valid, harmless MagicYUV AVI is encodable but must not be decodable.
/usr/bin/ffmpeg -hide_banner -loglevel error -filter_threads 1 \
    -f lavfi -i testsrc2=size=64x64:rate=1 -frames:v 1 \
    -c:v magicyuv -threads 1 "$work/magicyuv.avi"
if /usr/bin/ffmpeg -hide_banner -loglevel error -i "$work/magicyuv.avi" \
    -f null - > "$work/rejected.log" 2>&1; then
    fail 'MagicYUV decoding succeeded'
fi
grep -Eqi 'decoder.*(not found|none found)|decoding requested.*no decoder' "$work/rejected.log" || {
    cat "$work/rejected.log" >&2
    fail 'MagicYUV failed for an unexpected reason'
}

# Common images and screenshot resizing remain usable by the site owner.
for format in jpg png webp avif; do
    magick -size 64x48 gradient:blue-white "$work/image.$format"
    magick "$work/image.$format" -resize 32x24 "$work/resized-$format.png"
    [[ $(magick identify -format '%wx%h' "$work/resized-$format.png") == 32x24 ]] ||
        fail "$format resizing"
done
magick "$work/screenshot.jpg" -resize 32x32 "$work/thumbnail.jpg"

# The document only draws a rectangle. Its misleading extension must not
# let ImageMagick delegate it to Ghostscript, even if gs is later installed.
cat > "$work/postscript.jpg" <<'EPS'
%!PS-Adobe-3.0 EPSF-3.0
%%BoundingBox: 0 0 32 32
0 0 1 setrgbcolor
0 0 32 32 rectfill
showpage
EPS
if magick "$work/postscript.jpg" "$work/postscript.png" > "$work/rejected.log" 2>&1; then
    fail 'PostScript disguised as JPEG was accepted'
fi
grep -qi 'security policy' "$work/rejected.log" || {
    cat "$work/rejected.log" >&2
    fail 'PostScript was not rejected by policy'
}
printf '%s\n' 'Media security checks passed: blocked decoders and PostScript; video, audio and image conversions work.'
