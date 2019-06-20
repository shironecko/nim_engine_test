import render/render_vk
import sdl2
import sdl2/image as img

proc asLoadColorTexture*(path: string, renderContext: var RdContext): RdTexture =
    var
        surface = img.load(path)
        rawImageData = RdRawImageData(
            width: uint32 surface.w
            , height: uint32 surface.h
            , format: RdRawImageFormat.RGBAFloat32
            , pixelsRGBAFloat32: newSeq[RdRawImagePixelRGBAFloat32](surface.w * surface.h)
        )
    
    if surface.format.format != SDL_PIXELFORMAT_RGBA8888:
        var tempPtr = convertSurfaceFormat(surface, SDL_PIXELFORMAT_RGBA8888, 0)
        freeSurface(surface)
        surface = tempPtr
    
    # TODO: implement more robust convertion using color masks?
    type
        SurfacePixel {.packed.} = object
            a: uint8
            b: uint8
            g: uint8
            r: uint8
    
    for y in 0..<surface.h:
        for x in 0..<surface.w:
            let 
                pixelOffset = x * 4 + y * surface.pitch
                pixelsAsBytesArray = cast[ptr UncheckedArray[uint8]](surface.pixels)
                surfacePixel = cast[ptr SurfacePixel](addr pixelsAsBytesArray[pixelOffset])
            rawImageData.pixelsRGBAFloat32[x + y * surface.w] = RdRawImagePixelRGBAFloat32(
                r: float32(surfacePixel.r) / 256.0'f32
                , g: float32(surfacePixel.g) / 256.0'f32
                , b: float32(surfacePixel.b) / 256.0'f32
                , a: float32(surfacePixel.a) / 256.0'f32
            )
    
    freeSurface(surface)
    rdCreateTexture(renderContext, rawImageData)