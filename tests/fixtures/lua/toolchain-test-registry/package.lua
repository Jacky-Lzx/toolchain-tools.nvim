return {
  schema = "registry+v1",
  name = "toolchain-fixture",
  description = "Offline integration fixture",
  homepage = "https://example.invalid",
  licenses = { "MIT" },
  languages = {},
  categories = {},
  source = {
    id = "pkg:mason/toolchain-fixture@1.0.0",
    install = function(ctx)
      ctx.fs:write_file("toolchain-fixture", "#!/bin/sh\nprintf 'toolchain fixture\\n'\n")
      ctx.fs:chmod_exec("toolchain-fixture")
      ctx.stdio_sink:stdout("Created offline fixture executable\n")
    end,
  },
  bin = { ["toolchain-fixture"] = "toolchain-fixture" },
}
