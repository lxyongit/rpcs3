#!/bin/sh

file_path=$(find "$1/Contents/MacOS" -type f -print0 | head -n 1)

if [ -z "$file_path" ]; then
    echo "No executable file found in $1/Contents/MacOS" >&2
    exit 1
fi


target_architecture="$(lipo "$file_path" -archs)"

if [ -z "$target_architecture" ]; then
    exit 1
fi

# shellcheck disable=SC3045
find "$1" -type f -print0 | while IFS= read -r -d '' file; do
    # Resources and code-signature metadata are not Mach-O binaries. Passing
    # them to lipo both produces noisy failures and can invalidate a bundle.
    if ! file -b "$file" | grep -q '^Mach-O'; then
        continue
    fi

    file_architectures="$(lipo "$file" -archs)"
    set -- $file_architectures

    # A binary that already has one architecture cannot be thinned further.
    if [ "$#" -le 1 ]; then
        continue
    fi

    case " $file_architectures " in
        *" $target_architecture "*) ;;
        *)
            echo "Skipping $file: architecture $target_architecture is unavailable" >&2
            continue
            ;;
    esac

    echo "Thinning $file -> $target_architecture"
    tmp_file="${file}.thin.$$"
    if lipo "$file" -thin "$target_architecture" -output "$tmp_file"; then
        mv -f "$tmp_file" "$file"
    else
        rm -f "$tmp_file"
        echo "Failed to thin $file" >&2
        exit 1
    fi
done
