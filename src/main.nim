import strutils
import sdl2/[sdl, sdl_syswm]
import nim_logger as log

type
    LogCategories = enum
        LogGeneral = "G",
        LogSDL = "SDL",
        LogVulkan = "VK"

registerLogCategory(log.LogCategory(name: $LogGeneral, level: LTrace))
registerLogCategory(log.LogCategory(name: $LogSDL, level: LTrace))
registerLogCategory(log.LogCategory(name: $LogVulkan, level: LTrace))
registerLogProc(LogStandartProc.StdOut)

proc gLog(level: LogLevel, msg: string) =
    log $LogGeneral, level, msg

proc sdlLog(level: LogLevel, msg: string) =
    log $LogSDL, level, msg

proc vkLog(level: LogLevel, msg: string) =
    log $LogVulkan, level, msg

proc sdlCheck(res: cint, msg: string) =
    if res != 0:
        sdlLog(LCritical, msg & "\nSDL Message: " & $sdl.getError())
        quit(QuitFailure)

proc GetTime*(): float64 =
    return cast[float64](getPerformanceCounter()*1000) / cast[float64](getPerformanceFrequency())

sdlCheck sdl.init(0), "Failed to init :c"

var window: Window
window = createWindow(
    "SDL/Vulkan"
    , WINDOWPOS_UNDEFINED
    , WINDOWPOS_UNDEFINED
    , 1280, 720
    , WINDOW_SHOWN or WINDOW_RESIZABLE)
if window == nil:
    sdlLog LCritical, "Failed to create window!\nSDL Message: " & $sdl.getError()
    quit(QuitFailure)

var evt: sdl.Event

type
    WindowDimentions = object
        width, height, fullWidth, fullHeight : int32

proc getWindowDimentions(window : sdl.Window) : WindowDimentions =
    sdl.getWindowSize(window, addr result.fullWidth, addr result.fullHeight)
    sdl.glGetDrawableSize(window, addr result.width, addr result.height)

var windowDimentions = getWindowDimentions(window)

proc updateRenderResolution(winDim : WindowDimentions) =
    gLog LInfo, "Render resolution changed to: ($1, $2)".format(winDim.width, winDim.height)

updateRenderResolution(windowDimentions)

block GameLoop:
    while true:
        while sdl.pollEvent(evt.addr) == 1:
            if evt.kind == sdl.Quit:
                break GameLoop
            elif evt.kind == sdl.WINDOWEVENT:
                var windowEvent = cast[WindowEventObj](evt.addr)
                let newWindowDimensions = getWindowDimentions(window)
                if windowDimentions != newWindowDimensions:
                    updateRenderResolution(newWindowDimensions)
                    windowDimentions = newWindowDimensions

destroyWindow(window)
sdl.quit()