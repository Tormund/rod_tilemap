import rod / [ component, node, viewport, rod_types ]
import rod / tools / [ serializer, debug_draw ]
import nimx / [ types, property_visitor, matrixes, portable_gl, context, image, resource,
                render_to_image ]

import json, tables, strutils, logging
import opengl
import nimx.assets.asset_loading

type
    LayerRange = tuple
        minx, maxx: int
        miny, maxy: int

    BaseTileMapLayer = ref object of Component
        size: Size
        actualSize: LayerRange

    TileMapLayer* = ref object of BaseTileMapLayer
        data*: seq[int16]

    ImageMapLayer* = ref object of BaseTileMapLayer
        image*: Image

    BaseTileSet = ref object of RootObj
        tileSize: Vector3
        firstGid: int
        tilesCount: int
        name: string

    TileSheet = ref object of BaseTileSet
        sheet: Image
        columns: int

    TileCollection = ref object of BaseTileSet
        collection: seq[Image]

    TileMapOrientation* {.pure.}= enum
        orthogonal
        isometric
        staggeredX
        staggeredY
        hexagonal

    TileMap* = ref object of Component
        mapSize*: Size
        tileSize*: Vector3
        layers: seq[BaseTileMapLayer]
        tileSets: seq[BaseTileSet]
        tileDrawRect: proc(tm: TileMap, pos: int, tr: var Rect)

        case mOrientation: TileMapOrientation
        of TileMapOrientation.staggeredX, TileMapOrientation.staggeredY:
            isStaggerIndexOdd: bool
        else: discard

proc position*(l: BaseTileMapLayer): Vector3=
    return l.node.position

proc alpha*(l: BaseTileMapLayer): float=
    return l.node.alpha

proc enabled*(l: BaseTileMapLayer): bool=
    return l.node.enabled

proc name*(l: BaseTileMapLayer): string =
    return l.node.name

method canDrawTile(ts: BaseTileSet, tid: int): bool=
    result = tid >= ts.firstGid and tid < ts.firstGid + ts.tilesCount

method canDrawTile(ts: TileCollection, tid: int): bool=
    result = tid < ts.collection.len and not ts.collection[tid].isNil

method drawTile(ts: BaseTileSet, tid: int, r: Rect, a: float) {.base.}=
    raise newException(Exception, "Abstract method called!")

method drawTile(ts: TileSheet, tid: int, r: Rect, a: float)=
    let tilePos = tid - ts.firstGid
    let tileX = (tilePos mod ts.columns) * ts.tileSize.x.int
    let tileY = (tilePos div ts.columns) * ts.tileSize.y.int
    currentContext().drawImage(ts.sheet, r, newRect(tileX.float, tileY.float, ts.tileSize.x, ts.tileSize.y), a)

method drawTile(ts: TileCollection, tid: int, r: Rect, a: float)=
    let image = ts.collection[tid]
    let imageSize = image.size
    var tr = r
    if imageSize.width.int != tr.width.int or imageSize.height.int != tr.height.int:
        tr.origin += newPoint(0, r.size.height - imageSize.height)
        tr.size = imageSize

    currentContext().drawImage(image, tr, alpha = a)

proc layerRect(tm: TileMap, l: TileMapLayer): Rect=
    case tm.mOrientation:
    of TileMapOrientation.orthogonal:
        result = newRect(l.position.x, l.position.y, tm.mapSize.width * tm.tileSize.x, tm.mapSize.height * tm.tileSize.y)

    of TileMapOrientation.isometric:
        let
            width = (tm.mapSize.width + tm.mapSize.height) * tm.tileSize.x * 0.5
            height = (tm.mapSize.width + tm.mapSize.height) * tm.tileSize.y * 0.5
        result = newRect(l.position.x, l.position.y, width, height)

    of TileMapOrientation.staggeredX:
        result.origin = newPoint(l.position.x, l.position.y)
        result.size = newSize(tm.tileSize.x * (tm.mapSize.width / 2.0 + 0.5), tm.tileSize.y * (tm.mapSize.height + 0.5))

    of TileMapOrientation.staggeredY:
        result.origin = newPoint(l.position.x, l.position.y)
        result.size = newSize(tm.tileSize.x * (tm.mapSize.width + 0.5), tm.tileSize.y * (tm.mapSize.height / 2.0 + 0.5))

    else:
        discard

method drawLayer(layer: BaseTileMapLayer, tm: TileMap) {.base.} =
    raise newException(Exception, "Abstract method called!")

method drawLayer(layer: ImageMapLayer, tm: TileMap)=
    currentContext().drawImage(layer.image, newRect(layer.position.x, layer.position.y, layer.image.size.width, layer.image.size.height), alpha = layer.alpha)

proc getViewportRect(l: TileMapLayer): Rect=
    if not l.node.sceneView.isNil:
        let camera = l.node.sceneView.camera
        result.size = camera.viewportSize * camera.node.scale.x
        result.origin = newPoint(camera.node.worldPos().x, camera.node.worldPos().y)
        result.origin.x = result.origin.x - camera.viewportSize.width  * 0.5 * camera.node.scale.x
        result.origin.y = result.origin.y - camera.viewportSize.height * 0.5 * camera.node.scale.y

proc getDrawRange(layer: TileMapLayer, r: Rect, ts: Vector3): LayerRange =
    let layerLen = layer.data.len
    result.minx = (r.x / ts.x).int
    result.maxx = ((r.x + r.width) / (ts.x * 0.5)).int

    result.miny = (r.y / ts.y).int
    result.maxy = ((r.y + r.height) / ts.y).int

proc tileAtPosition(layer: TileMapLayer, tm: TileMap, pos: int): int=
    var x = pos div tm.mapSize.width.int
    var y = pos mod tm.mapSize.width.int

    if (x >= layer.actualSize.minx and x <= layer.actualSize.maxx) and (y >= layer.actualSize.miny and y <= layer.actualSize.maxy):
        x -= layer.actualSize.minx
        y -= layer.actualSize.miny
        let idx = (layer.actualSize.maxx - layer.actualSize.minX) * y + x

        result = layer.data[idx]

method drawLayer(layer: TileMapLayer, tm: TileMap)=
    var r = tm.layerRect(layer)
    var worldLayerRect = newRect(newPoint(layer.node.worldPos().x, layer.node.worldPos().y), r.size)
    let viewRect = layer.getViewportRect()

    if worldLayerRect.intersect(viewRect):
        let (cols, cole, rows, rowe) = layer.getDrawRange(viewRect, tm.tileSize)

        let mapWidth = tm.mapSize.width.int
        var tileDrawRect = newRect(0.0, 0.0, 0.0, 0.0)
        let camera = layer.node.sceneView.camera

        # echo " h ", cole - cols, " w ", rowe - rows, " count " , (cole - cols) * (rowe - rows), " camscale ", camera.node.scale.x

        for y in cols .. cole:
            let mapWidthY = mapWidth * y
            for x in rows .. rowe:
                let pos = mapWidthY + x

                if pos < layer.data.len:
                    let tileId = layer.tileAtPosition(tm, pos)
                    if tileId == 0: continue

                    tm.tileDrawRect(tm, pos, tileDrawRect)

                    for tileSet in tm.tileSets:
                        if tileSet.canDrawTile(tileId):
                            tileSet.drawTile(tileId, tileDrawRect, layer.alpha)
                            break

method draw*(tm: TileMap) =
    for layer in tm.layers:
        if layer.enabled:
            layer.drawLayer(tm)

method getBBox*(tm: TileMap): BBox =
    result.maxPoint = newVector3(low(int).Coord/2.0, low(int).Coord/2.0, 1.0)
    result.minPoint = newVector3(high(int).Coord/2.0, high(int).Coord/2.0, 0.0)

    for l in tm.layers:
        if l of TileMapLayer:
            let r = tm.layerRect(l.TileMapLayer)
            if r.x < result.minPoint.x:
                result.minPoint.x = r.x
            if r.y < result.minPoint.y:
                result.minPoint.y = r.y
            if r.width + r.x > result.maxPoint.x:
                result.maxPoint.x = r.width + r.x
            if r.height + r.y > result.maxPoint.y:
                result.maxPoint.y = r.height + r.y

    echo "getBBox tiledmap ", [result.minPoint, result.maxPoint]

proc staggeredYTileRect(tm: TileMap, pos: int, tr: var Rect)=
    var row = (pos div tm.mapSize.width.int).float
    var col = (pos mod tm.mapSize.width.int).float

    let offIndex = if tm.isStaggerIndexOdd: 0 else: 1
    let axisP = (row.int + offIndex) mod 2

    tr.origin.x = col * tm.tileSize.x + axisP.float * tm.tileSize.x * 0.5
    tr.origin.y = row * tm.tileSize.y * 0.5

    tr.size = newSize(tm.tileSize.x, tm.tileSize.y)

proc staggeredXTileRect(tm: TileMap, pos: int, tr: var Rect)=
    var row = (pos div tm.mapSize.width.int).float
    var col = (pos mod tm.mapSize.width.int).float

    let offIndex = if tm.isStaggerIndexOdd: 0 else: 1
    let axisP = (col.int + offIndex) mod 2

    tr.origin.x = col * tm.tileSize.x * 0.5
    tr.origin.y = row * tm.tileSize.y + axisP.float * 0.5 * tm.tileSize.y

    tr.size = newSize(tm.tileSize.x, tm.tileSize.y)

proc isometricTileRect(tm: TileMap, pos: int, tr: var Rect)=
    var row = (pos div tm.mapSize.width.int).float
    var col = (pos mod tm.mapSize.width.int).float

    let halfTileWidth  = tm.tileSize.x * 0.5
    let halfTileHeigth = tm.tileSize.y * 0.5

    tr.origin.x = (col * halfTileWidth) - (row * tm.tileSize.x * 0.5) + (tm.mapSize.width - 1.0) * halfTileWidth
    tr.origin.y = (row * halfTileHeigth) + (col * halfTileHeigth)

    tr.size = newSize(tm.tileSize.x, tm.tileSize.y)

proc orthogonalTileRect(tm: TileMap, pos: int, tr: var Rect)=
    var row = (pos div tm.mapSize.width.int).float
    var col = (pos mod tm.mapSize.width.int).float

    tr.origin.x = col * tm.tileSize.x
    tr.origin.y = row * tm.tileSize.y

    tr.size = newSize(tm.tileSize.x, tm.tileSize.y)

proc orientation*(tm: TileMap): TileMapOrientation=
    result = tm.mOrientation

proc `orientation=`*(tm: TileMap, val: TileMapOrientation)=
    tm.mOrientation = val

    case val:
    of TileMapOrientation.orthogonal:
        tm.tileDrawRect = orthogonalTileRect
    of TileMapOrientation.isometric:
        tm.tileDrawRect = isometricTileRect
    of TileMapOrientation.staggeredX:
        tm.tileDrawRect = staggeredXTileRect
    of TileMapOrientation.staggeredY:
        tm.tileDrawRect = staggeredYTileRect
    else:
        tm.tileDrawRect = orthogonalTileRect

#todo: serialize support
# method deserialize*(c: TileMap, j: JsonNode, serealizer: Serializer) =
#     discard

# method serialize*(c: TileMap, s: Serializer): JsonNode=
#     result = newJObject()

method visitProperties*(tm: TileMap, p: var PropertyVisitor) =
    p.visitProperty("mapSize", tm.mapSize)
    p.visitProperty("tileSize", tm.tileSize)
    p.visitProperty("orientation", tm.orientation)

registerComponent(TileMap, "TileMap")
registerComponent(ImageMapLayer, "TileMap")
registerComponent(TileMapLayer, "TileMap")

#[
    Tiled support http://www.mapeditor.org/
 ]#

var tiledLayerCreators = initTable[string, proc(tm: TileMap, jl: JsonNode, s: Serializer): BaseTileMapLayer]()

tiledLayerCreators["imagelayer"] = proc(tm: TileMap, jl: JsonNode, s: Serializer): BaseTileMapLayer =
    let layer = new(ImageMapLayer)
    if "image" in jl and jl["image"].str.len > 0:
        deserializeImage(jl["image"], s) do(img: Image, err: string):
            layer.image = img

    result = layer

tiledLayerCreators["tilelayer"] = proc(tm: TileMap, jl: JsonNode, s: Serializer): BaseTileMapLayer =
    let layer = new(TileMapLayer)

    var dataSize = (tm.mapSize.width * tm.mapSize.height).int
    if "actualSize" in jl:
        let acts = jl["actualSize"]
        layer.actualSize.minx = acts["minX"].getNum().int
        layer.actualSize.maxx = acts["maxX"].getNum().int
        layer.actualSize.miny = acts["minY"].getNum().int
        layer.actualSize.maxy = acts["maxY"].getNum().int

        dataSize = (layer.actualSize.maxx - layer.actualSize.minx) * (layer.actualSize.maxy - layer.actualSize.miny)
        echo "layer actualSize ", layer.actualSize , " datasize ", dataSize, " ", jl["name"]
    else:
        layer.actualSize.minx = 0
        layer.actualSize.maxx = tm.mapSize.width.int
        layer.actualSize.miny = 0
        layer.actualSize.maxy = tm.mapSize.height.int
        echo "default size "

    layer.data = newSeq[int16](dataSize)
    if layer.data.len != jl["data"].len:
        warn "Incorrect layer data size ", jl["data"].len , " versus ", dataSize

    var i = 0
    echo "starting ", jl["name"], " ",  layer.data.len , " ", jl["data"].len
    for jld in jl["data"]:
        layer.data[i] = jld.getNum().int16
        inc i
    echo "\tdone ", jl["name"], " ",  layer.data.len , " ", jl["data"].len

    result = layer

proc checkLoadingErr(err: string) {.raises: Exception.}=
    if not err.isNil:
        raise newException(Exception, err)

proc loadTileSet(jTileSet: JsonNode, serializer: Serializer): BaseTileSet=
    var firstgid = 0
    if "firstgid" in jTileSet:
        firstgid = jTileSet["firstgid"].getNum().int

    if "tiles" in jTileSet:
        let tileCollection = new(TileCollection)

        tileCollection.tilesCount = jTileSet["tilecount"].getNum().int
        tileCollection.collection = @[]
        var tilesFound = 0
        var i = 0
        while tilesFound < tileCollection.tilesCount:
            let k = $i
            if k in jTileSet["tiles"]:
                inc tilesFound
                closureScope:
                    let tilePath = jTileSet["tiles"][k]["image"].getStr()
                    let fgid = firstgid
                    let ii = i + firstgid

                    deserializeImage(jTileSet["tiles"][k]["image"], serializer) do(img: Image, err: string):
                        checkLoadingErr(err)

                        if ii > tileCollection.collection.len - 1:
                            tileCollection.collection.setLen(ii + 1)

                        tileCollection.collection[ii] = img

            else:
                if i > 10_000:
                    raise newException(Exception, "TileSet corrupted")
            inc i

        result = tileCollection

    elif "image" in jTileSet:
        let tileSheet = new(TileSheet)
        deserializeImage(jTileSet["image"], serializer) do(img: Image, err: string):
            checkLoadingErr(err)
            tileSheet.sheet = img

        tileSheet.columns = jTileSet["columns"].getNum().int
        result = tileSheet

    else:
        raise newException(Exception, "Incorrect tileSet format")

    result.name = jTileSet["name"].getStr()
    result.tileSize = newVector3(jTileSet["tilewidth"].getFNum(), jTileSet["tileheight"].getFNum())
    result.tilesCount = jTileSet["tilecount"].getNum().int

    result.firstGid = firstgid

    echo "TileSet ", result.name, " loaded!"

proc loadTiledWithUrl*(tm: TileMap, url: string, onComplete: proc() = nil) =
    loadAsset(url) do(jtm: JsonNode, err: string):
        checkLoadingErr(err)

        let serializer = new(Serializer)
        serializer.url = url
        serializer.onComplete = onComplete

        if "orientation" in jtm:
            try:
                tm.orientation = parseEnum[TileMapOrientation](jtm["orientation"].getStr())
            except:
                if jtm["orientation"].getStr() == "staggered":
                    let isStaggerAxisX = jtm["staggeraxis"].getStr() == "x"
                    if isStaggerAxisX:
                        tm.orientation = TileMapOrientation.staggeredX
                    else:
                        tm.orientation = TileMapOrientation.staggeredY
                    tm.isStaggerIndexOdd = jtm["staggerindex"].getStr() == "odd"

        if "width" in jtm and "height" in jtm:
            tm.mapSize = newSize(jtm["width"].getFNum(), jtm["height"].getFNum())

        if "tileheight" in jtm and "tilewidth" in jtm:
            let tWidth = jtm["tilewidth"].getNum().float
            let tHeigth = jtm["tileheight"].getNum().float
            tm.tileSize = newVector3(tWidth, tHeigth)

        if "layers" in jtm:
            tm.layers = @[]
            for jl in jtm["layers"]:
                let layerType = jl["type"].getStr()
                let layerCreator = tiledLayerCreators.getOrDefault(layerType)

                if layerCreator.isNil:
                    warn "TileMap loadTiled: ", layerType, " doesn't supported!"
                    continue

                var layer = tm.layerCreator(jl, serializer)
                let name = jl["name"].getStr()
                let enabled = jl["visible"].getBVal()
                let alpha = jl["opacity"].getFNum()

                layer.size = newSize(jl["width"].getFNum(), jl["height"].getFNum())
                var position = newVector3()
                if "offsetx" in jl:
                    position.x = jl["offsetx"].getFNum()
                if "offsety" in jl:
                    position.y = jl["offsety"].getFNum()

                var layerNode = newNode(name)
                layerNode.position = position
                layerNode.alpha = alpha
                layerNode.enabled = enabled

                if layerType == "imagelayer":
                    layerNode.setComponent("ImageMapLayer", layer)
                elif layerType == "tilelayer":
                    layerNode.setComponent("TileMapLayer", layer)

                layer.node = layerNode
                tm.node.addChild(layerNode)
                tm.layers.add(layer)

        if "tilesets" in jtm:
            tm.tileSets = @[]

            for jts in jtm["tilesets"]:
                if "source" in jts:
                    closureScope:
                        let url = serializer.toAbsoluteUrl(jts["source"].getStr())
                        serializer.startAsyncOp()
                        let fg = jts["firstgid"]

                        loadAsset(url) do(j: JsonNode, err: string):
                            checkLoadingErr(err)

                            let s = new(Serializer)
                            s.url = url
                            j["firstgid"] = fg
                            s.onComplete = proc() =
                                serializer.endAsyncOp()

                            let ts = loadTileSet(j, s)
                            s.finish()
                            tm.tileSets.add(ts)
                else:
                    let ts = loadTileSet(jts, serializer)
                    if not ts.isNil:
                        tm.tileSets.add(ts)

        serializer.finish()

proc loadTiledWithResource*(tm: TileMap, path: string) =
    var done = false
    tm.loadTiledWithUrl("res://" & path) do():
        done = true
        echo "done loadTiledWithResource"
    if not done:
        echo "failed loadTiledWithResource"
    #     raise newException(Exception, "Load could not complete synchronously. Possible reason: asset bundle not preloaded")
