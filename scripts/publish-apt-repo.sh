#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'USAGE' >&2
usage: publish-apt-repo.sh [repo-dir]

Publishes validated .deb files from incoming/<source-project>/<tag>/ into the
apt repository pool, regenerates stable/main metadata, signs it, and commits
any changes.
USAGE
}

if [ "$#" -gt 1 ]; then
	usage
	exit 2
fi

repo_dir=${1:-.}

if [ ! -d "$repo_dir/.git" ]; then
	echo "apt repository checkout does not exist: $repo_dir" >&2
	exit 1
fi

for tool in apt-ftparchive awk cmp cp dpkg-deb find git gpg gzip mkdir rm sha256sum sort; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "required tool not found: $tool" >&2
		exit 1
	fi
done

repo_root=$(cd "$repo_dir" && pwd)
cd "$repo_root"

config_file="packages.tsv"
if [ ! -f "$config_file" ]; then
	echo "package allowlist does not exist: $config_file" >&2
	exit 1
fi

declare -A allowed_arches
declare -A pool_dirs
declare -A match_tag_versions
declare -A release_arches

while IFS='|' read -r source_project package_name architectures pool_dir version_must_match_tag; do
	if [[ -z "${source_project:-}" || "${source_project:0:1}" == "#" ]]; then
		continue
	fi
	if [[ -z "${package_name:-}" || -z "${architectures:-}" || -z "${pool_dir:-}" || -z "${version_must_match_tag:-}" ]]; then
		echo "invalid package allowlist row: ${source_project}|${package_name}|${architectures}|${pool_dir}|${version_must_match_tag}" >&2
		exit 1
	fi
	if [[ "$source_project" == *"/"* || "$pool_dir" = /* || "$pool_dir" == *".."* ]]; then
		echo "unsafe package allowlist row: ${source_project}|${package_name}|${pool_dir}" >&2
		exit 1
	fi
	case "$version_must_match_tag" in
		true | false) ;;
		*)
			echo "version_must_match_tag must be true or false for ${source_project}/${package_name}" >&2
			exit 1
			;;
	esac

	key="${source_project}|${package_name}"
	allowed_arches["$key"]=",${architectures// /},"
	pool_dirs["$key"]="$pool_dir"
	match_tag_versions["$key"]="$version_must_match_tag"

	IFS=',' read -ra arch_list <<<"$architectures"
	for arch in "${arch_list[@]}"; do
		arch=${arch// /}
		if [ -n "$arch" ]; then
			release_arches["$arch"]=1
		fi
	done
done <"$config_file"

if [ "${#pool_dirs[@]}" -eq 0 ]; then
	echo "package allowlist is empty: $config_file" >&2
	exit 1
fi

shopt -s nullglob
mapfile -t incoming_debs < <(find incoming -mindepth 3 -maxdepth 3 -type f -name '*.deb' 2>/dev/null | sort)
shopt -u nullglob

if [ "${#incoming_debs[@]}" -eq 0 ] && [ ! -d pool/main ]; then
	echo "no incoming .deb files found"
	exit 0
fi

if [ "${#incoming_debs[@]}" -eq 0 ]; then
	echo "no incoming .deb files found; regenerating metadata from existing pool"
fi

published=0
for deb in "${incoming_debs[@]}"; do
	rel=${deb#incoming/}
	source_project=${rel%%/*}
	rest=${rel#*/}
	tag=${rest%%/*}

	if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "incoming tag must be stable SemVer vX.Y.Z: $deb" >&2
		exit 1
	fi

	package_name=$(dpkg-deb -f "$deb" Package)
	package_arch=$(dpkg-deb -f "$deb" Architecture)
	package_version=$(dpkg-deb -f "$deb" Version)
	key="${source_project}|${package_name}"

	if [ -z "${pool_dirs[$key]+set}" ]; then
		echo "package is not allowlisted for source project ${source_project}: ${package_name}" >&2
		exit 1
	fi

	if [[ "${allowed_arches[$key]}" != *",${package_arch},"* ]]; then
		echo "architecture is not allowlisted for ${source_project}/${package_name}: ${package_arch}" >&2
		exit 1
	fi

	if [ "${match_tag_versions[$key]}" = "true" ] && [ "$package_version" != "${tag#v}" ]; then
		echo "package version ${package_version} does not match incoming tag ${tag} for $deb" >&2
		exit 1
	fi

	pool_dir=${pool_dirs[$key]}
	mkdir -p "$pool_dir"
	dest="$pool_dir/$(basename "$deb")"
	if [ -e "$dest" ]; then
		if cmp -s "$deb" "$dest"; then
			echo "already published: $dest"
			rm "$deb"
			continue
		fi

		echo "refusing to replace existing package with different bytes: $dest" >&2
		echo "existing: $(sha256sum "$dest" | awk '{print $1}')" >&2
		echo "new:      $(sha256sum "$deb" | awk '{print $1}')" >&2
		exit 1
	fi

	cp "$deb" "$dest"
	rm "$deb"
	echo "published: $dest"
	published=$((published + 1))
done

find incoming -type d -empty -delete 2>/dev/null || true

gpg_args=(--batch --yes --pinentry-mode loopback)
if [ -n "${APT_GPG_PASSPHRASE:-}" ]; then
	gpg_args+=(--passphrase "$APT_GPG_PASSPHRASE")
fi
if [ -n "${APT_GPG_KEY_ID:-}" ]; then
	gpg_args+=(-u "$APT_GPG_KEY_ID")
	gpg_key_selector=("$APT_GPG_KEY_ID")
else
	gpg_key_selector=()
fi

gpg --batch --yes --armor --output liquidmetal-archive-keyring.asc --export "${gpg_key_selector[@]}"
gpg --batch --yes --output liquidmetal-archive-keyring.gpg --export "${gpg_key_selector[@]}"

mapfile -t sorted_arches < <(printf '%s\n' "${!release_arches[@]}" | sort)
architectures_string="${sorted_arches[*]}"
for arch in "${sorted_arches[@]}"; do
	binary_dir="dists/stable/main/binary-$arch"
	mkdir -p "$binary_dir"
	apt-ftparchive --arch "$arch" packages pool/main >"$binary_dir/Packages"
	gzip -9c "$binary_dir/Packages" >"$binary_dir/Packages.gz"
done

apt-ftparchive \
	-o APT::FTPArchive::Release::Origin="LiquidMetal" \
	-o APT::FTPArchive::Release::Label="LiquidMetal" \
	-o APT::FTPArchive::Release::Suite="stable" \
	-o APT::FTPArchive::Release::Codename="stable" \
	-o APT::FTPArchive::Release::Architectures="$architectures_string" \
	-o APT::FTPArchive::Release::Components="main" \
	release dists/stable >dists/stable/Release

gpg "${gpg_args[@]}" --clearsign -o dists/stable/InRelease dists/stable/Release
gpg "${gpg_args[@]}" --detach-sign -o dists/stable/Release.gpg dists/stable/Release

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git add -A -- dists pool liquidmetal-archive-keyring.asc liquidmetal-archive-keyring.gpg
if [ -e incoming ]; then
	git add -A -- incoming
else
	git rm -r --ignore-unmatch incoming
fi

if ! git diff --cached --quiet -- .; then
	git commit -m "Publish apt packages"
	git push
	echo "apt repository updated; new packages copied: $published"
else
	echo "apt repository already up to date"
fi
