#!/bin/bash
set -euo pipefail
: "${GITHUB_REPOSITORY:?}" "${XBPS_PRIVKEY:?}"
shopt -s nullglob

TAG=repo
SIGNEDBY="${SIGNEDBY:-${GITHUB_REPOSITORY_OWNER:-xbps-builder}}"
ARCH=$(xbps-uhelper arch)
WORK=$PWD
VP=/home/builder/void-packages
BIN=$VP/hostdir/binpkgs
GHR=(-R "$GITHUB_REPOSITORY")

[ -f "$WORK/.github/scripts/packages.txt" ] || { echo ".github/scripts/packages.txt missing" >&2; exit 1; }

id builder >/dev/null 2>&1 || useradd -m builder
rm -rf "$VP"; mkdir -p "$VP"
cp -a "$WORK"/. "$VP"/
mkdir -p "$BIN"

gh release view "$TAG" "${GHR[@]}" >/dev/null 2>&1 || \
	gh release create "$TAG" "${GHR[@]}" -t "xbps repo" -n "Binary xbps repository" --latest=false

assets=$(gh release view "$TAG" "${GHR[@]}" --json assets -q '.assets[].name')
if [ -n "$assets" ]; then
	gh release download "$TAG" "${GHR[@]}" -D "$BIN" --pattern '*' --clobber
fi

todo=()
while read -r pkg; do
	t="$WORK/srcpkgs/$pkg/template"
	[ -f "$t" ] || { echo "no template for $pkg" >&2; exit 1; }
	ver=$(sed -n 's/^version=//p' "$t" | tr -d '"'\' | head -1)
	rev=$(sed -n 's/^revision=//p' "$t" | tr -d '"'\' | head -1)
	if [[ "$ver" != *'$'* ]] && [ -e "$BIN/${pkg}-${ver}_${rev}.${ARCH}.xbps" ]; then
		echo "skip $pkg-${ver}_${rev} (already published)"
	else
		todo+=("$pkg")
	fi
done < <(grep -Ev '^\s*(#|$)' "$WORK/.github/scripts/packages.txt")

if [ ${#todo[@]} -eq 0 ]; then echo "Nothing to build."; exit 0; fi
echo "Building: ${todo[*]}"

chown -R builder:builder /home/builder
su builder -c "cd $VP && ./xbps-src binary-bootstrap && printf '%s\n' ${todo[*]} | xargs -n1 ./xbps-src pkg"

cd "$BIN"
printf '%s\n' "$XBPS_PRIVKEY" > /tmp/privkey.pem; chmod 600 /tmp/privkey.pem
xbps-rindex -r . || true
xbps-rindex -c . || true
for s in *.sig2; do [ -e "${s%.sig2}" ] || rm -f "$s"; done
xbps-rindex --privkey /tmp/privkey.pem --sign --signedby "$SIGNEDBY" .
pkgs=(*.xbps)
if [ ${#pkgs[@]} -gt 0 ]; then
    xbps-rindex --privkey /tmp/privkey.pem --sign-pkg "${pkgs[@]}"
fi
rm -f /tmp/privkey.pem

mapfile -t remote < <(gh release view "$TAG" "${GHR[@]}" --json assets -q '.assets[].name')
local_files=(*.xbps *.xbps.sig2 *-repodata)
upload=()
for f in "${local_files[@]}"; do
	[[ "$f" == *-repodata || "$f" == *.sig2 ]] && { upload+=("$f"); continue; }
	printf '%s\n' "${remote[@]}" | grep -qxF "$f" || upload+=("$f")
done
if [ ${#upload[@]} -gt 0 ]; then
    gh release upload "$TAG" "${GHR[@]}" --clobber "${upload[@]}"
fi
for r in "${remote[@]}"; do
	printf '%s\n' "${local_files[@]}" | grep -qxF "$r" || gh release delete-asset "$TAG" "$r" "${GHR[@]}" -y
done
echo "Done."
