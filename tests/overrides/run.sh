#!/usr/bin/env bash
#
# Exercises the optional CLI/provider download pins end to end.
#
# The fixtures are built rather than checked in: this script first runs the
# default (non-pinned) code path, then reuses the artefacts it produced --- the
# CLI, repacked as an archive, and the provider zips exactly as they are laid
# out in the mirror --- as the origins the pinned path is pointed at over
# file:// URLs. That keeps the repository free of vendored binaries and
# guarantees the fixtures always match what the default path actually produces.
#
# Usage: tests/overrides/run.sh [terraform|tofu]

set -euo pipefail

ENGINE="${1:-terraform}"

case "${ENGINE}" in
  terraform)
    USE_TOFU="False"
    VERSION="1.9.5"
    CLI_DIR="terraform"
    # terraform resolves providers against its own registry, and the mirror it
    # consumes under -plugin-dir is laid out under that same hostname.
    REGISTRY="registry.terraform.io"
    ;;
  tofu)
    USE_TOFU="True"
    VERSION="1.9.0"
    CLI_DIR="tofu"
    # OpenTofu uses a different registry, so the mirror path differs from
    # terraform's even though the zip file names are identical.
    REGISTRY="registry.opentofu.org"
    ;;
  *)
    echo "usage: $0 [terraform|tofu]" >&2
    exit 2
    ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_TF="${REPO_ROOT}/tests/bcr/tf"
WORK="$(mktemp -d)"
touch "${WORK}/workspaces"
bazel() { command bazel --output_user_root="${WORK}/bazel-output" "$@"; }
shutdown_bazel() {
  (cd "$1" && bazel shutdown) && touch "$1/.bazel-stopped"
}
cleanup() {
  local status=$? dir failed=0
  while IFS= read -r dir; do
    if [ ! -f "${dir}/.bazel-stopped" ]; then
      shutdown_bazel "${dir}" || failed=1
    fi
  done <"${WORK}/workspaces"
  if [ "${failed}" -eq 0 ]; then
    if ! find "${WORK}" -type d -exec chmod u+w {} + || ! rm -rf "${WORK}"; then
      echo "Cleanup failed. Retained test storage: ${WORK}" >&2
      status=1
    fi
  else
    echo "Bazel shutdown failed. Retained test storage: ${WORK}" >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Pins are per-platform, because each platform has its own artefact and
# therefore its own digest. Derive the key for this host the same way
# detect_host_platform() in the ruleset does.
host_os="$(uname -s)"
case "${host_os}" in
  Darwin) host_os="darwin" ;;
  Linux) host_os="linux" ;;
  *) host_os="$(echo "${host_os}" | tr '[:upper:]' '[:lower:]')" ;;
esac
host_arch="$(uname -m)"
case "${host_arch}" in
  aarch64 | arm64) host_arch="arm64" ;;
  x86_64 | amd64) host_arch="amd64" ;;
esac
PLATFORM="${host_os}/${host_arch}"

# A platform that is deliberately not this host, used to prove that the rule
# selects by platform rather than just taking whatever entry it finds.
if [ "${PLATFORM}" = "linux/amd64" ]; then
  OTHER_PLATFORM="darwin/arm64"
else
  OTHER_PLATFORM="linux/amd64"
fi

# Targets that prove the toolchain is usable: `validate` runs the engine's
# `init` against the provider mirror, which is the whole point of the feature.
VALIDATE_TARGETS=(//tf/modules/mod-a:validate //tf/root-modules/root-mod-a:validate)

NULL_VERSION="3.1.1"
RANDOM_VERSION="3.3.2"

PASSED=0
EXPECTED_CHECKS=24

info() { echo "== $*"; }
pass() { echo "PASS: $*"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Creates a self-contained Bazel module that consumes rules_tf from this
# checkout. "$2" is injected verbatim into the tf.download() call.
#
# Any *.json file placed in "${dir}" before the module is built is exported,
# so pins files can be referenced as //:<name> labels.
#
# Set ISOLATE_CACHE=1 before calling to give the module its own repository
# cache. That matters whenever the test asserts something about *how* an
# artifact is fetched: the shared cache is keyed by sha256, so it will happily
# serve a previously fetched archive without resolving the URL at all, which
# silently turns such a test into a no-op.
make_module() {
  local dir="$1" attrs="$2" cache="${WORK}/rcache"
  mkdir -p "${dir}"
  printf '%s\n' "${dir}" >>"${WORK}/workspaces"
  if [ "${ISOLATE_CACHE:-0}" = "1" ]; then
    cache="${WORK}/isolated-caches/$(basename "${dir}")"
  fi
  cp -R "${FIXTURE_TF}" "${dir}/tf"
  # Bazel 6 locates the workspace root via WORKSPACE rather than MODULE.bazel.
  touch "${dir}/WORKSPACE" "${dir}/WORKSPACE.bzlmod"
  # Pins files are ordinary source files reached by label, so the package that
  # holds them has to export them.
  cat > "${dir}/BUILD" <<'EOF'
exports_files(glob(["*.json"]))
EOF
  # Each fixture is its own workspace, so they share nothing by default. Point
  # them at one repository cache so the CLI and provider archives are fetched
  # once for the whole run instead of once per fixture.
  cat > "${dir}/.bazelrc" <<EOF
common --enable_bzlmod
common --repository_cache=${cache}
EOF
  cp "${REPO_ROOT}/.bazelversion" "${dir}/.bazelversion"
  # Honour the bazelisk version pin used by the rest of the test suite.
  if [ -f "${REPO_ROOT}/tests/bcr/.bazeliskrc" ]; then
    cp "${REPO_ROOT}/tests/bcr/.bazeliskrc" "${dir}/.bazeliskrc"
  fi
  cat > "${dir}/MODULE.bazel" <<EOF
module(name = "rules_tf_override_fixture", version = "0.0.1")

bazel_dep(name = "rules_tf", version = "", repo_name = "rules_tf")
local_path_override(
    module_name = "rules_tf",
    path = "${REPO_ROOT}",
)

tf = use_extension("@rules_tf//tf:extensions.bzl", "tf_repositories")
tf.download(
    version = "${VERSION}",
    use_tofu = ${USE_TOFU},
${attrs}
)

use_repo(tf, "tf_toolchains")

register_toolchains("@tf_toolchains//:all")
EOF
}

# Locates the generated toolchain repository. The canonical repository name is
# mangled differently across Bazel versions ("~" before Bazel 8, "+" after), so
# match on the stable substring instead.
find_tf_repo() {
  local dir="$1" output_base matches count
  output_base="$(cd "${dir}" && bazel info output_base)"
  matches="$(find "${output_base}/external" -maxdepth 1 -type d -name '*download_tf_0*')"
  count="$(printf '%s' "${matches}" | grep -c . || true)"
  # More than one match would mean every later assertion inspects an
  # arbitrarily chosen repository, so treat it as an error rather than
  # silently taking the first.
  if [ "${count}" != "1" ]; then
    fail "expected exactly 1 toolchain repository under ${output_base}/external, found ${count}"
  fi
  printf '%s' "${matches}"
}

# Emits one pins entry. Callers compose these into a pins file.
#   $1 key, $2 version, $3 url, $4 sha256
# A second entry for a platform that is not this host is always included, so
# every case also proves the rule selects by platform instead of taking the
# only entry present.
pin_entry() {
  cat <<EOF
  "$1": {
    "version": "$2",
    "platforms": {
      "${PLATFORM}": {"url": "$3", "sha256": "$4"},
      "${OTHER_PLATFORM}": {"url": "file:///nonexistent/wrong-platform.zip", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}
    }
  }
EOF
}

# ---------------------------------------------------------------------------
# Step 1: build the fixtures from the default (non-pinned) code path.
# ---------------------------------------------------------------------------
# A failed mirror must fail repository setup, even when the CLI itself works.
info "[${ENGINE}] case: unpinned provider version does not exist"
FAILED_MIRROR_DIR="${WORK}/failed-mirror"
make_module "${FAILED_MIRROR_DIR}" '    mirror = {"null": "hashicorp/null:999.0.0"},'
if (cd "${FAILED_MIRROR_DIR}" && bazel build @tf_toolchains//...) >"${WORK}/failed-mirror.log" 2>&1; then
  cat "${WORK}/failed-mirror.log" >&2
  shutdown_bazel "${FAILED_MIRROR_DIR}"
  fail "[${ENGINE}] failed provider mirror produced a successful repository"
fi
cat "${WORK}/failed-mirror.log"
grep -qF '999.0.0' "${WORK}/failed-mirror.log" || fail "missing provider version diagnostic"
grep -qi 'mirror' "${WORK}/failed-mirror.log" || fail "missing mirror failure diagnostic"
shutdown_bazel "${FAILED_MIRROR_DIR}"
pass "[${ENGINE}] failed provider mirror fails repository setup"

info "[${ENGINE}] building fixture artefacts from the default download path"

DEFAULT_DIR="${WORK}/default"
make_module "${DEFAULT_DIR}" '    mirror = {
        "random": "hashicorp/random:3.3.2",
        "null": "hashicorp/null:3.1.1",
    },'

(cd "${DEFAULT_DIR}" && bazel build @tf_toolchains//... >/dev/null)

SRC_REPO="$(find_tf_repo "${DEFAULT_DIR}")"
[ -n "${SRC_REPO}" ] || fail "could not locate the generated toolchain repository"
[ -d "${SRC_REPO}/mirror" ] || fail "default path produced no mirror/ directory"
[ -d "${SRC_REPO}/${CLI_DIR}" ] || fail "default path produced no ${CLI_DIR}/ directory"

# The registry directory this engine actually uses, as produced by its own
# 'providers mirror' subprocess. This is what makes the reused fixtures
# trustworthy; that the *rule* writes pinned providers to the same place is
# asserted later, against the pinned repository.
[ -d "${SRC_REPO}/mirror/${REGISTRY}" ] \
  || fail "[${ENGINE}] default path did not lay the mirror out under ${REGISTRY}"

# The provider zips produced by the default path are reused verbatim as the
# origins the pinned path fetches from, so the fixtures cannot drift from the
# layout and naming the engine actually expects.
null_zip="${SRC_REPO}/mirror/${REGISTRY}/hashicorp/null/terraform-provider-null_${NULL_VERSION}_${host_os}_${host_arch}.zip"
random_zip="${SRC_REPO}/mirror/${REGISTRY}/hashicorp/random/terraform-provider-random_${RANDOM_VERSION}_${host_os}_${host_arch}.zip"
[ -f "${null_zip}" ] || fail "[${ENGINE}] expected provider zip not found: ${null_zip}"
[ -f "${random_zip}" ] || fail "[${ENGINE}] expected provider zip not found: ${random_zip}"
pass "[${ENGINE}] default mirror is laid out under ${REGISTRY}"

# The default path is the behaviour this change promises to leave untouched, so
# it has to be exercised end to end and not merely built. tests/bcr only ever
# configures terraform, so for OpenTofu this is the only such check anywhere.
(cd "${DEFAULT_DIR}" && bazel test --nocache_test_results "${VALIDATE_TARGETS[@]}" >/dev/null) \
  || fail "[${ENGINE}] the default, unpinned toolchain no longer validates"
pass "[${ENGINE}] the default, unpinned path still works end to end"

# Providers are served from two separate directories, standing in for the
# separate hosts real providers come from: publishers put them wherever they
# like, so per-entry URLs are the normal case rather than an edge case.
mkdir -p "${WORK}/origin-a" "${WORK}/origin-b"
cp "${null_zip}" "${WORK}/origin-a/null.zip"
cp "${random_zip}" "${WORK}/origin-b/random.zip"
NULL_SHA="$(sha256_of "${null_zip}")"
RANDOM_SHA="$(sha256_of "${random_zip}")"

# The CLI archive is packed from *inside* the directory so that its contents
# sit at the archive root, which is the layout the pinned path expects.
# A copy packed one level too deep, i.e. the containing directory was zipped
# instead of its contents. This is the layout mistake the post-extraction guard
# exists to catch.
python3 - "${SRC_REPO}" "${CLI_DIR}" "${WORK}" <<'PY'
from pathlib import Path
import sys
from zipfile import ZipFile, ZIP_DEFLATED

repository, cli_dir, work = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
source = repository / cli_dir
for name, base in [("cli.zip", source), ("wrapped_cli.zip", repository)]:
    with ZipFile(work / name, "w", compression=ZIP_DEFLATED) as archive:
        for file in sorted(source.rglob("*")):
            if file.is_file():
                archive.write(file, file.relative_to(base))
PY
shutdown_bazel "${DEFAULT_DIR}"

CLI_SHA="$(sha256_of "${WORK}/cli.zip")"
WRAPPED_CLI_SHA="$(sha256_of "${WORK}/wrapped_cli.zip")"

info "[${ENGINE}] host platform ${PLATFORM}"
info "[${ENGINE}] cli    ${CLI_SHA}"
info "[${ENGINE}] null   ${NULL_SHA}"
info "[${ENGINE}] random ${RANDOM_SHA}"

NULL_ADDR="${REGISTRY}/hashicorp/null"
RANDOM_ADDR="${REGISTRY}/hashicorp/random"

# Writes a CLI pins file. $1 is the destination path.
write_cli_pins() {
  { echo "{"; pin_entry "${CLI_DIR}" "${VERSION}" "file://${WORK}/cli.zip" "${CLI_SHA}"; echo "}"; } > "$1"
}

# Writes a provider pins file covering both providers, each from its own
# origin. $1 is the destination path.
write_provider_pins() {
  {
    echo "{"
    pin_entry "${NULL_ADDR}" "${NULL_VERSION}" "file://${WORK}/origin-a/null.zip" "${NULL_SHA}"
    echo ","
    pin_entry "${RANDOM_ADDR}" "${RANDOM_VERSION}" "file://${WORK}/origin-b/random.zip" "${RANDOM_SHA}"
    echo "}"
  } > "$1"
}

MIRROR_BOTH='    mirror = {
        "random": "hashicorp/random:3.3.2",
        "null": "hashicorp/null:3.1.1",
    },'

# ---------------------------------------------------------------------------
# Positive cases.
# ---------------------------------------------------------------------------

# Sets LAST_DIR to the module directory so callers can inspect the repository
# it generated. The directory is not echoed, because that would force the
# caller into a command substitution and swallow Bazel's test output.
#
# "$3", when given, is a function name called with the module directory before
# the build, so a case can drop pins files into the module.
LAST_DIR=""
expect_toolchain_works() {
  local name="$1" attrs="$2" setup="${3:-}" dir
  dir="${WORK}/ok-${name}"
  make_module "${dir}" "${attrs}"
  if [ -n "${setup}" ]; then
    "${setup}" "${dir}"
  fi
  if ! (cd "${dir}" && bazel test --nocache_test_results "${VALIDATE_TARGETS[@]}"); then
    fail "[${ENGINE}] ${name}: expected the toolchain to build and validate"
  fi
  LAST_DIR="${dir}"
}

setup_both() {
  write_cli_pins "$1/cli_pins.json"
  write_provider_pins "$1/provider_pins.json"
}
setup_cli_only() { write_cli_pins "$1/cli_pins.json"; }
setup_providers_only() { write_provider_pins "$1/provider_pins.json"; }

info "[${ENGINE}] case: CLI and providers both pinned"
ISOLATE_CACHE=1 expect_toolchain_works "full" "${MIRROR_BOTH}
    cli_pins = \"//:cli_pins.json\",
    provider_pins = \"//:provider_pins.json\"," setup_both
DIR="${LAST_DIR}"

OV_REPO="$(find_tf_repo "${DIR}")"
[ -n "${OV_REPO}" ] || fail "could not locate the pinned toolchain repository"

# Each absence below is only evidence if the default path actually produces the
# file. Without this control, renaming either artefact in toolchain.bzl would
# leave both assertions passing while testing nothing at all.
[ -e "${SRC_REPO}/versions.tf.json" ] || fail "control failed: default path produced no versions.tf.json"
[ -e "${SRC_REPO}/sha256sums" ] || fail "control failed: default path produced no sha256sums"

# The repository rule writes this marker before invoking the provider-mirroring
# subprocess, so its absence proves selection of the pinned branch only.
if [ -e "${OV_REPO}/versions.tf.json" ]; then
  fail "[${ENGINE}] provider mirror subprocess ran despite provider_pins"
fi
# sha256sums is fetched only by the default CLI download, so its absence is
# what proves cli_pins bypassed that fetch.
if [ -e "${OV_REPO}/sha256sums" ]; then
  fail "[${ENGINE}] checksum manifest was fetched despite cli_pins"
fi
# The rule always creates mirror/ (it writes a .keep file when nothing was
# pinned), so asserting the directory exists proves nothing. Assert instead that
# the providers are at the exact paths the engine looks for.
[ -f "${OV_REPO}/mirror/${REGISTRY}/hashicorp/null/terraform-provider-null_${NULL_VERSION}_${host_os}_${host_arch}.zip" ] \
  || fail "[${ENGINE}] pinned null provider is not at the canonical mirror path"
[ -f "${OV_REPO}/mirror/${REGISTRY}/hashicorp/random/terraform-provider-random_${RANDOM_VERSION}_${host_os}_${host_arch}.zip" ] \
  || fail "[${ENGINE}] pinned random provider is not at the canonical mirror path"
[ -x "${OV_REPO}/${CLI_DIR}/${ENGINE}" ] || fail "[${ENGINE}] pinned CLI is not executable"
shutdown_bazel "${DIR}"
pass "[${ENGINE}] CLI and provider pins bypass both network paths"
pass "[${ENGINE}] providers from two different origins land at the canonical paths"

# Isolated cache: the shared one is keyed by sha256 and would serve the bytes
# fetched by the case above without ever resolving these URLs.
info "[${ENGINE}] case: CLI pinned, providers still mirrored by the subprocess"
ISOLATE_CACHE=1 expect_toolchain_works "cli-only" "${MIRROR_BOTH}
    cli_pins = \"//:cli_pins.json\"," setup_cli_only
# Passing the validate targets is not evidence on its own: had cli_pins been
# ignored, the default download would have produced a working CLI and this case
# would pass anyway. The discriminating artefacts are the checksum manifest,
# which only the default CLI path fetches, and versions.tf.json, which the
# repository rule writes before it invokes the provider subprocess.
CLI_ONLY_REPO="$(find_tf_repo "${LAST_DIR}")"
[ ! -e "${CLI_ONLY_REPO}/sha256sums" ] || fail "[${ENGINE}] checksum manifest was fetched despite cli_pins"
[ -e "${CLI_ONLY_REPO}/versions.tf.json" ] || fail "[${ENGINE}] repository rule did not write the unpinned-branch marker"
shutdown_bazel "${LAST_DIR}"
pass "[${ENGINE}] CLI pins compose with the default provider mirroring"

info "[${ENGINE}] case: providers pinned, CLI downloaded normally"
ISOLATE_CACHE=1 expect_toolchain_works "providers-only" "${MIRROR_BOTH}
    provider_pins = \"//:provider_pins.json\"," setup_providers_only
# Same reasoning in the other direction: the default subprocess would have
# populated an equally valid mirror, so assert the artefacts that differ.
PROV_ONLY_REPO="$(find_tf_repo "${LAST_DIR}")"
[ ! -e "${PROV_ONLY_REPO}/versions.tf.json" ] || fail "[${ENGINE}] provider subprocess ran despite provider_pins"
[ -e "${PROV_ONLY_REPO}/sha256sums" ] || fail "[${ENGINE}] default CLI download did not run, so nothing was composed with"
[ -f "${PROV_ONLY_REPO}/mirror/${REGISTRY}/hashicorp/null/terraform-provider-null_${NULL_VERSION}_${host_os}_${host_arch}.zip" ] \
  || fail "[${ENGINE}] pinned provider is not at the canonical mirror path"
shutdown_bazel "${LAST_DIR}"
pass "[${ENGINE}] provider pins compose with the default CLI download"

# Registry addresses are lowercase, but call sites write the registry's display
# casing, which for many publishers is capitalised. Without the normalisation
# the lookup misses and the provider is written to the wrong directory.
info "[${ENGINE}] case: capitalised namespace in the mirror dictionary"
setup_capitalised() { write_provider_pins "$1/provider_pins.json"; }
ISOLATE_CACHE=1 expect_toolchain_works "capitalised-namespace" "    mirror = {
        \"random\": \"HashiCorp/random:3.3.2\",
        \"null\": \"HashiCorp/null:3.1.1\",
    },
    provider_pins = \"//:provider_pins.json\"," setup_capitalised
CAP_REPO="$(find_tf_repo "${LAST_DIR}")"
[ -f "${CAP_REPO}/mirror/${REGISTRY}/hashicorp/null/terraform-provider-null_${NULL_VERSION}_${host_os}_${host_arch}.zip" ] \
  || fail "[${ENGINE}] capitalised namespace was not normalised to the lowercase mirror path"
shutdown_bazel "${LAST_DIR}"
pass "[${ENGINE}] a capitalised namespace resolves to the lowercase registry address"

# ---------------------------------------------------------------------------
# Negative cases: misconfiguration must fail loudly, not silently misbehave.
# ---------------------------------------------------------------------------

# "$4", when given, is a function name called with the module directory before
# the build, so a case can drop pins files into the module.
expect_failure() {
  local name="$1" attrs="$2" expected="$3" setup="${4:-}" dir out
  dir="${WORK}/bad-${name}"
  make_module "${dir}" "${attrs}"
  if [ -n "${setup}" ]; then
    "${setup}" "${dir}"
  fi
  if out="$(cd "${dir}" && bazel build @tf_toolchains//... 2>&1)"; then
    fail "[${ENGINE}] ${name}: expected a configuration error, but the build succeeded"
  fi
  if ! grep -qF "${expected}" <<<"${out}"; then
    echo "${out}" >&2
    fail "[${ENGINE}] ${name}: error did not mention '${expected}'"
  fi
  shutdown_bazel "${dir}"
  pass "[${ENGINE}] ${name}"
}

# Bumping a provider in 'mirror' without regenerating the pins would otherwise
# surface as a bare checksum mismatch part-way through a large download.
info "[${ENGINE}] case: pinned version disagrees with the mirror dictionary"
setup_version_mismatch() { write_provider_pins "$1/provider_pins.json"; }
expect_failure "version-mismatch" "    mirror = {
        \"random\": \"hashicorp/random:3.3.2\",
        \"null\": \"hashicorp/null:9.9.9\",
    },
    provider_pins = \"//:provider_pins.json\"," \
  "but the build requires 9.9.9" setup_version_mismatch

info "[${ENGINE}] case: version-indexed pins reject a missing requested version"
setup_missing_requested_version() {
  cat > "$1/provider_pins.json" <<EOF
{
  "${NULL_ADDR}": {
    "versions": {
      "3.1.1": {
        "platforms": {
          "${PLATFORM}": {"url": "file://${WORK}/origin-a/null.zip", "sha256": "${NULL_SHA}"}
        }
      }
    }
  }
}
EOF
}
expect_failure "missing-requested-version" "    mirror = {\"null\": \"hashicorp/null:3.2.3\"},
    provider_pins = \"//:provider_pins.json\"," \
  "has no version 3.2.3. Available versions: 3.1.1" setup_missing_requested_version

info "[${ENGINE}] case: provider version maps are rejected for CLI pins"
setup_cli_versions() {
  cat > "$1/cli_pins.json" <<EOF
{
  "${CLI_DIR}": {
    "versions": {
      "${VERSION}": {
        "platforms": {
          "${PLATFORM}": {"url": "file://${WORK}/cli.zip", "sha256": "${CLI_SHA}"}
        }
      }
    }
  }
}
EOF
}
expect_failure "cli-version-map" "    mirror = {\"null\": \"hashicorp/null:3.1.1\"},
    cli_pins = \"//:cli_pins.json\"," \
  "must be an object with a 'platforms' field" setup_cli_versions

info "[${ENGINE}] case: provider versions reject mixed legacy fields"
setup_mixed_provider_versions() {
  cat > "$1/provider_pins.json" <<EOF
{
  "${NULL_ADDR}": {
    "version": "${NULL_VERSION}",
    "versions": {"${NULL_VERSION}": {"platforms": {}}}
  }
}
EOF
}
expect_failure "mixed-provider-version-map" "    mirror = {\"null\": \"hashicorp/null:${NULL_VERSION}\"},
    provider_pins = \"//:provider_pins.json\"," \
  "cannot combine 'versions' with 'version' or 'platforms'" setup_mixed_provider_versions

info "[${ENGINE}] case: provider versions map must not be empty"
setup_empty_provider_versions() {
  cat > "$1/provider_pins.json" <<EOF
{
  "${NULL_ADDR}": {"versions": {}}
}
EOF
}
expect_failure "empty-provider-version-map" "    mirror = {\"null\": \"hashicorp/null:${NULL_VERSION}\"},
    provider_pins = \"//:provider_pins.json\"," \
  "has an empty or non-object 'versions' map" setup_empty_provider_versions

info "[${ENGINE}] case: provider in the mirror dictionary is absent from the pins"
setup_missing_entry() {
  { echo "{"; pin_entry "${NULL_ADDR}" "${NULL_VERSION}" "file://${WORK}/origin-a/null.zip" "${NULL_SHA}"; echo "}"; } \
    > "$1/provider_pins.json"
}
expect_failure "missing-provider-entry" "${MIRROR_BOTH}
    provider_pins = \"//:provider_pins.json\"," \
  "has no entry for '${RANDOM_ADDR}'" setup_missing_entry

# The error has to name both what was wanted and what the file offers,
# otherwise a generated pins file missing one platform is opaque to debug.
info "[${ENGINE}] case: pins cover a platform that is not this host"
setup_wrong_platform() {
  cat > "$1/provider_pins.json" <<EOF
{
  "${NULL_ADDR}": {
    "version": "${NULL_VERSION}",
    "platforms": {
      "${OTHER_PLATFORM}": {"url": "file://${WORK}/origin-a/null.zip", "sha256": "${NULL_SHA}"}
    }
  }
}
EOF
}
expect_failure "wrong-platform" "    mirror = {\"null\": \"hashicorp/null:3.1.1\"},
    provider_pins = \"//:provider_pins.json\"," \
  "no pin for '${NULL_ADDR}' on platform '${PLATFORM}'" setup_wrong_platform

info "[${ENGINE}] case: pins name the supplied platforms in the error"
expect_failure "wrong-platform-lists-supplied" "    mirror = {\"null\": \"hashicorp/null:3.1.1\"},
    provider_pins = \"//:provider_pins.json\"," \
  "Supplied platforms: ${OTHER_PLATFORM}" setup_wrong_platform

info "[${ENGINE}] case: malformed digest in the pins file"
setup_malformed_digest() {
  { echo "{"; pin_entry "${CLI_DIR}" "${VERSION}" "file://${WORK}/cli.zip" "nothexadecimal"; echo "}"; } \
    > "$1/cli_pins.json"
}
expect_failure "malformed-digest" "    mirror = {\"null\": \"hashicorp/null:3.1.1\"},
    cli_pins = \"//:cli_pins.json\"," \
  "malformed 'sha256'" setup_malformed_digest

info "[${ENGINE}] case: digest is well formed but does not match the artefact"
# The format guard above fails before anything is fetched, so on its own it says
# nothing about integrity. This case is the one that proves tampered bytes are
# actually rejected --- which is the whole point of carrying a digest. The cache
# is isolated because a matching entry would otherwise short-circuit the fetch.
setup_digest_mismatch() {
  { echo "{"; pin_entry "${CLI_DIR}" "${VERSION}" "file://${WORK}/cli.zip" \
      "0000000000000000000000000000000000000000000000000000000000000000"; echo "}"; } \
    > "$1/cli_pins.json"
}
ISOLATE_CACHE=1 expect_failure "digest-mismatch" "    mirror = {\"null\": \"hashicorp/null:3.1.1\"},
    cli_pins = \"//:cli_pins.json\"," \
  "Checksum" setup_digest_mismatch

info "[${ENGINE}] case: provider digest is well formed but does not match the archive"
setup_provider_digest_mismatch() {
  cat > "$1/provider_pins.json" <<EOF
{
  "${NULL_ADDR}": {
    "version": "${NULL_VERSION}",
    "platforms": {
      "${PLATFORM}": {"url": "file://${WORK}/origin-a/null.zip", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"},
      "${OTHER_PLATFORM}": {"url": "file:///nonexistent/wrong-platform.zip", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}
    }
  }
}
EOF
}
ISOLATE_CACHE=1 expect_failure "provider-digest-mismatch" "    mirror = {\"null\": \"hashicorp/null:${NULL_VERSION}\"},
    provider_pins = \"//:provider_pins.json\"," \
  "Checksum" setup_provider_digest_mismatch

info "[${ENGINE}] case: pins file is not a JSON object"
setup_not_an_object() { echo '["not", "an", "object"]' > "$1/cli_pins.json"; }
expect_failure "pins-not-an-object" "    mirror = {\"null\": \"hashicorp/null:3.1.1\"},
    cli_pins = \"//:cli_pins.json\"," \
  "must contain a JSON object" setup_not_an_object

info "[${ENGINE}] case: pins file has no entry for the CLI"
setup_no_cli_entry() {
  { echo "{"; pin_entry "some-other-tool" "${VERSION}" "file://${WORK}/cli.zip" "${CLI_SHA}"; echo "}"; } \
    > "$1/cli_pins.json"
}
expect_failure "missing-cli-entry" "    mirror = {\"null\": \"hashicorp/null:3.1.1\"},
    cli_pins = \"//:cli_pins.json\"," \
  "has no entry for '${CLI_DIR}'" setup_no_cli_entry

info "[${ENGINE}] case: pins entry is missing its url"
setup_no_url() {
  cat > "$1/cli_pins.json" <<EOF
{
  "${CLI_DIR}": {
    "version": "${VERSION}",
    "platforms": {"${PLATFORM}": {"sha256": "${CLI_SHA}"}}
  }
}
EOF
}
expect_failure "pin-without-url" "    mirror = {\"null\": \"hashicorp/null:3.1.1\"},
    cli_pins = \"//:cli_pins.json\"," \
  "needs both 'url' and 'sha256'" setup_no_url

# The archive was packed one level too deep. This is the only coverage for the
# post-extraction layout guard, which is otherwise a user-facing error path
# that no test ever reaches.
info "[${ENGINE}] case: CLI archive with a wrapping directory"
setup_wrapped() {
  { echo "{"; pin_entry "${CLI_DIR}" "${VERSION}" "file://${WORK}/wrapped_cli.zip" "${WRAPPED_CLI_SHA}"; echo "}"; } \
    > "$1/cli_pins.json"
}
ISOLATE_CACHE=1 expect_failure "wrapped-cli-archive" "    mirror = {\"null\": \"hashicorp/null:3.1.1\"},
    cli_pins = \"//:cli_pins.json\"," \
  "does not contain the expected layout" setup_wrapped

info "[${ENGINE}] case: two locked roots select different pinned versions"
MULTI_DIR="${WORK}/multi-version"
make_module "${MULTI_DIR}" '    mirror = {
        "null_old": "hashicorp/null:3.1.1",
        "null_new": "hashicorp/null:3.2.3",
        "random": "hashicorp/random:3.3.2",
    },
    provider_pins = "//:provider_pins.json",'
CLI="${SRC_REPO}/${CLI_DIR}/${CLI_DIR}"
mkdir -p "${WORK}/new-release" "${WORK}/independent-mirror"
cat >"${WORK}/new-release/main.tf" <<'EOF'
terraform {
  required_providers {
    null = { source = "hashicorp/null", version = "= 3.2.3" }
  }
}
resource "null_resource" "probe" {}
EOF
"${CLI}" -chdir="${WORK}/new-release" providers mirror "${WORK}/independent-mirror"
NEW_ZIP="${WORK}/independent-mirror/${REGISTRY}/hashicorp/null/terraform-provider-null_3.2.3_${host_os}_${host_arch}.zip"
[ -f "${NEW_ZIP}" ] || fail "independently acquired null 3.2.3 archive missing"
NEW_SHA="$(sha256_of "${NEW_ZIP}")"
python3 - "${MULTI_DIR}/provider_pins.json" "${NULL_ADDR}" "${RANDOM_ADDR}" "${PLATFORM}" "${WORK}" "${NULL_SHA}" "${NEW_ZIP}" "${NEW_SHA}" "${RANDOM_SHA}" <<'PY'
import json
import sys
path, address, random, platform, work, old_sha, new_zip, new_sha, random_sha = sys.argv[1:]
def release(url, digest):
    return {"platforms": {platform: {"url": "file://" + url, "sha256": digest}}}
pins = {
    address: {"versions": {
        "3.1.1": release(work + "/origin-a/null.zip", old_sha),
        "3.2.3": release(new_zip, new_sha),
    }},
    random: {"version": "3.3.2", **release(work + "/origin-b/random.zip", random_sha)},
}
with open(path, "w") as output:
    json.dump(pins, output)
PY
for release in 3.1.1 3.2.3; do
  root="${MULTI_DIR}/root-${release}"
  mkdir -p "${root}"
  sed "s/3.2.3/${release}/" "${WORK}/new-release/main.tf" >"${root}/main.tf"
  "${CLI}" -chdir="${root}" init -backend=false -input=false -plugin-dir="${SRC_REPO}/mirror" -plugin-dir="${WORK}/independent-mirror"
  cp "${root}/.terraform.lock.hcl" "${WORK}/${release}.lock"
  find "${root}/.terraform" -type d -exec chmod u+w {} +
  rm -rf "${root}/.terraform"
  cat >"${root}/BUILD.bazel" <<'EOF'
load("@rules_tf//tf:def.bzl", "tf_module")
tf_module(name = "root")
EOF
done
(cd "${MULTI_DIR}" && bazel test //root-3.1.1:validate //root-3.2.3:validate) \
  || fail "two-version pinned toolchain cannot validate both locked roots"
MULTI_REPO="$(find_tf_repo "${MULTI_DIR}")"
for release in 3.1.1 3.2.3; do
  root="${MULTI_DIR}/root-${release}"
  [ -f "${MULTI_REPO}/mirror/${REGISTRY}/hashicorp/null/terraform-provider-null_${release}_${host_os}_${host_arch}.zip" ] \
    || fail "pinned mirror lost null ${release}"
  "${CLI}" -chdir="${root}" init -backend=false -input=false -lockfile=readonly -plugin-dir="${MULTI_REPO}/mirror"
  "${CLI}" -chdir="${root}" validate
  cmp "${WORK}/${release}.lock" "${root}/.terraform.lock.hcl" || fail "validation changed root lock ${release}"
done
shutdown_bazel "${MULTI_DIR}"
pass "[${ENGINE}] version-indexed null releases coexist with legacy random pins and readonly root locks"

# A check that is deleted, renamed away or short-circuited by an early return
# would otherwise leave the run green with a smaller number that nobody reads.
if [ "${PASSED}" -ne "${EXPECTED_CHECKS}" ]; then
  fail "[${ENGINE}] expected ${EXPECTED_CHECKS} checks, ran ${PASSED}"
fi

echo
echo "[${ENGINE}] ${PASSED} checks passed"
