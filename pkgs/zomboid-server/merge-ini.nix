# Applies a declared `<name>.ini` fragment over the one the server maintains.
#
#   zomboid-merge-ini FRAGMENT TARGET
#
# Every key in FRAGMENT replaces the same key in TARGET, in place; keys TARGET
# has and FRAGMENT does not are left exactly as the server wrote them; keys only
# FRAGMENT has are appended. TARGET need not exist.
#
# ## Why a merge rather than a copy
#
# The server writes ~150 options into that file and rewrites it as it runs.
# Replacing it wholesale would reset every option not declared in Nix on each
# restart — including ones the server derived rather than defaulted. Seeding it
# only when absent is the opposite failure: the deployment stops tracking the
# repository the moment the file exists.
#
# ## Why its own package
#
# It carries no game content, so it builds and RUNS in `nix flake check` on any
# platform — which is the only way this logic gets a test that can fail. Inlined
# into the launcher it would be reachable only by grepping the script.
{
  writeShellApplication,
  gawk,
  coreutils,
}:
writeShellApplication {
  name = "zomboid-merge-ini";
  runtimeInputs = [
    gawk
    coreutils
  ];
  text = ''
    if [ "$#" -ne 2 ]; then
      echo "usage: zomboid-merge-ini FRAGMENT TARGET" >&2
      exit 2
    fi

    fragment=$1
    target=$2

    if [ ! -e "$target" ]; then
      : > "$target"
    fi

    # Written beside the target rather than in /tmp: the rename has to be
    # atomic, and rename(2) does not cross filesystems. The state directory is
    # a bind mount or a PVC, so /tmp is a different one.
    tmp="$target.nixzoid-merge"

    # FRAGMENT is read first (NR == FNR), TARGET second. Whole lines are
    # carried across rather than reconstructed, so a value containing "=", ";",
    # a backslash or a quote survives untouched — which rules out the sed
    # substitution this would otherwise be.
    gawk '
      function keyof(line,   i) {
        # Comments and section-ish lines are content, not keys. The server does
        # not write them, but a hand-edited file may have them.
        if (line ~ /^[[:space:]]*[#;[]/) { return "" }
        i = index(line, "=")
        # i == 1 is a line starting with "=", which has no key.
        if (i < 2) { return "" }
        return substr(line, 1, i - 1)
      }

      NR == FNR {
        k = keyof(''$0)
        if (k != "") {
          if (!(k in declared)) { order[++n] = k }
          declared[k] = ''$0
        }
        next
      }

      {
        k = keyof(''$0)
        # delete, so the END block appends only what the target never had, and
        # so a duplicated key in the target does not get the value twice.
        if (k != "" && (k in declared)) {
          print declared[k]
          delete declared[k]
          next
        }
        print
      }

      END {
        for (i = 1; i <= n; i++) {
          if (order[i] in declared) { print declared[order[i]] }
        }
      }
    ' "$fragment" "$target" > "$tmp"

    mv -f "$tmp" "$target"
  '';

  meta = {
    description = "Merge a declared Project Zomboid server-config fragment into the server's own ini";
    mainProgram = "zomboid-merge-ini";
  };
}
