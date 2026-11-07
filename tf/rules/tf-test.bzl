load("@rules_tf//tf/rules:providers.bzl", "TfArtifactInfo", "TfModuleInfo")
load("@rules_tf//tf/rules:tf-staging.bzl", "collect_module_files", "staged_test")

def _tf_test_impl(ctx):
    return staged_test(ctx, "test", ctx.attr.test_directory)

tf_test = rule(
    implementation = _tf_test_impl,
    attrs = {
        "module": attr.label(mandatory = True, providers = [[TfModuleInfo], [TfArtifactInfo]], aspects = [collect_module_files]),
        "test_directory": attr.string(default = "tests"),
    },
    test = True,
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)
