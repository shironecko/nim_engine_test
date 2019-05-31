import nim_logger as log
export log

import sdl2/sdl
import vulkan as vk

type
    LogCategories* = enum
        LogGeneral = "G",
        LogSDL = "SDL",
        LogVulkan = "VK"

registerLogCategory(log.LogCategory(name: $LogGeneral, level: LTrace))
registerLogCategory(log.LogCategory(name: $LogSDL, level: LTrace))
registerLogCategory(log.LogCategory(name: $LogVulkan, level: LTrace))
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
        quit QuitFailure

proc sdlCheck*(res: cint, msg = "") =
    if res != 0:
        if msg != "": sdlLog LCritical, msg
        sdlLog LCritical, "SDL Call Failed: " & $sdl.getError()
        quit QuitFailure

proc sdlCheck*(res: bool, msg = "") =
    if not res:
        if msg != "": sdlLog LCritical, msg
        sdlLog LCritical, "SDL Call Failed: " & $sdl.getError()
        quit QuitFailure

proc vkCheck*(res: VkResult, msg = "") =
    if res != VkResult.success:
        if msg != "": vkLog LCritical, msg
        vkLog LCritical, "Call failed: " & $res
        quit QuitFailure

proc vkCheck*(res: bool, msg = "") =
    if not res:
        if msg != "": vkLog LCritical, msg
        vkLog LCritical, "Call failed: " & $res
        quit QuitFailure