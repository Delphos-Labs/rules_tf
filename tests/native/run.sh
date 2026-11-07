#!/usr/bin/env bash
# Exercise public native tests with actual engines in disposable consumer trees.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
LOGS="${RULES_TF_TEST_LOGS:-${ROOT}/.local/native-logs}"
mkdir -p "${LOGS}"
ACTIVE=""
cleanup() {
  local status=$?
  if [ -n "${ACTIVE}" ]; then
    (cd "${ACTIVE}" && bazel shutdown) || status=1
  fi
  rm -rf "${WORK}"
  exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$2" "$1" || fail "$1 does not contain $2"; }
sha() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
bzl() { (cd "${ACTIVE}" && bazel "$@"); }
test_ok() {
  local name="$1" expected="$2"
  shift 2
  bzl test --test_output=all "$@" 2>&1 | tee "${LOGS}/${ENGINE}-${name}.log"
  has "${LOGS}/${ENGINE}-${name}.log" "${expected}"
}
test_bad() {
  local name="$1" expected="$2"
  shift 2
  if bzl test --test_output=all "$@" >"${LOGS}/${ENGINE}-${name}.log" 2>&1; then
    fail "${name} unexpectedly passed"
  fi
  cat "${LOGS}/${ENGINE}-${name}.log"
  has "${LOGS}/${ENGINE}-${name}.log" "${expected}"
}
snapshot() {
  (cd "${ACTIVE}" && find basic assertion_failure init_failure locks mapped custom missing_input external_module -type f | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s %s\n' "$(sha "${file}")" "${file}"
  done)
}

for ENGINE in tofu terraform; do
  case "${ENGINE}" in
    tofu) VERSION=1.12.0; USE_TOFU=True ;;
    terraform) VERSION=1.9.5; USE_TOFU=False ;;
  esac
  ACTIVE="${WORK}/${ENGINE}"
  mkdir -p "${ACTIVE}"
  cp -R "${ROOT}/tests/native/fixtures/." "${ACTIVE}/"
  touch "${ACTIVE}/WORKSPACE" "${ACTIVE}/WORKSPACE.bzlmod"
  cp "${ROOT}/.bazelversion" "${ACTIVE}/.bazelversion"
  cat >"${ACTIVE}/.bazelrc" <<EOF
common --enable_bzlmod
common --symlink_prefix=${WORK}/bazel-
common --repository_cache=${WORK}/repository-cache
test --test_output=errors
EOF
  cat >"${ACTIVE}/MODULE.bazel" <<EOF
module(name = "native_consumer")
bazel_dep(name = "rules_tf", version = "")
local_path_override(module_name = "rules_tf", path = "${ROOT}")
bazel_dep(name = "rules_pkg", version = "0.9.1")
bazel_dep(name = "external_module", version = "")
local_path_override(module_name = "external_module", path = "${ACTIVE}/external_module")
tf = use_extension("@rules_tf//tf:extensions.bzl", "tf_repositories")
tf.download(version = "${VERSION}", use_tofu = ${USE_TOFU}, mirror = {"null": "hashicorp/null:3.1.1", "aws": "hashicorp/aws:6.17.0", "random": "hashicorp/random:3.6.3"})
use_repo(tf, "tf_toolchains")
register_toolchains("@tf_toolchains//:all")
EOF
  cat >"${ACTIVE}/BUILD.bazel" <<EOF
load("@rules_tf//tf:def.bzl", "tf_module", "tf_test")
alias(name = "engine", actual = "@tf_toolchains//:${ENGINE}")
tf_module(name = "root")
tf_test(name = "root_test", module = ":module")
tf_test(name = "external_test", module = "@external_module//:external")
EOF
  cp "${ACTIVE}/basic/main.tf" "${ACTIVE}/main.tf"
  mkdir -p "${ACTIVE}/tests" "${ACTIVE}/external_module/tests"
  cp "${ACTIVE}/basic/tests/answer.tftest.hcl" "${ACTIVE}/tests/"
  cp "${ACTIVE}/basic/main.tf" "${ACTIVE}/external_module/"
  cp "${ACTIVE}/basic/tests/answer.tftest.hcl" "${ACTIVE}/external_module/tests/"
  cat >"${ACTIVE}/external_module/MODULE.bazel" <<EOF
module(name = "external_module")
bazel_dep(name = "rules_tf", version = "")
EOF
  touch "${ACTIVE}/external_module/WORKSPACE" "${ACTIVE}/external_module/WORKSPACE.bzlmod"
  cat >"${ACTIVE}/external_module/BUILD.bazel" <<'EOF'
load("@rules_tf//tf:def.bzl", "tf_module")
tf_module(name = "external")
EOF

  bzl build //:engine
  OUTPUT="$(bzl info output_base)"
  REPOS=()
  for candidate in "${OUTPUT}"/external/*download_tf_0*; do
    [ -d "${candidate}" ] && REPOS+=("${candidate}")
  done
  [ "${#REPOS[@]}" -eq 1 ] || fail "ambiguous toolchain repository"
  MIRROR="${REPOS[0]}/mirror"
  CLI="${REPOS[0]}/${ENGINE}/${ENGINE}"
  "${CLI}" version | tee "${LOGS}/${ENGINE}-version.log"
  has "${LOGS}/${ENGINE}-version.log" "${VERSION}"

  # The real engine establishes package-hash provenance before lock mutations.
  mkdir -p "${WORK}/${ENGINE}-lock"
  cp "${ACTIVE}/locks/main.tf" "${WORK}/${ENGINE}-lock/"
  "${CLI}" -chdir="${WORK}/${ENGINE}-lock" init -backend=false -input=false -plugin-dir="${MIRROR}"
  cp "${WORK}/${ENGINE}-lock/.terraform.lock.hcl" "${ACTIVE}/locks/"
  cp "${ACTIVE}/locks/.terraform.lock.hcl" "${WORK}/${ENGINE}-valid.lock"
  snapshot >"${WORK}/before"

  # A no-op or validation-only launcher cannot produce named successful runs.
  test_ok basic declared_answer //basic:native_test //basic:concurrent_test
  test_bad forwarded-args 'flag provided but not defined' //basic:forwarded_args_test
  test_ok root declared_answer //:root_test //:external_test
  test_ok mappings mapped_closure //mapped:native_test
  test_ok custom custom_directory //custom:native_test
  test_bad assertion NATIVE_EXPECTED_FAILURE //assertion_failure:native_test
  test_bad init 'hashicorp/random' //init_failure:native_test
  if grep -qE 'must_not_execute|NATIVE_INIT_DID_NOT_STOP' "${LOGS}/${ENGINE}-init.log"; then
    fail "native test ran after failed initialization"
  fi
  test_bad undeclared undeclared.txt //missing_input:native_test
  test_bad analysis-conflict 'conflicting destination' //negative:conflict_test
  test_bad analysis-escape 'escapes' //negative:escape_test
  test_bad analysis-ancestor 'ancestor of' //negative:ancestor_test
  test_bad analysis-directory 'directory artifact' //negative:directory_test
  test_bad analysis-symlink 'symlink entries' //negative:symlink_test
  test_bad analysis-terraform-dir '.terraform path' //negative:terraform_dir_test
   test_bad invalid-test-directory 'tf_test test_directory must be relative and must not contain parent traversal' //negative:invalid_test_directory_test
  test_ok lock locked_answer //locks:native_test
  cat >"${WORK}/host.tfrc" <<'EOF'
provider_installation {
  dev_overrides {
    "hashicorp/null" = "/nonexistent/native-test-host-provider"
  }
  direct {}
}
EOF
  test_ok environment locked_answer --test_env="TF_CLI_CONFIG_FILE=${WORK}/host.tfrc" --test_env=TF_CLI_ARGS_test=-invalid-flag --test_env=TF_CLI_ARGS_init=-invalid-flag --test_env=TF_DATA_DIR=/unwritable --test_env=TF_PLUGIN_CACHE_DIR=/unwritable //locks:native_test
  snapshot >"${WORK}/after"
  cmp "${WORK}/before" "${WORK}/after" || fail "native tests modified input files"
  [ -z "$(find "${ACTIVE}/basic" "${ACTIVE}/locks" -name .terraform -print)" ] || fail "native test initialized checkout"

  # Normal test caching stays enabled during every mutation.
  sed 's/value = 7/value = 8/' "${ROOT}/tests/native/fixtures/basic/main.tf" >"${ACTIVE}/basic/main.tf"
  test_bad changed-config NATIVE_ANSWER_MISMATCH //basic:native_test
  cp "${ROOT}/tests/native/fixtures/basic/main.tf" "${ACTIVE}/basic/main.tf"
  sed 's/== 7/== 8/' "${ROOT}/tests/native/fixtures/basic/tests/answer.tftest.hcl" >"${ACTIVE}/basic/tests/answer.tftest.hcl"
  test_bad changed-test NATIVE_ANSWER_MISMATCH //basic:native_test
  cp "${ROOT}/tests/native/fixtures/basic/tests/answer.tftest.hcl" "${ACTIVE}/basic/tests/answer.tftest.hcl"
  sed 's/value = 7/value = 8/' "${ACTIVE}/mapped/BUILD.bazel" >"${WORK}/changed-build"
  cp "${WORK}/changed-build" "${ACTIVE}/mapped/BUILD.bazel"
  test_bad changed-dependency NATIVE_MAPPED_CLOSURE_MISMATCH //mapped:native_test
  cp "${ROOT}/tests/native/fixtures/mapped/BUILD.bazel" "${ACTIVE}/mapped/BUILD.bazel"
  sed -E 's/(h1:|zh:)[A-Za-z0-9+\/=]+/zh:0000000000000000000000000000000000000000000000000000000000000000/g' "${WORK}/${ENGINE}-valid.lock" >"${ACTIVE}/locks/.terraform.lock.hcl"
  test_bad changed-lock checksums //locks:native_test
  sed 's/3.1.1/3.0.0/g' "${WORK}/${ENGINE}-valid.lock" >"${ACTIVE}/locks/.terraform.lock.hcl"
   test_bad incompatible-lock 'locked provider' //locks:native_test
  cp "${WORK}/${ENGINE}-valid.lock" "${ACTIVE}/locks/.terraform.lock.hcl"
  mv "${ACTIVE}/locks/.terraform.lock.hcl" "${WORK}/${ENGINE}-removed.lock"
  test_ok absent-lock locked_answer //locks:native_test
  [ ! -e "${ACTIVE}/locks/.terraform.lock.hcl" ] || fail 'native test wrote a source lock'
  mv "${WORK}/${ENGINE}-removed.lock" "${ACTIVE}/locks/.terraform.lock.hcl"
  snapshot >"${WORK}/restored"
  cmp "${WORK}/before" "${WORK}/restored" || fail "mutation restoration failed"
  test_ok restored declared_answer //basic:native_test

  bzl aquery 'deps(//basic:native_test)' --output=textproto >"${LOGS}/${ENGINE}-actions.txt"
  if grep -E 'mnemonic: ".*(Compile|Link)' "${LOGS}/${ENGINE}-actions.txt"; then
    fail "native test unexpectedly compiles a helper"
  fi

  # Registry access is a distinct qualification, never a passing local case.
  if [ "${ENGINE}" = tofu ]; then
    mkdir -p "${WORK}/registry"
    cp "${ROOT}/tests/native/registry/main.tf" "${WORK}/registry/"
    set +e
    "${CLI}" -chdir="${WORK}/registry" init -backend=false -input=false -no-color -plugin-dir="${MIRROR}" >"${LOGS}/registry-init.log" 2>&1
    registry_status=$?
    set -e
    cat "${LOGS}/registry-init.log"
    printf 'OpenTofu %s init exit status: %s\n' "${VERSION}" "${registry_status}" >"${LOGS}/registry-status.txt"
    if [ "${registry_status}" -eq 0 ]; then
      has "${WORK}/registry/.terraform/modules/modules.json" '4.2.2'
      has "${WORK}/registry/.terraform/modules/modules.json" '6.2.3'
      has "${WORK}/registry/.terraform/modules/modules.json" 'modules/iam-policy'
      cp "${WORK}/registry/.terraform/modules/modules.json" "${LOGS}/registry-modules.json"
      echo 'QUALIFIED: registry module installation' | tee -a "${LOGS}/registry-status.txt"
    elif grep -Eiq '403|Forbidden|[Tt]imeout|[Nn]o such host|[Cc]ould not resolve|[Cc]onnection refused|[Nn]etwork is unreachable' "${LOGS}/registry-init.log"; then
      echo 'UNQUALIFIED: external access failed, see registry-init.log' | tee -a "${LOGS}/registry-status.txt"
    else
      fail 'unexpected registry initialization failure'
    fi
  fi
  bzl shutdown
  ACTIVE=""
  echo "PASS: ${ENGINE} native behavior, isolation, locks, mapped inputs and cache sensitivity"
done
echo "Native logs: ${LOGS}"
