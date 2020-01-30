import rod/node
import rod/component
import tile_map
import json

proc prototype*[T](m: TileMap, n: Node): T =
    assert(n.parent.isNil, "Add node to scene after prototyping")
    result = n.component(T)
    result.tileSize = m.tileSize
    result.mapSize = m.mapSize
    result.mOrientation = m.mOrientation
    result.tileSets = m.tileSets
    result.isStaggerIndexOdd = m.isStaggerIndexOdd
    result.properties = m.properties
    # result.mTilesSpriteSheet = m.mTilesSpriteSheet
    # result.tileVCoords = m.tileVCoords
    result.layers = @[]

proc pcgStaggeredRect*(tl: TileMapLayer, width, height: int, m, ltc, rtc, lbc, rbc, ts, bs, ls, rs: int16 = -1)=
    let lwidth = height + width
    let dataLen = lwidth * (lwidth div 2 + 1)
    let lw = if lwidth mod 2 == 0: lwidth else: lwidth - 1

    var mid = m
    var lTopc = ltc
    var rTopc = rtc
    var lBotc = lbc
    var rBotc = rbc
    var tops = ts
    var bots = bs
    var lefs = ls
    var rigs = rs

    template verifyTid(t: var int16, deft:int16)=
        if t == -1:
            t = deft

    verifyTid(lTopc, mid)
    verifyTid(rTopc, mid)
    verifyTid(lBotc, mid)
    verifyTid(rBotc, mid)
    verifyTid(tops, mid)
    verifyTid(bots, mid)
    verifyTid(lefs, mid)
    verifyTid(rigs, mid)

    tl.data = newSeq[int16](dataLen)

    tl.actualSize.minx = 0
    tl.actualSize.miny = 0
    tl.actualSize.maxx = lw.int32
    tl.actualSize.maxy = (tl.data.len div lw).int32

    var ftp = height - 1

    var codd = ftp mod 2 == 0

    for i in 0 ..< width:
        var p = ftp
        for j in 0 ..< height:
            var tid = mid

            if i == 0:
                if j == 0:
                    tid = lTopc
                elif j == height - 1:
                    tid = lbotc
                else:
                    tid = lefs

            elif i == width - 1:
                if j == 0:
                    tid = rTopc
                elif j == height - 1:
                    tid = rBotc
                else:
                    tid = rigs

            elif j == 0:
                tid = tops

            elif j == height - 1:
                tid = bots

            tl.data[p] = tid
            if p mod 2 != 0:
                p += lw
            p -= 1

        if not codd:
            ftp += lw + 1
        else:
            ftp += 1

        codd = not codd

