#!/usr/bin/env bash
# The commit's release archive (git archive honours .gitattributes
# export-ignore, as GitHub's tag tarballs do) must load for a consumer:
# the export-ignored dirs are absent and `bazel query @<module>//...` works.
# The consumer pins the module's non-dev, non-BCR deps with the same
# overrides as its MODULE.bazel (overrides only apply in the root).
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
module="$(sed -n 's/^    name = "\(.*\)",$/\1/p' "$repo/MODULE.bazel" | head -1)"
src="$work/$module"
rm -rf "$work"; mkdir -p "$src" "$work/consumer"
git -C "$repo" archive HEAD | tar -x -C "$src"
for d in $(sed -n 's#^\([^ #]*\)/ export-ignore$#\1#p' "$repo/.gitattributes"); do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
overrides="$(python3 -I - "$src/MODULE.bazel" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
deps = {m.group(1) for m in re.finditer(r'bazel_dep\(\s*name\s*=\s*"([^"]+)"([^)]*)\)', s)
        if "dev_dependency" not in m.group(2)}
for m in re.finditer(r'(\w+_override)\((.*?)\n\)', s, re.S):
    name = re.search(r'module_name\s*=\s*"([^"]+)"', m.group(2))
    if name and name.group(1) in deps:
        print(m.group(0))
        dep = re.search(r'bazel_dep\(\s*name\s*=\s*"%s"[^)]*\)' % re.escape(name.group(1)), s)
        print(dep.group(0))
PY
)"
if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$work/consumer/"; fi
touch "$work/consumer/BUILD.bazel"
cat > "$work/consumer/MODULE.bazel" <<MOD
module(name = "consumer")
bazel_dep(name = "$module")
local_path_override(module_name = "$module", path = "$src")
$overrides
MOD
cd "$work/consumer"
bazel query "@$module//..." >/dev/null
echo "PASS: @$module//... loads from the archive"
