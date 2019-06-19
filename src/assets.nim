import render/render_vk
import nimPNG

proc asLoadColorTexture*(path: string, renderContext: var RdContext): RdTexture =
    type
        PNGPixel {.packed.} = object
            r, g, b, a: uint8
    
    var
        png = loadPNG32(path)
        pngPixels = cast[ptr UncheckedArray[PNGPixel]](addr png.data[0])
        rawImageData = RdRawImageData(
            width: uint32 png.width
            , height: uint32 png.height
            , format: RdRawImageFormat.RGBAFloat32
            , pixelsRGBAFloat32: newSeq[RdRawImagePixelRGBAFloat32](png.width * png.height)
        )
    
    for i in 0 ..< png.width * png.height:
        let p = pngPixels[i]
        rawImageData.pixelsRGBAFloat32[i] = RdRawImagePixelRGBAFloat32(
            r: float32(p.r) / 256.0'f32
            , g: float32(p.g) / 256.0'f32
            , b: float32(p.b) / 256.0'f32
            , a: float32(p.a) / 256.0'f32
        )
    
    rdCreateTexture(renderContext, rawImageData)