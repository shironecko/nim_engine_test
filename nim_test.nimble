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

requires "nim >= 0.20.0"
requires "sdl2"
requires "nim_logger >= 0.1.0"
requires "vulkan >= 0.2"
requires "glm"