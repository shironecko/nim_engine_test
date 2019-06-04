import sequtils

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

proc charArrayToString*[LEN](charArr: array[LEN, char]): string =
    for c in charArr:
        if c == '\0': break
        result &= c