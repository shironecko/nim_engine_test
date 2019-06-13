import strutils
import sequtils
import sugar
import strformat
import glm
import log
import sdl2
import vulkan as vk except vkCreateDebugReportCallbackEXT, vkDestroyDebugReportCallbackEXT
import render/vulkan_wrapper
import render/render_vk
import utility

proc GetTime*(): float64 =
    return cast[float64](getPerformanceCounter()*1000) / cast[float64](getPerformanceFrequency())

sdlCheck sdl2.init(INIT_EVERYTHING), "Failed to init :c"

const
    prefferedWidth = 640
    prefferedHeight = 480

var window: WindowPtr
window = createWindow(
    "SDL/Vulkan"
    , SDL_WINDOWPOS_UNDEFINED
    , SDL_WINDOWPOS_UNDEFINED
    , prefferedWidth, prefferedHeight
    , uint32 maskCombine(SDL_WINDOW_SHOWN, rdGetRequiredSDLWindowFlags())
)
sdlCheck window != nil, "Failed to create window!"

type
    WindowDimentions = object
        width, height, fullWidth, fullHeight : int32

proc getWindowDimentions(window : WindowPtr) : WindowDimentions =
    sdl2.getSize(window, result.fullWidth, result.fullHeight)
    sdl2.vulkanGetDrawableSize(window, addr result.width, addr result.height)

var windowDimentions = getWindowDimentions(window)

var renderContext = rdPreInitialize(window)

let renderDevices = rdGetCompatiblePhysicalDevices(renderContext)
check renderDevices.len() != 0, "Failed to find any render compatible devices!"

gLog LTrace, "[Compatible Devices]"
for d in renderDevices: gLog LTrace, &"\t{d.name}({d.deviceType}, {d.vendor})"
let selectedRenderDevice = renderDevices[0]
gLog LInfo, &"Selected render device: {selectedRenderDevice.name}"

rdInitialize(renderContext, selectedRenderDevice)

proc updateRenderResolution(winDim : WindowDimentions) =
    gLog LInfo, &"Render resolution changed to: ({winDim.width}, {winDim.height})"

updateRenderResolution(windowDimentions)

var
    evt: sdl2.Event
    cameraPosition = vec3f(0.0'f32)
    lastPC = getPerformanceCounter()
block GameLoop:
    while true:
        while sdl2.pollEvent(evt) == True32:
            case evt.kind:
                of QuitEvent:
                    break GameLoop
                of WindowEvent:
                    var windowEvent = cast[WindowEventObj](addr evt)
                    let newWindowDimensions = getWindowDimentions(window)
                    if windowDimentions != newWindowDimensions:
                        updateRenderResolution(newWindowDimensions)
                        windowDimentions = newWindowDimensions
                else: discard
        
        let 
            keys = getKeyboardState(nil)
            cameraSpeed = 100.0'f32
            pc = getPerformanceCounter()
            dt = float32(float64(pc - lastPC) / float64(getPerformanceFrequency()))
        lastPC = pc

        if keys[int SDL_SCANCODE_ESCAPE] == 1:
            break GameLoop

        if keys[int SDL_SCANCODE_A] == 1:
            cameraPosition.x -= cameraSpeed * dt
        if keys[int SDL_SCANCODE_D] == 1:
            cameraPosition.x += cameraSpeed * dt
        if keys[int SDL_SCANCODE_W] == 1:
            cameraPosition.y -= cameraSpeed * dt
        if keys[int SDL_SCANCODE_S] == 1:
            cameraPosition.y += cameraSpeed * dt
        
        var renderList = RdRenderList(sprites: @[
                RdSpriteRenderRequest(x: 0, y: 0, w: 128, h: 128, minUV: vec2f(0, 0), maxUV: vec2f(0.25, 0.25))
                , RdSpriteRenderRequest(x: 150, y: 0, w: 128, h: 128, minUV: vec2f(0.25, 0), maxUV: vec2f(0.5, 0.25))
                # , RdSpriteRenderRequest(x: 300, y: 0, w: 128, h: 128, minUV: vec2f(0.5, 0), maxUV: vec2f(0.75, 0.25))
                # , RdSpriteRenderRequest(x: 450, y: 0, w: 128, h: 128, minUV: vec2f(0.75, 0), maxUV: vec2f(1, 0.25))
                # , RdSpriteRenderRequest(x: 0, y: 150, w: 128, h: 128, minUV: vec2f(0, 0.25), maxUV: vec2f(0.25, 0.5))
                # , RdSpriteRenderRequest(x: 0, y: 300, w: 128, h: 128, minUV: vec2f(0.25, 0.25), maxUV: vec2f(0.5, 0.5))
            ])
        rdRenderAndPresent(renderContext, cameraPosition, renderList)

destroyWindow(window)
sdl2.quit()