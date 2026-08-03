#!/usr/bin/bash

# This script chains together the pieces needed to package all supported deb packages.
# For simplicity, it does not run the required build(s) first or install dependencies, that's on you / the CI pipeline.
# If you're a human, the best way is to install the dev dependencies with the script in the main kanidm/kanidm repo:
# `PACKAGING=1 scripts/install_ubuntu_dependencies.sh`

set -e

# Manually pinned to known good version, see issue #17 for history
CARGO_DEB_VERSION="2.11.2"

# The target triplet must be given as an arg, for example: x86_64-unknown-linux-gnu
if [ -z "$1" ]; then
    >&2 echo "Missing target triplet as argument, for example: ${0} x86_64-unknown-linux-gnu"
    exit 1
fi
target="$1"

if [ ! -f "Cargo.toml" ]; then
    >&2 echo -e "Your current working directory doesn't look like we'll find the necessary data. This script must be run from from a checked out copy of the kanidm/kanidm project root."
    exit 1
fi

if [ -f "${HOME}/.cargo/env" ]; then
    # shellcheck disable=SC1091
    source "${HOME}/.cargo/env"
fi

# If we can't find cargo then need to update the path.
if [ "$(which cargo | wc -l)" -eq 0 ]; then
    if echo "$PATH" | grep -q '.cargo/bin'; then
        echo "Updating path to include local cargo dir"
        export PATH="$HOME/.cargo/bin:$PATH"
        if [ "$(which cargo | wc -l)" -eq 0 ]; then
            echo "Still couldn't find cargo, bailing!"
            exit 1
        fi
    fi
fi

if [ "$(which cargo-deb | wc -l)" -eq 0 ]; then
	echo "Installing missing cargo-deb"
	cargo install cargo-deb --version "$CARGO_DEB_VERSION"
fi

# Get the version. cargo-deb does have some version handling but it fails at a few key items such as the `-dev` suffix.
# We can't trust $GITHUB_SHA here because that points to the automation repo hash, not the source hash of what we're building.
git config --global --add safe.directory "$PWD"
GIT_HEAD="$(git rev-parse HEAD)"

KANIDM_VERSION="$(grep -ioE 'version.*' Cargo.toml | head -n1 | awk '{print $NF}' | tr -d '"' | sed -e 's/-/~/')"
# We read the commit date of the reference rev, feed it to date, format a bit and print in UTC.
# Ergo, the version date field is a unix time representation of when the commit was submitted.
# Unlike commit hashes, this is a sort compatible ever increasing version, but still marginally human readable.
DATESTR="$(date -ud "@$(git show --no-patch --format=%ct HEAD)" +%Y%m%d%H%M)"
GIT_COMMIT="${GIT_HEAD:0:7}"
DEBIAN_REV="${DATESTR}+${GIT_COMMIT}"
PACKAGE_VERSION="${KANIDM_VERSION}-${DEBIAN_REV}"

echo "Package version: ${PACKAGE_VERSION}"

echo "Updating changelog"
mkdir -p target/debian
sed -E \
    "s/#DATE#/$(date -R)/" \
    platform/debian/kanidm_ppa_automation/templates/changelog |
    sed -E "s/#VERSION#/${PACKAGE_VERSION}/" |
    sed -E "s/#GIT_COMMIT#/${GIT_COMMIT}/" |
    sed -E "s/#PACKAGE#/${PACKAGE}/" \
        >target/debian/changelog

metadata_path=""
patched_manifest=""
manifest_backup=""

restore_manifest() {
    if [[ -n "${patched_manifest}" &&
          -n "${manifest_backup}" &&
          -f "${manifest_backup}" ]]; then
        echo "Restoring ${patched_manifest}"

        if ! cp -- "${manifest_backup}" "${patched_manifest}"; then
            >&2 echo "Failed to restore ${patched_manifest}; backup remains at ${manifest_backup}"
            return 1
        fi

        rm -f -- "${manifest_backup}"
    fi

    patched_manifest=""
    manifest_backup=""
}

cleanup() {
    # A failed cargo-deb invocation must not leave the source checkout modified.
    restore_manifest || true

    if [[ -n "${metadata_path}" ]]; then
        rm -f -- "${metadata_path}" || true
    fi
}

trap cleanup EXIT

patch_unixd_internal_dependencies() {
    local manifest_path="$1"
    local dependency
    local match_count

    patched_manifest="${manifest_path}"
    manifest_backup="$(mktemp)"

    if ! cp -- "${patched_manifest}" "${manifest_backup}"; then
        >&2 echo "Failed to back up ${patched_manifest}"
        rm -f -- "${manifest_backup}"
        patched_manifest=""
        manifest_backup=""
        return 1
    fi

    for dependency in libpam-kanidm libnss-kanidm; do
        match_count="$(
            grep -Ec \
                "^[[:space:]]*\"${dependency}\"[[:space:]]*,?[[:space:]]*(#.*)?$" \
                "${patched_manifest}" ||
                true
        )"

        if [[ "${match_count}" -ne 1 ]]; then
            >&2 echo "Expected exactly one unversioned ${dependency} entry in ${patched_manifest}; found ${match_count}"
            exit 1
        fi

        sed -i -E \
            "s|^([[:space:]]*)\"${dependency}\"([[:space:]]*,?[[:space:]]*(#.*)?)$|\\1\"${dependency} (= ${PACKAGE_VERSION})\"\\2|" \
            "${patched_manifest}"

        if ! grep -Fq \
            "\"${dependency} (= ${PACKAGE_VERSION})\"" \
            "${patched_manifest}"; then
            >&2 echo "Failed to pin ${dependency} in ${patched_manifest}"
            exit 1
        fi
    done

    echo "Pinned kanidm-unixd PAM/NSS dependencies to ${PACKAGE_VERSION}"
}

echo "Packaging for: ${target}"

# Build debs per Rust package.
metadata_path="$(mktemp)"

cargo metadata \
    --format-version 1 \
    --filter-platform "$target" \
    >"$metadata_path"

for rust_package in \
    daemon \
    kanidm_unix_int \
    kanidm_tools \
    pam_kanidm \
    nss_kanidm; do

    # Check that we have a config for the package.
    manifest_path="$(
        jq -r \
            ".packages[] | select(.name == \"${rust_package}\") | .manifest_path" \
            "$metadata_path"
    )"

    if [[ -z "${manifest_path}" || "${manifest_path}" == "null" ]]; then
        echo "::warning Rust package ${rust_package} was not found; not building it. This may be normal for an older version."
        continue
    fi

    if grep -q 'package.metadata.deb' "$manifest_path"; then
        echo "Building deb for: ${rust_package}"

        extra_args=()

        if [[ -n "${VERBOSE:-}" ]]; then
            extra_args+=("-v")
        fi
        # kanidmd needs to drop a config at /usr/lib/sysusers.d, not an arch specific variant
        if [[ "$rust_package" != "daemon" ]]; then
            extra_args+=("--multiarch=foreign")
        fi

        # cargo-deb cannot substitute the final --deb-version into Depends.
        # Patch only while building kanidm-unixd, then restore the checkout.
        if [[ "$rust_package" == "kanidm_unix_int" ]]; then
            patch_unixd_internal_dependencies "$manifest_path"
        fi

        cargo deb \
            -p "$rust_package" \
            --no-build \
            --target "$target" \
            --deb-version "$PACKAGE_VERSION" \
            "${extra_args[@]}"

        if [[ "$rust_package" == "kanidm_unix_int" ]]; then
            restore_manifest
        fi
    else
        echo "::warning No deb metadata found for ${rust_package}, not building it! This may be normal if building an older version."
    fi
done

rm -f -- "$metadata_path"
metadata_path=""

# Verify the generated package rather than trusting that the text replacement
# worked.
unixd_deb=""

while IFS= read -r -d '' candidate; do
    if [[ "$(dpkg-deb -f "$candidate" Version)" == "$PACKAGE_VERSION" ]]; then
        if [[ -n "$unixd_deb" ]]; then
            >&2 echo "Found more than one kanidm-unixd package at version ${PACKAGE_VERSION}:"
            >&2 echo "  ${unixd_deb}"
            >&2 echo "  ${candidate}"
            exit 1
        fi

        unixd_deb="$candidate"
    fi
done < <(
    find "target/${target}/debian" \
        -maxdepth 1 \
        -type f \
        -name 'kanidm-unixd_*.deb' \
        -print0
)

if [[ -z "$unixd_deb" ]]; then
    >&2 echo "Could not find kanidm-unixd package at version ${PACKAGE_VERSION}"
    exit 1
fi

unixd_depends="$(dpkg-deb -f "$unixd_deb" Depends)"

for dependency in libpam-kanidm libnss-kanidm; do
    expected_dependency="${dependency} (= ${PACKAGE_VERSION})"

    if ! grep -Fq "$expected_dependency" <<<"$unixd_depends"; then
        >&2 echo "Generated package ${unixd_deb} is missing required dependency: ${expected_dependency}"
        >&2 echo "Actual Depends: ${unixd_depends}"
        exit 1
    fi
done

echo "Verified kanidm-unixd lockstep dependencies:"
echo "  ${unixd_depends}"

echo "Target ${target} done, packages:"
find "target/${target}" -maxdepth 3 -name '*.deb'