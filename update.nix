{
  lib,
  writeShellApplication,
  jq,
  coreutils,
  git,
  curl,
  gawk,
}:
writeShellApplication {
  name = "tracy-update";
  runtimeInputs = [
    jq
    coreutils
    git
    curl
    gawk
  ];
  text = ''
    set -euo pipefail
    echo "Fetching latest revision from github.com/wolfpld/tracy"

    NEW_REV=$(git ls-remote https://github.com/wolfpld/tracy.git master | awk '{print $1}')
    PREV_REV=$(jq -r '.rev' version.json)
    if [ "$NEW_REV" = "$PREV_REV" ]; then
      echo "Revision matches current version.json, skipping update"
      exit 0
    fi
    echo "New revision: $NEW_REV (was: $PREV_REV)"

    BASE_URL="https://raw.githubusercontent.com/wolfpld/tracy/$NEW_REV"

    # -- Prefetch Tracy source
    echo "Prefetching Tracy source..."
    GIT_HASH=$(nix hash convert --to sri --hash-algo sha256 \
      "$(nix-prefetch-url --unpack "https://github.com/wolfpld/tracy/archive/$NEW_REV.tar.gz" 2>/dev/null)")
    echo "  hash: $GIT_HASH"

    # -- Parse Tracy version from TracyVersion.hpp
    VERSION_HPP=$(curl -sfL "$BASE_URL/public/common/TracyVersion.hpp")
    MAJOR=$(echo "$VERSION_HPP" | awk '/constexpr int Major/ { print $NF }' | tr -d ';')
    MINOR=$(echo "$VERSION_HPP" | awk '/constexpr int Minor/ { print $NF }' | tr -d ';')
    PATCH=$(echo "$VERSION_HPP" | awk '/constexpr int Patch/ { print $NF }' | tr -d ';')
    VERSION="$MAJOR.$MINOR.$PATCH"
    echo "Tracy version: $VERSION"

    # -- Parse CPM dependencies from vendor.cmake
    VENDOR_CMAKE=$(curl -sfL "$BASE_URL/cmake/vendor.cmake")

    # Only process deps we build from source (not system packages)
    WANTED_DEPS="capstone imgui ppqsort nfd json md4c base64 tidy usearch zstd"

    prefetch_github() {
      local owner="$1" repo="$2" rev="$3"
      nix hash convert --to sri --hash-algo sha256 \
        "$(nix-prefetch-url --unpack "https://github.com/$owner/$repo/archive/$rev.tar.gz" 2>/dev/null)"
    }

    # Parse CPMAddPackage blocks: emit "name\towner\trepo\ttag" lines
    DEPS_JSON="{}"
    while IFS=$'\t' read -r name owner repo tag; do
      case " $WANTED_DEPS " in
        *" $name "*) ;;
        *) continue ;;
      esac
      echo "Prefetching $name ($owner/$repo @ $tag)..."
      HASH=$(prefetch_github "$owner" "$repo" "$tag")
      echo "  hash: $HASH"
      DEPS_JSON=$(echo "$DEPS_JSON" | jq \
        --arg name "$name" \
        --arg owner "$owner" \
        --arg repo "$repo" \
        --arg rev "$tag" \
        --arg hash "$HASH" \
        '.[$name] = {owner: $owner, repo: $repo, rev: $rev, hash: $hash}')
    done < <(echo "$VENDOR_CMAKE" | awk '
      /CPMAddPackage\(/ { in_block=1; name=""; repo=""; tag="" }
      in_block && /^[[:space:]]*NAME[[:space:]]/ { name=$NF }
      in_block && /^[[:space:]]*GITHUB_REPOSITORY[[:space:]]/ { repo=$NF }
      in_block && /^[[:space:]]*GIT_TAG[[:space:]]/ { tag=$NF }
      in_block && /^[[:space:]]*VERSION[[:space:]]/ { if (tag == "") tag="v"$NF }
      in_block && /^[[:space:]]*\)/ {
        if (name != "" && repo != "" && tag != "") {
          split(repo, parts, "/")
          printf "%s\t%s\t%s\t%s\n", tolower(name), parts[1], parts[2], tag
        }
        in_block=0
      }
    ')

    # -- Handle transitive dependency: PackageProject.cmake (from PPQSort)
    PP_OWNER=$(echo "$DEPS_JSON" | jq -r '.ppqsort.owner')
    PP_REPO=$(echo "$DEPS_JSON" | jq -r '.ppqsort.repo')
    PP_REV=$(echo "$DEPS_JSON" | jq -r '.ppqsort.rev')
    echo "Resolving PackageProject.cmake version from PPQSort..."
    PPQSORT_CMAKE=$(curl -sfL "https://raw.githubusercontent.com/$PP_OWNER/$PP_REPO/$PP_REV/CMakeLists.txt")
    PKG_PROJECT_VER=$(echo "$PPQSORT_CMAKE" | grep 'TheLartians/PackageProject.cmake@' | sed 's/.*@//' | sed 's/[")].*//')
    PKG_PROJECT_TAG="v$PKG_PROJECT_VER"
    echo "Prefetching packageproject (TheLartians/PackageProject.cmake @ $PKG_PROJECT_TAG)..."
    PKG_PROJECT_HASH=$(prefetch_github "TheLartians" "PackageProject.cmake" "$PKG_PROJECT_TAG")
    echo "  hash: $PKG_PROJECT_HASH"
    DEPS_JSON=$(echo "$DEPS_JSON" | jq \
      --arg rev "$PKG_PROJECT_TAG" \
      --arg hash "$PKG_PROJECT_HASH" \
      '.packageproject = {owner: "TheLartians", repo: "PackageProject.cmake", rev: $rev, hash: $hash}')

    # -- Write version.json
    jq -n \
      --arg version "$VERSION" \
      --arg rev "$NEW_REV" \
      --arg gitHash "$GIT_HASH" \
      --argjson deps "$DEPS_JSON" \
      '{version: $version, rev: $rev, gitHash: $gitHash, deps: $deps}' \
      > version.json.tmp
    mv version.json.tmp version.json
    echo "Done updating version.json"
  '';
}
