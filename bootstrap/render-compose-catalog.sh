#!/bin/sh
set -eu

catalog_root="${1:-.}"
output_name="${2:-.komodo.compose.yaml}"
generated_file=
temporary_file=

fail() {
  printf 'render-compose-catalog: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$temporary_file" ]; then
    case "$temporary_file" in
      */.komodo.compose.yaml.tmp.*|*/compose.yaml.tmp.*) rm -f "$temporary_file" ;;
      *) printf 'render-compose-catalog: refusing unexpected temporary path: %s\n' "$temporary_file" >&2 ;;
    esac
  fi
}
trap cleanup EXIT HUP INT TERM

[ -d "$catalog_root" ] || fail "directory does not exist: $catalog_root"
catalog_root="$(CDPATH= cd -- "$catalog_root" && pwd)"
case "$output_name" in
  compose.yaml|.komodo.compose.yaml) ;;
  *) fail 'output must be compose.yaml or .komodo.compose.yaml' ;;
esac
project_name="$(sed -n 's/^name:[[:space:]]*//p' "$catalog_root/compose.yaml" | head -n 1)"
case "$project_name" in
  *[!a-z0-9_-]*|'') fail 'root compose.yaml must declare a simple lowercase project name' ;;
esac
generated_file="$catalog_root/$output_name"
temporary_file="$(mktemp "$catalog_root/$output_name.tmp.XXXXXX")"

printf 'name: %s\n\ninclude:\n' "$project_name" >"$temporary_file"
count=0
for compose_file in "$catalog_root"/*/compose.yaml; do
  [ -f "$compose_file" ] || continue
  service_dir="${compose_file%/compose.yaml}"
  [ ! -e "$service_dir/.komodo-ignore" ] || continue
  service_name="${service_dir##*/}"
  case "$service_name" in
    *[!a-z0-9._-]*|'') fail "invalid service folder name: $service_name" ;;
  esac
  printf '  - path: ./%s/compose.yaml\n' "$service_name" >>"$temporary_file"
  count=$((count + 1))
done

[ "$count" -gt 0 ] || fail "no discoverable */compose.yaml files below $catalog_root"
chmod 0644 "$temporary_file"
mv -f "$temporary_file" "$generated_file"
temporary_file=
printf 'Rendered %s from %s service folders.\n' "$generated_file" "$count"
