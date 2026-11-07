def _tree_impl(ctx):
    out = ctx.actions.declare_directory("tree.tf")
    ctx.actions.run_shell(outputs = [out], command = "mkdir -p \"$1\"", arguments = [out.path])
    return [DefaultInfo(files = depset([out]))]

tree = rule(implementation = _tree_impl)
