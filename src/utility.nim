import sequtils
import strformat
import log

template high*[T: uint64](_: typedesc[T]): uint64 = 0xFFFFFFFF_FFFFFFFF'u64
template low*[T: uint64](_: typedesc[T]): uint64 = 0'u64

type
    CArray*[T] = ptr UncheckedArray[T]

proc readBinaryFile*(path: string): seq[uint8] =
    var
        file: File
        fileSize: int64
    check open(file, path), &"Can't open file: {path}"
    fileSize = getFileSize(file)
    result.setLen(fileSize)
    discard readBuffer(file, addr result[0], fileSize)
    close(file)

template intersect*[T](a, b: seq[T]): seq[T] =
    a.filterIt(b.contains(it))

template maskCheck*[A, B](pa: A, pb: B): bool =
    let
        a = uint64 pa
        b = uint64 pb
    (a and b) == b

proc maskCombine*(bits: varargs[uint64, `uint64`]): uint64 =
    var mask = 0'u64
    for bit in bits:
        mask = (mask or bit)
    mask

proc charArrayToString*[LEN](charArr: array[LEN, char]): string =
    for c in charArr:
        if c == '\0': break
        result &= c