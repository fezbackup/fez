#!/usr/bin/env bash
#
# Builds install.sh from install.sh.tmpl plus the files in embed/.
#
# The installer ships as one file, because asking someone to download a tarball
# and trust a build step defeats the point of shipping something readable. But
# editing shell-quoted nginx config and JavaScript is miserable, so those live
# in embed/ as real files and this splices them in wherever the template has a
# line reading @@EMBED:name@@.
#
# Quoting around the heredoc decides whether the embedded file sees variable
# expansion: <<'DELIM' writes it literally, <<DELIM expands $vars in it.
#
# Embedded files can embed others, and do: setup-server.sh is the whole server
# side and the files it writes live inside it. So this splices recursively and
# tracks how deep the heredocs go.

set -euo pipefail


TEMPLATE="install.sh.tmpl"
EMBED_DIR="embed"
OUTPUT="install.sh"

RED=""; GREEN=""; DIM=""; RESET=""
if [ -t 1 ]; then
  RED=$(printf '\033[31m'); GREEN=$(printf '\033[32m')
  DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
fi

die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

[ -f "$TEMPLATE" ] || die "$TEMPLATE not found"
[ -d "$EMBED_DIR" ] || die "$EMBED_DIR/ not found"

# ---------------------------------------------------------------- splice ----

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

count=0
# Heredocs open at this point in the walk, innermost last. Gets 2-3 deep.
OPEN=()
# Matched with bash's own regex: a sed per line costs thousands of processes.
HEREDOC_RE="<<-?'?([A-Za-z_][A-Za-z0-9_]*)'?"
SEEN=""

# A line matching an enclosing heredoc delimiter would close it early and turn
# the rest of the file into commands. This is the one real hazard here.
check_delimiters() {
  local file="$1" delim
  for delim in ${OPEN+"${OPEN[@]}"}; do
    if grep -qxF "$delim" "$file"; then
      die "$file has a line reading '$delim', which would close a heredoc early"
    fi
  done
}

splice() {
  local source="$1" line name file delim

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      @@EMBED:*@@)
        name="${line#@@EMBED:}"
        name="${name%@@}"
        file="$EMBED_DIR/$name"

        [ -f "$file" ] || die "$source wants $file, which does not exist"
        case " $SEEN " in
          *" $name "*) die "$name is embedded inside itself" ;;
        esac
        # Spliced as-is, so no trailing newline runs into what follows.
        [ -z "$(tail -c 1 "$file")" ] || die "$file does not end with a newline"
        check_delimiters "$file"

        SEEN="$SEEN $name"
        count=$((count + 1))
        splice "$file"
        SEEN="${SEEN% $name}"
        ;;
      *)
        # Track heredocs so check_delimiters knows what we're inside.
        if [ "${#OPEN[@]}" -gt 0 ] && [ "$line" = "${OPEN[${#OPEN[@]}-1]}" ]; then
          unset "OPEN[${#OPEN[@]}-1]"
        else
          if [[ $line =~ $HEREDOC_RE ]]; then OPEN+=("${BASH_REMATCH[1]}"); fi
        fi
        printf '%s\n' "$line"
        ;;
    esac
  done < "$source"
}

splice "$TEMPLATE" > "$TMP"

# Anything in embed/ that nothing refers to is either a mistake or dead weight.
for file in "$EMBED_DIR"/*; do
  name="$(basename "$file")"
  grep -qr "@@EMBED:$name@@" "$TEMPLATE" "$EMBED_DIR" || printf '%swarning:%s %s is unused\n' \
    "$RED" "$RESET" "$file" >&2
done

# ----------------------------------------------------------------- check ----

if grep -q '@@EMBED:' "$TMP"; then
  grep -n '@@EMBED:' "$TMP" >&2
  die "placeholders left in the output; they must be alone on their own line"
fi

bash -n "$TMP" || die "the assembled script is not valid bash"

mv "$TMP" "$OUTPUT"
trap - EXIT
# mktemp made it 0600, and this is a file people download and read.
chmod 755 "$OUTPUT"

printf '%sbuilt%s %s %s(%s placeholders, %s lines)%s\n' \
  "$GREEN" "$RESET" "$OUTPUT" "$DIM" "$count" "$(wc -l < "$OUTPUT" | tr -d ' ')" "$RESET"
