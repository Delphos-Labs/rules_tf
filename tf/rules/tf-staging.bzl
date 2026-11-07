load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_pkg//pkg:providers.bzl", "PackageFilegroupInfo", "PackageFilesInfo")
load("@rules_tf//tf/rules:providers.bzl", "TfArtifactInfo", "TfModuleInfo")

TfStagedFilesInfo = provider(fields = ["files"])

def _merge_files(target, files):
    def add(destination, file):
        if destination in files and files[destination] != file:
            fail("tf_test conflicting destination '{}': {} and {}".format(destination, files[destination].short_path, file.short_path))
        files[destination] = file

    if TfArtifactInfo in target:
        return
    if TfModuleInfo in target:
        for destination, file in target[TfModuleInfo].files[PackageFilesInfo].dest_src_map.items():
            add(destination, file)
    elif PackageFilegroupInfo in target:
        for package_files, _origin in target[PackageFilegroupInfo].pkg_files:
            for destination, file in package_files.dest_src_map.items():
                add(destination, file)
        if target[PackageFilegroupInfo].pkg_dirs or target[PackageFilegroupInfo].pkg_symlinks:
            fail("tf_test does not support directory or symlink entries in package groups")
    elif PackageFilesInfo in target:
        for destination, file in target[PackageFilesInfo].dest_src_map.items():
            add(destination, file)

def _collect_impl(target, ctx):
    files = {}
    if TfArtifactInfo in target:
        child = ctx.rule.attr.module
        if TfStagedFilesInfo in child:
            _merge_files(child, files)
            files.update(child[TfStagedFilesInfo].files)
    else:
        _merge_files(target, files)
    if TfModuleInfo in target and not TfArtifactInfo in target:
        for dep in ctx.rule.attr.deps:
            if TfStagedFilesInfo in dep:
                _merge_files(dep, files)
                for destination, file in dep[TfStagedFilesInfo].files.items():
                    if destination in files and files[destination] != file:
                        fail("tf_test conflicting destination '{}': {} and {}".format(destination, files[destination].short_path, file.short_path))
                    files[destination] = file
    return [TfStagedFilesInfo(files = files)]

collect_module_files = aspect(implementation = _collect_impl, attr_aspects = ["deps", "module"])

def _validate_destination(destination, source):
    if not destination or destination.startswith("/") or "\\" in destination:
        fail("tf_test has invalid mapped file destination '{}' from {}".format(destination, source))
    normalized = paths.normalize(destination)
    if normalized == ".." or normalized.startswith("../"):
        fail("tf_test destination '{}' escapes the staged root".format(destination))
    if ".terraform" in normalized.split("/"):
        fail("tf_test does not allow a .terraform path component: {}".format(destination))
    return normalized

def _runfile_key(file, workspace):
    short = file.short_path
    return short[3:] if short.startswith("../") else paths.join(workspace, short)

def staged_test(ctx, command, test_directory = None):
    if command not in ["test", "validate"]:
        fail("staged_test command must be 'test' or 'validate', got {}".format(repr(command)))
    module_target = ctx.attr.module
    if TfArtifactInfo in module_target:
        module_target = module_target[TfArtifactInfo].module
    module = module_target[TfModuleInfo]
    runtime = ctx.toolchains["@rules_tf//:tf_toolchain_type"].runtime
    destinations = {}
    for destination, file in ctx.attr.module[TfStagedFilesInfo].files.items():
        destination = _validate_destination(destination, file.short_path)
        if file.is_directory:
            fail("tf_test does not support directory artifact at '{}'".format(destination))
        if destination in destinations and destinations[destination] != file:
            fail("tf_test conflicting destination '{}': {} and {}".format(destination, destinations[destination].short_path, file.short_path))
        destinations[destination] = file
    for destination in destinations:
        for other in destinations:
            if other.startswith(destination + "/"):
                fail("tf_test file destination '{}' is an ancestor of '{}'".format(destination, other))
    entries = ["  mkdir -p \"$tree/$(dirname {dest})\"\n  cp -L \"$RUNFILES\"/{src} \"$tree\"/{dest}".format(dest = shell.quote(destination), src = shell.quote(_runfile_key(file, ctx.workspace_name))) for destination, file in sorted(destinations.items())]
    module_path = paths.normalize(module.module_path) if module.module_path else "."
    args = ""
    if command == "test":
        if test_directory.startswith("/") or "\\" in test_directory or ".." in test_directory.split("/"):
            fail("tf_test test_directory must be relative and must not contain parent traversal")
        test_directory = paths.normalize(test_directory) or "."
        if test_directory not in ["", "."]:
            test_directory = _validate_destination(test_directory, "test_directory")
        args = "-test-directory=" + shell.quote(test_directory)
    runfiles = ctx.runfiles(files = destinations.values() + runtime.deps)
    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    tail = 'exec "$engine" test "$@" -no-color ' + args if command == "test" else 'exec "$engine" validate -no-color'
    init_extra = ' -test-directory=' + shell.quote(test_directory) if command == "test" else ""
    script = '''#!/usr/bin/env bash
set -euo pipefail
: "${{TEST_TMPDIR:?Bazel must set TEST_TMPDIR}}"
: "${{TEST_SRCDIR:?Bazel must set TEST_SRCDIR}}"
RUNFILES="$TEST_SRCDIR"
tree="$(mktemp -d "$TEST_TMPDIR/tf-test.XXXXXXXX")/tree"
mkdir -p "$tree"
{copy}
home="$(dirname "$tree")/home"
mkdir -p "$home/.config"
cd "$tree"/{module_path}
export HOME="$home" XDG_CONFIG_HOME="$home/.config" TF_CLI_CONFIG_FILE="$home/.tfrc"
unset TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_test TF_CLI_ARGS_validate TF_DATA_DIR TF_PLUGIN_CACHE_DIR TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE || true
export TF_IN_AUTOMATION=1 TF_INPUT=0
touch "$TF_CLI_CONFIG_FILE"
engine="$RUNFILES"/{engine}
mirror="$RUNFILES"/{mirror}
init_args=(-backend=false -input=false -no-color{init_extra} -plugin-dir="$mirror")
if [ -f .terraform.lock.hcl ]; then init_args+=( -lockfile=readonly ); fi
"$engine" init "${{init_args[@]}}"
{tail}
'''.format(copy = "\n".join(entries), module_path = shell.quote(module_path), engine = shell.quote(_runfile_key(runtime.tf, ctx.workspace_name)), mirror = shell.quote(_runfile_key(runtime.mirror, ctx.workspace_name)), init_extra = init_extra, tail = tail)
    ctx.actions.write(launcher, script, is_executable = True)
    return [DefaultInfo(executable = launcher, runfiles = runfiles)]
