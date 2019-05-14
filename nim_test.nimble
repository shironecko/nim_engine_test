# Package

version       = "0.1.0"
author        = "shiro"
description   = "Testing out NIM language to see if it'll suit my needs."
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
backend       = "c"
bin           = @["main"]
skipExt       = @["nim"]

# Deps

requires "nim >= 0.19.4"
requires "sdl2_nim >= 2.0.9.2"
requires "nim_logger >= 0.1.0"
requires "vulkan >= 0.2"
when defined(windows):
    requires "oldwinapi >= 2.1.0"
    