# Renders the server's two config files from COMMAND-LINE flags.
#
#   zomboid-render-config --out DIR [--set K=V] [--mod ID] [--workshop ID]
#                                   [--sandbox K=V]
#
# Writes `DIR/fragment.ini` and `DIR/SandboxVars.lua`, each only when at least
# one flag feeds it. The launcher then points `ZOMBOID_CONFIG_FILE` and
# `ZOMBOID_SANDBOX_FILE` at them, so a flag and a hand-written file travel the
# same path into the server.
#
# ## Why this exists as a package
#
# `config-format.nix` renders the same two files, but it is a Nix function: it
# runs at EVALUATION time, and `nix run github:hcbt/nixzoid -- --mod tsarslib`
# has no evaluation left to do by the time the flag is read. So the flags need
# a renderer that runs at RUNTIME.
#
# Two renderers of one format is a drift risk, which is why this is its own
# package rather than a paragraph of the launcher: it carries no game content,
# so `checks.render-config` can EXECUTE it and diff its output against
# `config-format.nix` for the same input. Inlined into the launcher it would be
# reachable only by grepping a script that cannot be built without ~7G of Steam
# depots.
#
# ## Matching the Nix renderer exactly
#
# Nix iterates an attribute set in sorted key order, so both files sort. The
# sort is `LC_ALL=C` and keyed on the field before the first `=`, never on the
# whole line: `Max` and `Max0` order one way by key and the other way by line,
# because `=` (0x3D) sorts above the digits (0x30) and below the letters.
#
# Sandbox paths sort globally rather than per level, which gives the same
# result for the same reason — `.` (0x2E) is below every character a sandbox
# key uses, so a parent always sorts before its siblings.
{
  writeShellApplication,
  gawk,
  coreutils,
}:
writeShellApplication {
  name = "zomboid-render-config";
  runtimeInputs = [
    gawk
    coreutils
  ];
  text = ''
    usage() {
      cat >&2 <<'EOF'
    usage: zomboid-render-config --out DIR [options]

      --out DIR            where to write fragment.ini and SandboxVars.lua
      --set KEY=VALUE      one <name>.ini key, repeatable
      --mod ID[,ID...]     append to Mods. A list, and repeatable
      --workshop ID[,ID...] append to WorkshopItems. A list, and repeatable
      --sandbox KEY=VALUE  one SandboxVars key, repeatable.
                           A dotted KEY nests: ZombieLore.Speed=2
    EOF
      exit 2
    }

    die() { echo "zomboid-render-config: $*" >&2; exit 2; }

    # `--mod a,b` and `--mod a --mod b` are the same thing, and so is
    # `--mod "a, b"` with a space after the comma. Only the LIST options split:
    # a `--set` or `--sandbox` value is free text and may hold a comma, and
    # splitting one would cut a server message in half.
    parts=()
    split() { read -r -a parts <<< "''${1//,/ }"; }

    # `KEY=VALUE`, where KEY is non-empty and holds no `=`. A flag that is
    # merely a key with no `=` would otherwise render as a line the server
    # reads as a malformed setting and reports as a missing one.
    pair() {
      case "$1" in
        =*) die "$2: expected KEY=VALUE, got '$1' — the key is empty" ;;
        *=*) : ;;
        *) die "$2: expected KEY=VALUE, got '$1'" ;;
      esac
    }

    out=""
    ini=()
    mods=()
    workshop=()
    sandbox=()

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --out) [ "$#" -ge 2 ] || die "--out needs a directory"; out=$2; shift 2 ;;
        --set) [ "$#" -ge 2 ] || die "--set needs KEY=VALUE"; pair "$2" --set; ini+=("$2"); shift 2 ;;
        --mod)
          [ "$#" -ge 2 ] || die "--mod needs an id"
          split "$2"
          mods+=(''${parts[@]+"''${parts[@]}"})
          shift 2
          ;;
        --workshop)
          [ "$#" -ge 2 ] || die "--workshop needs an id"
          split "$2"
          workshop+=(''${parts[@]+"''${parts[@]}"})
          shift 2
          ;;
        --sandbox) [ "$#" -ge 2 ] || die "--sandbox needs KEY=VALUE"; pair "$2" --sandbox; sandbox+=("$2"); shift 2 ;;
        -h|--help) usage ;;
        *) die "unknown option '$1'" ;;
      esac
    done

    [ -n "$out" ] || usage
    mkdir -p "$out"

    # `--mod` and `--set Mods=` are two spellings of one key, and picking a
    # winner silently is how half a mod list goes missing. Both spellings work;
    # using both at once does not.
    conflict() {
      for entry in ''${ini[@]+"''${ini[@]}"}; do
        case "$entry" in
          "$1="*) die "$2 and --set $1= both set the same key — use one of them" ;;
        esac
      done
    }
    [ ''${#mods[@]} -eq 0 ] || conflict Mods --mod
    [ ''${#workshop[@]} -eq 0 ] || conflict WorkshopItems --workshop

    # Semicolons, the separator the server splits on — the same join
    # `config-format.nix` does for a Nix list.
    join() {
      local IFS=";"
      echo "$*"
    }
    [ ''${#mods[@]} -eq 0 ] || ini+=("Mods=$(join "''${mods[@]}")")
    [ ''${#workshop[@]} -eq 0 ] || ini+=("WorkshopItems=$(join "''${workshop[@]}")")

    # ---- <name>.ini ----------------------------------------------------
    #
    # Values pass through verbatim. The server's spellings are already what a
    # shell word is — `PVP=false` on the command line is the string the Nix
    # renderer produces for the boolean — so there is nothing to convert, and
    # converting would only introduce a way to disagree.
    if [ ''${#ini[@]} -gt 0 ]; then
      {
        echo "# Generated by nixzoid. These keys are re-applied on every server start;"
        echo "# changing them in-game or by hand does not survive a restart."
        # Last flag wins, then sort. Both halves have to happen before the
        # output: a repeated --set is a correction, not a duplicate line.
        printf '%s\n' "''${ini[@]}" \
          | gawk -F= '{ k = ''$1; if (!(k in seen)) { seen[k] = 1 } line[k] = ''$0 }
                      END { for (k in line) print line[k] }' \
          | LC_ALL=C sort -t= -k1,1
      } > "$out/fragment.ini"
    fi

    # ---- <name>_SandboxVars.lua ----------------------------------------
    if [ ''${#sandbox[@]} -gt 0 ]; then
      printf '%s\n' "''${sandbox[@]}" \
        | gawk -F= '{ k = ''$1; line[k] = ''$0 } END { for (k in line) print line[k] }' \
        | LC_ALL=C sort -t= -k1,1 \
        | gawk '
            # The type a bare value takes in Lua. `config-format.nix` decides
            # this from the Nix type, which a command line does not have — so
            # it is inferred, and anything that is not plainly a number or a
            # boolean becomes a quoted string.
            #
            # A non-integer prints as %f, six decimals, because that is what
            # `toString` does to a Nix float: 1.5 renders as 1.500000 on the
            # NixOS path and has to render the same here. Lua reads both, so
            # the divergence would never fail — it would only mean the two
            # renderers no longer produce the same file.
            function scalar(v) {
              if (v == "true" || v == "false") { return v }
              if (v ~ /^-?[0-9]+''$/) { return v }
              if (v ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?''$/) { return sprintf("%f", v) }
              gsub(/\\/, "\\\\", v)
              gsub(/"/, "\\\"", v)
              return "\"" v "\""
            }

            function pad(n,   s, i) {
              s = ""
              for (i = 0; i < n; i++) { s = s " " }
              return s
            }

            BEGIN {
              print "-- Generated by nixzoid. Rewritten in full on every server start."
              print "SandboxVars = {"
              depth = 0
            }

            {
              eq = index(''$0, "=")
              path = substr(''$0, 1, eq - 1)
              value = substr(''$0, eq + 1)
              n = split(path, part, ".")

              # A key cannot be both a value and a table. Emitting it anyway
              # produces Lua that parses, so the server would load it and
              # silently take defaults for the whole group.
              for (i = 1; i < n; i++) {
                if (part[i] in leaf) { print "zomboid-render-config: --sandbox " part[i] " is set as a value and as a group" > "/dev/stderr"; exit 2 }
              }
              leaf[path] = 1

              # How much of the enclosing path the previous line already opened.
              common = 0
              while (common < n - 1 && common < depth && part[common + 1] == open[common + 1]) { common++ }

              for (i = depth; i > common; i--) { print pad(4 * i) "}," }
              for (i = common + 1; i < n; i++) { print pad(4 * i) part[i] " = {"; open[i] = part[i] }
              depth = n - 1

              print pad(4 * n) part[n] " = " scalar(value) ","
            }

            END {
              for (i = depth; i >= 1; i--) { print pad(4 * i) "}," }
              print "}"
            }
          ' > "$out/SandboxVars.lua"
    fi
  '';

  meta = {
    description = "Render Project Zomboid server config and sandbox files from command-line flags";
    mainProgram = "zomboid-render-config";
  };
}
