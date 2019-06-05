import strformat
import nim_logger
export nim_logger

import sdl2/sdl except LogCategory
import vulkan as vk

type
    LogCategories* = enum
        LogGeneral = "G",
        LogSDL = "SDL",
        LogVulkan = "VK"

registerLogCategory(LogCategory(name: $LogGeneral, level: LTrace))
registerLogCategory(LogCategory(name: $LogSDL, level: LTrace))
registerLogCategory(LogCategory(name: $LogVulkan, level: LTrace))
registerLogProc(LogStandartProc.StdOut)

proc gLog*(level: LogLevel, msg: string) =
    log $LogGeneral, level, msg

proc sdlLog*(level: LogLevel, msg: string) =
    log $LogSDL, level, msg

proc vkLog*(level: LogLevel, msg: string) =
    log $LogVulkan, level, msg

proc check*(condition: bool, msg = "") =
    if not condition:
        if msg != "": gLog LCritical, msg
        gLog LCritical, "Check failed!"
        writeStackTrace()
        quit QuitFailure

proc sdlCheck*(res: cint, msg = "") =
    if res != 0:
        if msg != "": sdlLog LCritical, msg
        sdlLog LCritical, &"SDL Call Failed: {sdl.getError()}"
        writeStackTrace()
        quit QuitFailure

proc sdlCheck*(res: bool, msg = "") =
    if not res:
        if msg != "": sdlLog LCritical, msg
        sdlLog LCritical, &"SDL Call Failed: {sdl.getError()}"
        writeStackTrace()
        quit QuitFailure

proc vkCheck*(res: VkResult, msg = "") =
    if res != VkResult.success:
        if msg != "": vkLog LCritical, msg
        vkLog LCritical, &"Call failed: {res}"
        writeStackTrace()
        quit QuitFailure

proc vkCheck*(res: bool, msg = "") =
    if not res:
        if msg != "": vkLog LCritical, msg
        vkLog LCritical, &"Call failed: {res}"
        writeStackTrace()
        quit QuitFailure

macro vkCheck*(voidStatement: typed): untyped =
    voidStatement