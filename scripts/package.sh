#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

version="$(sed -n 's/^[[:space:]]*VERSION[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' plugins/burrow.koplugin/burrow_version.lua | head -n 1)"
if [[ -z "$version" ]]; then
  echo "Could not read VERSION from burrow_version.lua" >&2
  exit 1
fi

package_name="Burrow-${version}"
dist_dir="$repo_root/dist"
stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT

mkdir -p "$dist_dir" "$stage_dir/plugins"

for file in README.md INSTALL.txt CHANGELOG.md LICENSE NOTICE.md REMOVE_OLD_FILES.txt; do
  cp "$file" "$stage_dir/$file"
done
cp -R plugins/burrow.koplugin "$stage_dir/plugins/"

(
  cd "$stage_dir"
  find . -type f ! -name FILES.sha256 -print0 \
    | sort -z \
    | xargs -0 sha256sum > FILES.sha256
)

rm -f "$dist_dir/${package_name}.zip" "$dist_dir/${package_name}.sha256"
(
  cd "$stage_dir"
  zip -qr "$dist_dir/${package_name}.zip" .
)
(
  cd "$dist_dir"
  sha256sum "${package_name}.zip" > "${package_name}.sha256"
)

echo "Created:"
echo "  dist/${package_name}.zip"
echo "  dist/${package_name}.sha256"
