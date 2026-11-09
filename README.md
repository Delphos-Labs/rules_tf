# Tf Rules

The Tf rules are useful to validate, lint and format terraform code.

They can typically be used in a terraform monorepo of modules to lint, run validation tests, auto generate documentation and enforce the consistency of Tf and providers versions across all modules.

# Why "Tf" and not "Terraform"

Because now you can either use "tofu" or "terraform" binary.

## Getting Started

### Pinning CLI and provider downloads

`tf.download` accepts optional `cli_pins` and `provider_pins` labels. Each JSON
file maps an artifact name or full provider registry address to a version and
platform-specific URL and SHA256 digest. When pins are absent, the existing
release checksum and provider mirror paths remain in use. If an unpinned
provider mirror fails, repository setup now stops and reports the engine
diagnostics instead of continuing with an incomplete mirror.

```python
tf.download(
    version = "1.12.0",
    use_tofu = True,
    mirror = {"null": "hashicorp/null:3.1.1"},
    cli_pins = "//:cli-pins.json",
    provider_pins = "//:provider-pins.json",
)
```

Each pin file is a JSON object. A CLI pin uses the artifact name, such as
`tofu`, as its key. A provider pin uses its full registry address, such as
`registry.opentofu.org/hashicorp/null`. CLI values have an exact `version` and a `platforms` object keyed by
`{os}/{arch}`, such as `linux/amd64`. Provider values support this legacy
shape or a `versions` object keyed by exact version. Each selected version has
a `platforms` object. Each platform value has a `url` and a 64-character
hexadecimal `sha256` digest.

```json
{
  "tofu": {
    "version": "1.12.0",
    "platforms": {
      "linux/amd64": {
        "url": "https://example.invalid/tofu.zip",
        "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
      }
    }
  }
}
```

Provider pins use the full provider address as the top-level key. Legacy entries
carry one version. To pin several versions of one address, use a version-indexed
entry:

```json
{
  "registry.opentofu.org/hashicorp/null": {
    "versions": {
      "3.1.1": {"platforms": {"linux/amd64": {"url": "https://example.invalid/null-3.1.1.zip", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}}},
      "3.2.3": {"platforms": {"linux/amd64": {"url": "https://example.invalid/null-3.2.3.zip", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}}}
    }
  }
}
```

Use separate mirror aliases to request both versions, such as `null_old` and
`null_new`. Aliases do not select pin entries. Terraform uses
`registry.terraform.io`; OpenTofu uses `registry.opentofu.org`. The exact version
must match the mirror request. Digests above are placeholders, not usable
checksums. Pins use public URLs. Configure Bazel's downloader to rewrite origins
when a proxy or mirror is required.

To import rules_tf in your project, you first need to add it to your `MODULE.bazel` file:

```python
bazel_dep(name = "rules_tf", version = "0.0.9")
# git_override(
#     module_name = "rules_tf",
#     remote      = "https://github.com/yanndegat/rules_tf",
#     commit      = "...",
# )

tf = use_extension("@rules_tf//tf:extensions.bzl", "tf_repositories", dev_dependency = True)
tf.download(
    version = "1.9.5",
    tflint_version = "0.53.0",
    tfdoc_version = "0.19.0",
    use_tofu = False,
    mirror = {
        "random" : "hashicorp/random:3.3.2",
        "null"   : "hashicorp/null:3.1.1",
    }
)

# Optional: pin tflint and terraform-docs per "{os}_{arch}" so Bazel can cache
# their repos. A platform without a pin uses the release's checksum file.
# tf.download(
#    ...
#    tflint_sha256 = {
#        "darwin_arm64": "2ba8eefe6cbd5d34e5a0589a8897646e4da44c48f4c2fd9a77581d1e2b03bff8",
#        "linux_amd64": "bb0a3a6043ea1bcd221fc95d49bac831bb511eb31946ca6a4050983e9e584578",
#    },
#    tfdoc_sha256 = {
#        "darwin_arm64": "c4e8d863571b8d5102089a22500426a18094855040eb07e4b83e4dfd1816dd23",
#        "linux_amd64": "dd741a0ece81059a478684b414d95d72b8b74fa58f50ac4036b4e8b56130d64b",
#    },
# )

# Switch to tofu
# tf = use_extension("@rules_tf//tf:extensions.bzl", "tf_repositories")
# tf.download(
#    version = "1.6.0",
#    use_tofu = True,
#    mirror = {
#        "random" : "hashicorp/random:3.3.2",
#        "null"   : "hashicorp/null:3.1.1",
#    }
# )

use_repo(tf, "tf_toolchains")
register_toolchains(
    "@tf_toolchains//:all",
    dev_dependency = True,
)
```

### Using Tf rules

#### Native configuration tests

`tf_module` admits configuration files ending in `.tf`, `.tf.json`, `.tofu`,
or `.tofu.json`. The selected engine owns parsing and filename precedence.
OpenTofu-only suffixes require OpenTofu. Admission does not promise that every
engine can read every admitted suffix.

Use `tf_test` to run the configured engine's native assertions against a private
copy of the module's declared, package-mapped files. Test inputs, local modules,
and a root `.terraform.lock.hcl` must be declared through the module mappings.
The rule initializes with the backend disabled. It is not a cloud security
sandbox. Native tests can still call provider APIs, so use plan-only or mocked
tests and do not pass live credentials.

```python
load("@rules_tf//tf:def.bzl", "tf_module", "tf_test")

tf_module(name = "network")
tf_test(name = "native_test", module = ":network")
```

Use `tf_validate_test` when you need engine validation without native test
assertions. It uses the same private staging, mapped inputs, configuration
isolation, and readonly lock behavior. This also describes the `validate`
target generated by `tf_module`; set `skip_validation = True` to omit that
macro-generated target. Validation now fails when initialization fails, and a
supplied lock file is readonly. Both validation paths use declared mappings,
including explicit mappings. They reject mapped `.terraform` paths.

```python
load("@rules_tf//tf/rules:tf-module.bzl", "tf_validate_test")

tf_validate_test(name = "explicit_validate", module = ":network")
```

The module package glob includes local test files and a root `.terraform.lock.hcl`.
Use `data` only for inputs outside that glob, such as files in another package.

The macro also includes local `.terraform` initialization output. `tf_test`
rejects these paths instead of using cached providers or state from your checkout.
For initialized modules, declare the inputs explicitly with `pkg_files` and the
low-level module rule. Keep the lock file, tests, templates, and local dependencies
in the declared inputs.

For Bzlmod, add `bazel_dep(name = "rules_pkg", version = "0.9.1")` to
`MODULE.bazel` so the example can load `@rules_pkg` directly.

```python
load("@rules_pkg//pkg:mappings.bzl", "pkg_files")
load("@rules_tf//tf:def.bzl", "tf_test")
load("@rules_tf//tf/rules:tf-module.bzl", native_module = "tf_module")

pkg_files(
    name = "native_sources",
    srcs = glob(
        ["**/*"],
        exclude = [
            ".terraform/**",
            "**/.terraform/**",
            "BUILD",
            "BUILD.bazel",
            "**/*.bzl",
        ],
    ),
    prefix = package_name(),
    strip_prefix = "",
)

native_module(
    name = "native_module",
    srcs = ":native_sources",
)

tf_test(
    name = "native_test",
    module = ":native_module",
)
```

Declare local module dependencies through `native_module`'s `deps` attribute.
Explicit and macro-generated validation use the declared mapped inputs in a private copy, isolate engine configuration, and keep supplied locks readonly. They fail if initialization fails. They reject mapped `.terraform` paths. Set `skip_validation = True` on `tf_module` to omit its generated validation target. This does not change macro packaging.

Registry modules can still require network access during initialization. Provider
pins do not pin or checksum remote module downloads. The launcher supports POSIX
directory runfiles on Linux and macOS.

OpenTofu toolchain compatibility follows the execution platform, not the target
CPU. The download remains specific to the repository host. This does not acquire
a runtime for a different remote execution host or prove native execution on a
different CPU.

The native rule and verified acquisition work reuse upstream contributions:
PR 28 by agentydragon and PR 30 by Sanath Manavarte. The implementation keeps
the repository's newer TFLint and terraform-docs checksum support.

Once you've imported the rule set, you can then load the tf rules in your `BUILD` files with:

```python
load("@rules_tf//tf:def.bzl", "tf_providers_versions", "tf_module")

tf_providers_versions(
    name = "providers",
    tf_version = "1.2.3",
    providers = {
        "random" : "hashicorp/random:>=3.3",
        "null"   : "hashicorp/null:>=3.1",
    },
)

tf_module(
    name = "root-mod-a",
    providers = [
        "random",
    ],
    deps = [
        "//tf/modules/mod-a",
    ],
    providers_versions = ":providers",
)
```

#### Provider Configuration Aliases

The `providers` parameter supports both string list format and dictionary format (for configuration aliases):

```python
# String list format (legacy)
tf_module(
    name = "simple-module",
    providers = [
        "random",
        "null",
    ],
    providers_versions = ":providers",
)

# Dictionary format (for provider aliases)
tf_module(
    name = "multi-provider-module",
    providers = {
        "random": {
            "configuration_aliases": ["random.primary", "random.secondary"]
        },
        "aws": {
            "configuration_aliases": ["aws.us_east_1", "aws.us_west_2"]
        }
    },
    providers_versions = ":providers",
)
```

The dictionary format allows you to specify `configuration_aliases` for providers that need multiple configurations, which is useful for multi-region deployments or when a module needs to work with multiple instances of the same provider.

#### Skipping Validation for Nested Modules

Modules that use provider configuration aliases are designed to be nested (called by other modules) and cannot be validated standalone because they don't have concrete provider configurations. For these modules, use `skip_validation = True`:

```python
# Nested module with provider aliases - cannot validate standalone
tf_module(
    name = "multi-region-module",
    providers = {
        "aws": {
            "configuration_aliases": ["aws.us_east_1", "aws.us_west_2"]
        }
    },
    providers_versions = "//tf:versions",
    skip_validation = True,  # Required for modules with configuration aliases
)

# Root module that uses the nested module - can validate
tf_module(
    name = "root-module",
    providers = ["aws"],
    deps = ["//tf/modules/multi-region-module"],
    providers_versions = "//tf:versions",
    # skip_validation = False (default) - root modules can be validated
)
```

This is necessary because Terraform cannot validate a module that declares configuration aliases without having concrete provider configurations passed to it from a parent module.

### Using prebuilt binaries

To ensure a consistent binary version across the team, you can create an alias to the prebuilt binaries:

```python
# Likewise for tofu, tfdoc, and tflint.
alias(
    name = "terraform",
    actual = "@tf_toolchains//:terraform",
)
```

And you can use `bazel run //:terraform` which uses the same version as configured in your `MODULE.bazel`.

## Using Tf Modules

1. Using custom tflint config file

```python
load("@rules_tf//tf:def.bzl", "tf_module")

filegroup(
    name = "tflint-custom-config",
    srcs = [
        "my-tflint-config.hcl",
    ],
)

tf_module(
    name = "mod-a",
    providers = [
        "random",
    ],
    ...
    tflint_config = ":tflint-custom-config"

)
```

1. Generating versions.tf.json files

Terraform linter by default requires that all providers used by a module
are versioned. It is possible to generate a versions.tf.json file by running
a dedicated target:

```python
load("@rules_tf//tf:def.bzl", "tf_providers_versions", "tf_module")

tf_providers_versions(
    name = "providers",
    tf_version = "1.2.3",
    providers = {
        "random" : "hashicorp/random:3.3.2",
        "null"   : "hashicorp/null:3.1.1",
    },
)

tf_module(
    name = "root-mod-a",
    providers = [
        "random",
    ],
    deps = [
        "//tf/modules/mod-a",
    ],

    providers_versions = ":providers",
)
```

``` bash
bazel run //path/to/root-mod-a:gen-tf-versions
```

or generate all files of a workspace:

``` bash
bazel cquery 'kind(tf_gen_versions, //...)' --output files | xargs -n1 bash
```

1. Generating terraform doc files

It is possible to generate a README.md file by running
a dedicated target for terraform modules:

```python
load("@rules_tf//tf:def.bzl", "tf_gen_doc")

tf_gen_doc(
    name = "tfgendoc",
    modules = ["//{}/{}".format(package_name(), m) for m in subpackages(include = ["**/*.tf"])],
)
```

and run the following command to generate docs for all sub packages.

``` bash
bazel run //path/to:tfgendoc
```

It is also possible to customize terraform docs config:

```python
load("@rules_tf//tf:def.bzl", "tf_gen_doc")

filegroup(
    name = "tfdoc-config",
    srcs = [
        "my-tfdoc-config.yaml",
    ],
)

tf_gen_doc(
    name   = "custom-tfgendoc",
    modules = ["//{}/{}".format(package_name(), m) for m in subpackages(include = ["**/*.tf"])],
    config = ":tfdoc-config",
)
```

1. Formatting terraform files

It is possible to format terraform files by running a dedicated target:

```python
load("@rules_tf//tf:def.bzl", "tf_format")


tf_format(
    name = "tffmt",
    modules = ["//{}/{}".format(package_name(), m) for m in subpackages(include = ["**/*.tf"])],
)
```

and run the following command to generate docs for all sub packages.

``` bash
bazel run //path/to:tffmt
```
