import sequtils

template intersect*[T](a, b: seq[T]): seq[T] =
    a.filterIt(b.contains(it))

proc charArrayToString*[LEN](charArr: array[LEN, char]): string =
    for c in charArr:
        if c == '\0': break
        result &= c