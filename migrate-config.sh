#!/system/bin/sh
# Upgrade migration only. Retain supported values, remove retired fields, never reset at boot.
cg_migrate_config() {
    cg_cfg="$1"; cg_defaults="$2"
    [ -s "$cg_cfg" ] || return 1
    [ -f "$cg_cfg.pre-v230.bak" ] || cp -p "$cg_cfg" "$cg_cfg.pre-v230.bak" || return 1
    awk '
        NR==FNR { raw=raw $0 "\n"; next }
        BEGIN { print "{"; comma="" }
        /"[a-z_]+"[[:space:]]*:/ {
            line=$0; sub(/^[[:space:]]*"/, "", line); sub(/".*/, "", line); key=line
            def=$0; sub(/^[^:]*:[[:space:]]*/, "", def); sub(/,[[:space:]]*$/, "", def)
            value=def
            pat="\"" key "\"[[:space:]]*:[[:space:]]*"
            if (match(raw,pat)) {
                rest=substr(raw,RSTART+RLENGTH)
                if (def ~ /^(true|false)$/) type="^(true|false)"
                else if (def ~ /^"/) type="^\"[^\"]*\""
                else type="^-?[0-9]+"
                if (match(rest,type)) value=substr(rest,RSTART,RLENGTH)
            }
            printf "%s  \"%s\": %s",comma,key,value; comma=",\n"
        }
        END { print "\n}" }
    ' "$cg_cfg" "$cg_defaults" > "$cg_cfg.migrate.tmp" || return 1
    [ -s "$cg_cfg.migrate.tmp" ] || return 1
    chmod 0644 "$cg_cfg.migrate.tmp" && mv -f "$cg_cfg.migrate.tmp" "$cg_cfg"
}
